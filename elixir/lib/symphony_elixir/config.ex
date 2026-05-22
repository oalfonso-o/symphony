defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @type codex_execution :: %{
          profile_name: String.t(),
          command: String.t(),
          prompt_template: String.t() | nil,
          action: String.t() | nil,
          claim_scope: String.t() | nil
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec runtime_state_root() :: Path.t()
  def runtime_state_root do
    settings!().runtime.state_root
  end

  @spec drain?() :: boolean()
  def drain? do
    case settings!().runtime.drain_file do
      path when is_binary(path) -> File.exists?(path)
      _ -> false
    end
  end

  @spec set_drain(boolean()) :: :ok | {:error, term()}
  def set_drain(enabled) when is_boolean(enabled) do
    case settings!().runtime.drain_file do
      path when is_binary(path) and enabled ->
        enable_drain(path)

      path when is_binary(path) ->
        disable_drain(path)

      _ ->
        {:error, :drain_file_not_configured}
    end
  end

  defp enable_drain(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, "drain enabled at #{DateTime.utc_now() |> DateTime.to_iso8601()}\n")
    end
  end

  defp disable_drain(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec workflow_prompt_template(String.t() | nil) :: String.t()
  def workflow_prompt_template(nil), do: workflow_prompt()
  def workflow_prompt_template(""), do: workflow_prompt()
  def workflow_prompt_template("default"), do: workflow_prompt()

  def workflow_prompt_template(name) when is_binary(name) do
    settings = settings!()

    case Map.get(settings.codex.prompt_templates || %{}, name) do
      template when is_binary(template) and template != "" -> template
      _ -> workflow_prompt()
    end
  end

  @spec codex_execution_for_issue(map(), keyword()) :: codex_execution()
  def codex_execution_for_issue(issue, opts \\ []) when is_map(issue) and is_list(opts) do
    settings = settings!()
    claim_scope = Keyword.get(opts, :claim_scope)
    route = codex_route_for_issue(settings, issue, claim_scope)
    profile_name = route["profile"] || settings.codex.default_profile || "default"
    profile = Map.get(settings.codex.profiles || %{}, profile_name, %{})

    %{
      profile_name: profile_name,
      command: route["command"] || profile["command"] || settings.codex.command,
      prompt_template: route["prompt_template"] || profile["prompt_template"],
      action: route["action"],
      claim_scope: claim_scope
    }
  end

  @spec codex_execution_for_profile(String.t()) :: {:ok, codex_execution()} | {:error, term()}
  def codex_execution_for_profile(profile_name) when is_binary(profile_name) do
    settings = settings!()

    case Map.get(settings.codex.profiles || %{}, profile_name) do
      %{} = profile ->
        {:ok,
         %{
           profile_name: profile_name,
           command: profile["command"] || settings.codex.command,
           prompt_template: profile["prompt_template"],
           action: nil,
           claim_scope: nil
         }}

      _ ->
        {:error, {:missing_codex_profile, profile_name}}
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  defp validate_semantics(settings) do
    cond do
      is_nil(settings.tracker.kind) ->
        {:error, :missing_tracker_kind}

      settings.tracker.kind not in ["linear", "memory"] ->
        {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.api_key) ->
        {:error, :missing_linear_api_token}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        :ok
    end
  end

  defp codex_route_for_issue(settings, issue, claim_scope) do
    routes = settings.codex.routes || %{}

    claim_scope_route =
      routes
      |> Map.get("claim_scopes", %{})
      |> route_entry(claim_scope)

    state_route =
      routes
      |> Map.get("states", %{})
      |> route_entry(Map.get(issue, :state) || Map.get(issue, "state"))

    Map.merge(state_route, claim_scope_route)
  end

  defp route_entry(routes, key) when is_map(routes) and is_binary(key) do
    Map.get(routes, key) || Map.get(routes, String.downcase(String.trim(key))) || %{}
  end

  defp route_entry(_routes, _key), do: %{}

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
