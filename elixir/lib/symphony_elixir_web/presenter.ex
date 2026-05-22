defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard}
  alias SymphonyElixir.Runtime.{EventLog, SummaryStore}

  @optional_runtime_fields MapSet.new([
                             :run_id,
                             :runtime_kind,
                             :registry_path,
                             :event_log_path,
                             :summary_path,
                             :summary,
                             :codex_profile,
                             :prompt_template,
                             :tmux_target,
                             :tmux_input_path,
                             :tmux_output_path,
                             :tmux_stderr_path,
                             :status_reason
                           ])

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        adopted = Enum.map(Map.get(snapshot, :adopted, []), &adopted_entry_payload/1)
        drain = Map.get(snapshot, :drain, %{enabled: false, file: nil})
        profile_totals = Map.get(snapshot, :profile_totals, %{})
        scheduling = Map.get(snapshot, :scheduling, %{})

        %{
          generated_at: generated_at,
          counts:
            %{
              running: length(snapshot.running),
              retrying: length(snapshot.retrying),
              blocked: length(Map.get(snapshot, :blocked, []))
            }
            |> maybe_put(:adopted, length(adopted), adopted != []),
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          blocked: Enum.map(Map.get(snapshot, :blocked, []), &blocked_entry_payload/1),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits
        }
        |> maybe_put(:adopted, adopted, adopted != [])
        |> maybe_put(:drain, drain, drain[:enabled] == true)
        |> maybe_put(:profile_totals, profile_totals, profile_totals != %{})
        |> maybe_put(:scheduling, scheduling, scheduling != %{})

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
        blocked = Enum.find(Map.get(snapshot, :blocked, []), &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) and is_nil(blocked) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, blocked)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry, blocked) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry, blocked),
      status: issue_status(running, retry, blocked),
      workspace: workspace_payload(issue_identifier, running, retry, blocked),
      attempts: attempts_payload(retry),
      running: running_payload(running),
      retry: retry_payload(retry),
      blocked: blocked_payload(blocked),
      logs: logs_payload(running),
      recent_events: recent_events_payload(active_event_entry(running, blocked)),
      last_error: last_error(blocked, retry),
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry, blocked),
    do: (running && running.issue_id) || (retry && retry.issue_id) || (blocked && blocked.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(running, _retry, _blocked) when not is_nil(running), do: "running"
  defp issue_status(nil, retry, _blocked) when not is_nil(retry), do: "retrying"
  defp issue_status(nil, nil, _blocked), do: "blocked"

  defp workspace_payload(issue_identifier, running, retry, blocked) do
    %{
      path: workspace_path(issue_identifier, running, retry, blocked),
      host: workspace_host(running, retry, blocked)
    }
  end

  defp attempts_payload(retry) do
    %{
      restart_count: restart_count(retry),
      current_retry_attempt: retry_attempt(retry)
    }
  end

  defp running_payload(nil), do: nil
  defp running_payload(running), do: running_issue_payload(running)

  defp retry_payload(nil), do: nil
  defp retry_payload(retry), do: retry_issue_payload(retry)

  defp blocked_payload(nil), do: nil
  defp blocked_payload(blocked), do: blocked_issue_payload(blocked)

  defp logs_payload(nil), do: %{codex_session_logs: []}
  defp logs_payload(running), do: %{codex_session_logs: recent_events_payload(running)}

  defp active_event_entry(nil, blocked), do: blocked
  defp active_event_entry(running, _blocked), do: running

  defp last_error(%{error: error}, _retry), do: error
  defp last_error(nil, %{error: error}), do: error
  defp last_error(nil, nil), do: nil

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      run_id: Map.get(entry, :run_id),
      runtime_kind: Map.get(entry, :runtime_kind),
      registry_path: Map.get(entry, :registry_path),
      event_log_path: Map.get(entry, :event_log_path),
      summary_path: Map.get(entry, :summary_path),
      codex_profile: Map.get(entry, :codex_profile),
      prompt_template: Map.get(entry, :prompt_template),
      tmux_target: Map.get(entry, :tmux_target),
      tmux_input_path: Map.get(entry, :tmux_input_path),
      tmux_output_path: Map.get(entry, :tmux_output_path),
      tmux_stderr_path: Map.get(entry, :tmux_stderr_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      },
      recent_events: recent_events_payload(entry),
      summary: summary_payload(Map.get(entry, :summary_path))
    }
    |> compact_map()
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp blocked_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      run_id: Map.get(entry, :run_id),
      runtime_kind: Map.get(entry, :runtime_kind),
      registry_path: Map.get(entry, :registry_path),
      event_log_path: Map.get(entry, :event_log_path),
      summary_path: Map.get(entry, :summary_path),
      codex_profile: Map.get(entry, :codex_profile),
      prompt_template: Map.get(entry, :prompt_template),
      tmux_target: Map.get(entry, :tmux_target),
      tmux_input_path: Map.get(entry, :tmux_input_path),
      tmux_output_path: Map.get(entry, :tmux_output_path),
      tmux_stderr_path: Map.get(entry, :tmux_stderr_path),
      session_id: entry.session_id,
      blocked_at: iso8601(entry.blocked_at),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      last_event_at: iso8601(entry.last_codex_timestamp),
      summary: summary_payload(Map.get(entry, :summary_path))
    }
    |> compact_map()
  end

  defp adopted_entry_payload(entry) do
    %{
      issue_id: Map.get(entry, :issue_id),
      issue_identifier: Map.get(entry, :identifier),
      state: Map.get(entry, :state),
      run_id: Map.get(entry, :run_id),
      runtime_kind: Map.get(entry, :runtime_kind),
      status: Map.get(entry, :status),
      status_reason: Map.get(entry, :status_reason),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      registry_path: Map.get(entry, :registry_path),
      event_log_path: Map.get(entry, :event_log_path),
      summary_path: Map.get(entry, :summary_path),
      codex_profile: Map.get(entry, :codex_profile),
      prompt_template: Map.get(entry, :prompt_template),
      tmux_target: Map.get(entry, :tmux_target),
      heartbeat_at: iso8601(Map.get(entry, :heartbeat_at)),
      started_at: iso8601(Map.get(entry, :started_at)),
      updated_at: iso8601(Map.get(entry, :updated_at)),
      recent_events: recent_events_payload(entry),
      summary: summary_payload(Map.get(entry, :summary_path))
    }
    |> compact_map()
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      run_id: Map.get(running, :run_id),
      runtime_kind: Map.get(running, :runtime_kind),
      registry_path: Map.get(running, :registry_path),
      event_log_path: Map.get(running, :event_log_path),
      summary_path: Map.get(running, :summary_path),
      codex_profile: Map.get(running, :codex_profile),
      prompt_template: Map.get(running, :prompt_template),
      tmux_target: Map.get(running, :tmux_target),
      tmux_input_path: Map.get(running, :tmux_input_path),
      tmux_output_path: Map.get(running, :tmux_output_path),
      tmux_stderr_path: Map.get(running, :tmux_stderr_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      },
      recent_events: recent_events_payload(running),
      summary: summary_payload(Map.get(running, :summary_path))
    }
    |> compact_map()
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp blocked_issue_payload(blocked) do
    %{
      worker_host: Map.get(blocked, :worker_host),
      workspace_path: Map.get(blocked, :workspace_path),
      run_id: Map.get(blocked, :run_id),
      runtime_kind: Map.get(blocked, :runtime_kind),
      registry_path: Map.get(blocked, :registry_path),
      event_log_path: Map.get(blocked, :event_log_path),
      summary_path: Map.get(blocked, :summary_path),
      codex_profile: Map.get(blocked, :codex_profile),
      prompt_template: Map.get(blocked, :prompt_template),
      tmux_target: Map.get(blocked, :tmux_target),
      tmux_input_path: Map.get(blocked, :tmux_input_path),
      tmux_output_path: Map.get(blocked, :tmux_output_path),
      tmux_stderr_path: Map.get(blocked, :tmux_stderr_path),
      session_id: blocked.session_id,
      state: blocked.state,
      error: blocked.error,
      blocked_at: iso8601(blocked.blocked_at),
      last_event: blocked.last_codex_event,
      last_message: summarize_message(blocked.last_codex_message),
      last_event_at: iso8601(blocked.last_codex_timestamp),
      summary: summary_payload(Map.get(blocked, :summary_path))
    }
    |> compact_map()
  end

  defp workspace_path(issue_identifier, running, retry, blocked) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      (blocked && Map.get(blocked, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry, blocked) do
    (running && Map.get(running, :worker_host)) ||
      (retry && Map.get(retry, :worker_host)) ||
      (blocked && Map.get(blocked, :worker_host))
  end

  defp recent_events_payload(nil), do: []

  defp recent_events_payload(entry) do
    events = durable_recent_events(entry) || in_memory_recent_events(entry)

    if events == [] do
      [
        %{
          at: iso8601(entry.last_codex_timestamp),
          event: entry.last_codex_event,
          message: summarize_message(entry.last_codex_message)
        }
      ]
      |> Enum.reject(&is_nil(&1.at))
    else
      events
    end
  end

  defp durable_recent_events(entry) do
    case Map.get(entry, :event_log_path) do
      path when is_binary(path) ->
        case EventLog.tail(path, 100) do
          {:ok, events} ->
            events
            |> Enum.map(&codex_event_payload/1)
            |> Enum.reject(&is_nil(&1.at))

          {:error, _reason} ->
            nil
        end

      _ ->
        nil
    end
  end

  defp in_memory_recent_events(entry) do
    entry
    |> Map.get(:codex_events, [])
    |> Enum.map(&codex_event_payload/1)
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summary_payload(nil), do: nil

  defp summary_payload(path) do
    case SummaryStore.read(path) do
      {:ok, summary} -> summary
      {:error, reason} -> %{SummaryStore.empty() | status: "failed", status_reason: inspect(reason)}
    end
  end

  defp maybe_put(map, _key, _value, false), do: map
  defp maybe_put(map, key, value, true), do: Map.put(map, key, value)

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {key, value} -> is_nil(value) and MapSet.member?(@optional_runtime_fields, key) end)
    |> Map.new()
  end

  defp codex_event_payload(%{event: event, timestamp: timestamp, message: message}) do
    %{
      at: iso8601(timestamp),
      event: event,
      message: summarize_message(message)
    }
  end

  defp codex_event_payload(_event), do: %{at: nil, event: nil, message: nil}

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(datetime) when is_binary(datetime), do: datetime

  defp iso8601(_datetime), do: nil
end
