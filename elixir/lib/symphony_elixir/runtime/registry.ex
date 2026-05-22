defmodule SymphonyElixir.Runtime.Registry do
  @moduledoc """
  Durable registry for local Symphony worker runs.
  """

  alias SymphonyElixir.{Config, Linear.Issue}
  alias SymphonyElixir.Runtime.Json

  @terminal_statuses ["completed", "failed", "blocked", "stopped", "dead"]

  @type metadata :: map()

  @spec state_root() :: Path.t()
  def state_root, do: Config.runtime_state_root()

  @spec run_id(String.t() | nil) :: String.t()
  def run_id(issue_identifier) do
    prefix =
      issue_identifier
      |> to_string()
      |> String.replace(~r/[^A-Za-z0-9_.-]+/, "-")
      |> String.trim("-")
      |> case do
        "" -> "run"
        value -> value
      end

    timestamp = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    suffix = System.unique_integer([:positive, :monotonic])
    "#{prefix}-#{timestamp}-#{suffix}"
  end

  @spec build(Issue.t(), keyword()) :: metadata()
  def build(%Issue{} = issue, opts \\ []) do
    root = Keyword.get(opts, :state_root, state_root())
    run_id = Keyword.get(opts, :run_id) || run_id(issue.identifier)
    registry_path = registry_path(root, run_id)
    event_log_path = event_log_path(root, run_id)
    summary_path = summary_path(root, run_id)
    now = DateTime.utc_now()

    %{
      run_id: run_id,
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      issue_state: issue.state,
      runtime_kind: Keyword.get(opts, :runtime_kind, "native"),
      status: Keyword.get(opts, :status, "starting"),
      status_reason: Keyword.get(opts, :status_reason),
      worker_host: Keyword.get(opts, :worker_host),
      workspace_path: Keyword.get(opts, :workspace_path),
      codex_profile: Keyword.get(opts, :codex_profile),
      codex_command: Keyword.get(opts, :codex_command),
      prompt_template: Keyword.get(opts, :prompt_template),
      claim_scope: Keyword.get(opts, :claim_scope),
      tmux_target: Keyword.get(opts, :tmux_target),
      session_id: nil,
      codex_app_server_pid: nil,
      registry_path: registry_path,
      event_log_path: event_log_path,
      summary_path: summary_path,
      heartbeat_at: now,
      started_at: now,
      updated_at: now,
      completed_at: nil,
      token_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
    }
    |> drop_nil_values()
  end

  @spec registry_path(Path.t(), String.t()) :: Path.t()
  def registry_path(root, run_id), do: Path.join([root, "registry", run_id <> ".json"])

  @spec event_log_path(Path.t(), String.t()) :: Path.t()
  def event_log_path(root, run_id), do: Path.join([root, "events", run_id <> ".jsonl"])

  @spec summary_path(Path.t(), String.t()) :: Path.t()
  def summary_path(root, run_id), do: Path.join([root, "summaries", run_id <> ".json"])

  @spec write(metadata()) :: {:ok, metadata()} | {:error, term()}
  def write(%{registry_path: path} = metadata) when is_binary(path) do
    metadata =
      metadata
      |> Map.put(:updated_at, DateTime.utc_now())
      |> drop_nil_values()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- atomic_write(path, Json.encode_pretty!(metadata) <> "\n") do
      {:ok, metadata}
    end
  end

  @spec read(Path.t()) :: {:ok, metadata()} | {:error, term()}
  def read(path) when is_binary(path) do
    with {:ok, content} <- File.read(path),
         {:ok, %{} = metadata} <- Json.decode(content) do
      {:ok, atomize_metadata(metadata)}
    else
      {:error, :enoent} -> {:error, :missing_registry}
      {:error, %Jason.DecodeError{} = error} -> {:error, {:malformed_registry, Exception.message(error)}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_registry}
    end
  end

  @spec list(Path.t()) :: {:ok, [metadata()]} | {:error, term()}
  def list(root \\ state_root()) when is_binary(root) do
    registry_glob = Path.join([root, "registry", "*.json"])

    registry_glob
    |> Path.wildcard()
    |> Enum.reduce({:ok, []}, fn
      path, {:ok, acc} ->
        case read(path) do
          {:ok, metadata} -> {:ok, [metadata | acc]}
          {:error, _reason} -> {:ok, acc}
        end

      _path, {:error, _reason} = error ->
        error
    end)
    |> case do
      {:ok, metadata} -> {:ok, Enum.reverse(metadata)}
      error -> error
    end
  end

  @spec touch(Path.t(), map()) :: {:ok, metadata()} | {:error, term()}
  def touch(path, updates \\ %{}) when is_binary(path) and is_map(updates) do
    with {:ok, metadata} <- read(path) do
      metadata
      |> Map.merge(updates)
      |> Map.put(:heartbeat_at, DateTime.utc_now())
      |> write()
    end
  end

  @spec complete(Path.t(), String.t(), String.t() | nil) :: {:ok, metadata()} | {:error, term()}
  def complete(path, status, reason \\ nil) when is_binary(path) and is_binary(status) do
    touch(path, %{
      status: status,
      status_reason: reason,
      completed_at: DateTime.utc_now()
    })
  end

  @spec classification(metadata(), keyword()) :: {String.t(), String.t() | nil}
  def classification(metadata, opts \\ []) when is_map(metadata) and is_list(opts) do
    stale_after_ms = Keyword.get(opts, :stale_after_ms, Config.settings!().runtime.stale_after_ms)
    status = metadata |> Map.get(:status, "unknown") |> to_string()

    cond do
      status in @terminal_statuses ->
        {status, Map.get(metadata, :status_reason)}

      stale?(metadata, stale_after_ms) ->
        {"stale", "heartbeat older than #{stale_after_ms}ms"}

      true ->
        {status, Map.get(metadata, :status_reason)}
    end
  end

  defp stale?(metadata, stale_after_ms) when is_integer(stale_after_ms) and stale_after_ms > 0 do
    case parse_datetime(Map.get(metadata, :heartbeat_at)) do
      {:ok, heartbeat_at} ->
        DateTime.diff(DateTime.utc_now(), heartbeat_at, :millisecond) > stale_after_ms

      :error ->
        false
    end
  end

  defp stale?(_metadata, _stale_after_ms), do: false

  defp parse_datetime(%DateTime{} = value), do: {:ok, value}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp parse_datetime(_value), do: :error

  defp atomic_write(path, content) when is_binary(path) and is_binary(content) do
    tmp_path = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.write(tmp_path, content),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp_path)
        {:error, reason}
    end
  end

  defp atomize_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.new(fn {key, value} -> {String.to_atom(to_string(key)), atomize_value(value)} end)
    |> drop_nil_values()
  end

  defp atomize_value(value) when is_map(value), do: atomize_metadata(value)
  defp atomize_value(value) when is_list(value), do: Enum.map(value, &atomize_value/1)
  defp atomize_value(value), do: value

  defp drop_nil_values(%_{} = value), do: value

  defp drop_nil_values(value) when is_map(value) do
    value
    |> Enum.reject(fn {_key, nested} -> is_nil(nested) end)
    |> Map.new(fn {key, nested} -> {key, drop_nil_values(nested)} end)
  end

  defp drop_nil_values(value), do: value
end
