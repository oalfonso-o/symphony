defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}
  alias SymphonyElixir.Runtime.{EventLog, Registry}

  @type worker_host :: String.t() | nil

  @spec run(Issue.t(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    with {:ok, issue} <- move_queued_issue_to_in_progress(issue) do
      run_prepared_issue_on_worker_host(issue, codex_update_recipient, opts, worker_host)
    end
  end

  defp run_prepared_issue_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        execution = Config.codex_execution_for_issue(issue, opts)

        run_metadata =
          issue
          |> Registry.build(
            worker_host: worker_host,
            workspace_path: workspace,
            codex_profile: execution.profile_name,
            codex_command: execution.command,
            prompt_template: execution.prompt_template,
            claim_scope: execution.claim_scope
          )
          |> write_run_metadata()

        append_run_event(run_metadata, :worker_started, %{worker_host: worker_host, workspace_path: workspace})
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace, run_metadata)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            result =
              run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host, execution, run_metadata)

            complete_run_metadata(run_metadata, result)
            result
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp move_queued_issue_to_in_progress(%Issue{id: issue_id, state: state} = issue)
       when is_binary(issue_id) and is_binary(state) do
    case queued_issue_target_state(state) do
      nil ->
        {:ok, issue}

      target_state ->
        Logger.info("Moving queued issue to #{target_state} before Codex startup for #{issue_context(issue)} current_state=#{inspect(state)}")

        case Tracker.update_issue_state(issue_id, target_state) do
          :ok -> {:ok, %{issue | state: target_state}}
          {:error, reason} -> {:error, {:issue_state_transition_failed, state, target_state, reason}}
        end
    end
  end

  defp move_queued_issue_to_in_progress(issue), do: {:ok, issue}

  defp queued_issue_target_state(state) do
    normalized_state = normalize_issue_state(state)

    if normalized_state in ["todo", "ready for agent"] do
      Enum.find(Config.settings!().tracker.active_states, fn active_state ->
        normalize_issue_state(active_state) == "in progress"
      end)
    end
  end

  defp codex_message_handler(recipient, issue, run_metadata) do
    fn message ->
      append_codex_event(run_metadata, message)
      touch_run_metadata(run_metadata, message)
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace, run_metadata)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace,
         run_id: Map.get(run_metadata, :run_id),
         registry_path: Map.get(run_metadata, :registry_path),
         event_log_path: Map.get(run_metadata, :event_log_path),
         summary_path: Map.get(run_metadata, :summary_path),
         runtime_kind: Map.get(run_metadata, :runtime_kind),
         codex_profile: Map.get(run_metadata, :codex_profile),
         prompt_template: Map.get(run_metadata, :prompt_template)
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace, _run_metadata), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host, execution, run_metadata) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    run_context = %{
      codex_update_recipient: codex_update_recipient,
      opts: opts,
      issue_state_fetcher: issue_state_fetcher,
      max_turns: max_turns,
      execution: execution,
      run_metadata: run_metadata
    }

    with {:ok, session} <-
           AppServer.start_session(workspace,
             worker_host: worker_host,
             codex_command: execution.command,
             codex_profile: execution.profile_name,
             run_id: Map.get(run_metadata, :run_id)
           ) do
      try do
        do_run_codex_turns(session, workspace, issue, 1, run_context)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(app_session, workspace, issue, turn_number, run_context) do
    prompt =
      build_turn_prompt(
        issue,
        run_context.opts,
        turn_number,
        run_context.max_turns,
        run_context.execution
      )

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message:
               codex_message_handler(
                 run_context.codex_update_recipient,
                 issue,
                 run_context.run_metadata
               )
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{run_context.max_turns}")

      case continue_with_issue?(issue, run_context.issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < run_context.max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{run_context.max_turns}")

          do_run_codex_turns(app_session, workspace, refreshed_issue, turn_number + 1, run_context)

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns, execution) do
    opts =
      opts
      |> Keyword.put(:prompt_template, execution.prompt_template)
      |> Keyword.put(:codex_profile, execution.profile_name)

    PromptBuilder.build_prompt(issue, opts)
  end

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns, _execution) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp write_run_metadata(metadata) do
    case Registry.write(metadata) do
      {:ok, metadata} ->
        metadata

      {:error, reason} ->
        Logger.warning("Failed to write run registry for issue_id=#{metadata[:issue_id]} issue_identifier=#{metadata[:issue_identifier]} run_id=#{metadata[:run_id]} reason=#{inspect(reason)}")
        metadata
    end
  end

  defp complete_run_metadata(metadata, :ok), do: complete_registry(metadata, "completed", nil)
  defp complete_run_metadata(metadata, {:error, reason}), do: complete_registry(metadata, "failed", inspect(reason))

  defp complete_registry(%{registry_path: path}, status, reason) when is_binary(path) do
    case Registry.complete(path, status, reason) do
      {:ok, _metadata} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp complete_registry(_metadata, _status, _reason), do: :ok

  defp touch_run_metadata(%{registry_path: path}, message) when is_binary(path) and is_map(message) do
    updates =
      %{
        status: "running",
        session_id: Map.get(message, :session_id),
        codex_app_server_pid: Map.get(message, :codex_app_server_pid),
        codex_profile: Map.get(message, :codex_profile),
        runtime_kind: Map.get(message, :runtime_kind),
        tmux_target: Map.get(message, :tmux_target),
        tmux_input_path: Map.get(message, :tmux_input_path),
        tmux_output_path: Map.get(message, :tmux_output_path),
        tmux_stderr_path: Map.get(message, :tmux_stderr_path),
        last_event: Map.get(message, :event),
        last_event_at: Map.get(message, :timestamp)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    case Registry.touch(path, updates) do
      {:ok, _metadata} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp touch_run_metadata(_metadata, _message), do: :ok

  defp append_run_event(%{event_log_path: path}, event, payload) when is_binary(path) do
    case EventLog.append(path, %{event: event, payload: payload}) do
      {:ok, _event} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp append_run_event(_metadata, _event, _payload), do: :ok

  defp append_codex_event(%{event_log_path: path}, message) when is_binary(path) and is_map(message) do
    event =
      message
      |> Map.take([:event, :timestamp, :payload, :raw, :usage, :session_id, :codex_app_server_pid, :codex_profile])
      |> Map.put(:message, Map.get(message, :payload) || Map.get(message, :raw))

    case EventLog.append(path, event) do
      {:ok, _event} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp append_codex_event(_metadata, _message), do: :ok
end
