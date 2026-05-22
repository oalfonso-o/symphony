defmodule SymphonyElixir.Runtime.EventSummarizer do
  @moduledoc """
  On-demand summarization for durable worker event logs.
  """

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Runtime.{EventLog, Json, SummaryStore}
  alias SymphonyElixir.StatusDashboard

  @prompt_version "event-summary-v1"
  @segment_size 40
  @agent_message_methods [
    "item/agentMessage/delta",
    "codex/event/agent_message_delta",
    "codex/event/agent_message_content_delta"
  ]

  @spec summarize_entry(map()) :: {:ok, map()} | {:error, term()}
  def summarize_entry(entry) when is_map(entry) do
    if Config.settings!().runtime.summary_enabled do
      do_summarize_entry(entry)
    else
      {:ok, %{SummaryStore.empty() | status: "disabled", status_reason: "summary disabled"}}
    end
  end

  defp do_summarize_entry(entry) do
    summary_path = Map.get(entry, :summary_path) || Map.get(entry, "summary_path")
    event_log_path = Map.get(entry, :event_log_path) || Map.get(entry, "event_log_path")

    with path when is_binary(path) <- summary_path,
         log_path when is_binary(log_path) <- event_log_path do
      :global.trans({__MODULE__, path}, fn -> summarize_locked(path, log_path) end, [node()])
    else
      nil -> {:error, :missing_summary_or_event_log_path}
      {:error, reason} = error -> maybe_record_failure(summary_path, reason, error)
    end
  end

  defp summarize_locked(path, log_path) do
    with {:ok, summary} <- SummaryStore.read(path),
         {:ok, events} <- EventLog.read(log_path, after_sequence: summary.cursor) do
      append_summary_segments(path, summary, events)
    else
      {:error, reason} = error -> maybe_record_failure(path, reason, error)
    end
  end

  defp append_summary_segments(_path, summary, []), do: {:ok, summary}

  defp append_summary_segments(path, summary, events) do
    with {:ok, execution} <- Config.codex_execution_for_profile(Config.settings!().runtime.summary_profile),
         {:ok, segments} <- summary_segments(events, execution) do
      cursor =
        events
        |> Enum.map(&Map.get(&1, :sequence, summary.cursor))
        |> Enum.filter(&is_integer/1)
        |> Enum.max(fn -> summary.cursor end)

      SummaryStore.write(path, %{
        summary
        | cursor: cursor,
          status: "ready",
          status_reason: nil,
          segments: summary.segments ++ segments
      })
    else
      {:error, reason} = error -> maybe_record_failure(path, reason, error)
    end
  end

  defp maybe_record_failure(path, reason, error) when is_binary(path) do
    _ = SummaryStore.fail(path, reason)
    error
  end

  defp maybe_record_failure(_path, _reason, error), do: error

  defp summary_segments(events, execution) do
    result =
      events
      |> Enum.chunk_every(@segment_size)
      |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
        case segment_for_events(chunk, execution) do
          {:ok, segment} -> {:cont, {:ok, [segment | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    case result do
      {:ok, segments} -> {:ok, Enum.reverse(segments)}
      {:error, _reason} = error -> error
    end
  end

  defp segment_for_events(events, execution) do
    first = List.first(events) || %{}
    last = List.last(events) || first

    with {:ok, summary} <- summarize_events(events, execution) do
      {:ok,
       %{
         source_start_sequence: Map.get(first, :sequence, 0),
         source_end_sequence: Map.get(last, :sequence, 0),
         started_at: Map.get(first, :timestamp),
         ended_at: Map.get(last, :timestamp),
         model: execution.profile_name,
         command: execution.command,
         prompt_version: @prompt_version,
         source_event_count: length(events),
         summary: summary
       }}
    end
  end

  defp summarize_events(events, execution) do
    ref = make_ref()
    caller = self()

    on_message = fn message -> send(caller, {ref, message}) end

    with {:ok, workspace} <- summary_workspace(),
         {:ok, _result} <-
           AppServer.run(workspace, summary_prompt(events), summary_issue(),
             codex_command: execution.command,
             codex_profile: execution.profile_name,
             dynamic_tools: false,
             runtime_kind: :native,
             on_message: on_message,
             tool_executor: fn tool, _arguments -> rejected_summary_tool_result(tool) end,
             turn_timeout_ms: Config.settings!().runtime.summary_timeout_ms
           ),
         messages = collect_messages(ref, []),
         {:ok, text} <- agent_summary_text(messages),
         {:ok, summary} <- decode_summary_output(text) do
      {:ok, summary}
    else
      {:error, reason} -> {:error, {:summary_spark_failed, reason}}
    end
  end

  defp summary_workspace do
    workspace = Path.join(Config.runtime_state_root(), "summary_workspace")

    with :ok <- File.mkdir_p(workspace) do
      {:ok, workspace}
    end
  end

  defp summary_issue do
    %Issue{
      id: "symphony-event-summary",
      identifier: "SUMMARY",
      title: "Summarize Symphony event log",
      description: "Summarize durable Symphony worker events.",
      state: "Summary",
      url: "",
      labels: []
    }
  end

  defp summary_prompt(events) do
    compact_events =
      events
      |> compact_streaming_events()
      |> Enum.map(&summary_event/1)

    """
    You are summarizing a Symphony worker event log for an operations dashboard.

    Return exactly one JSON object with this shape:
    {"summary":"one concise operational summary"}

    Constraints:
    - Do not use tools, shell commands, git, Linear, network access, or repository files.
    - Summarize only the events below.
    - Mention concrete blockers, approvals, failures, test results, or handoff state when present.
    - Keep the summary under 80 words.
    - Return JSON only. Do not wrap it in Markdown.

    Events:
    #{Json.encode_pretty!(compact_events)}
    """
  end

  defp summary_event(event) do
    %{
      sequence: Map.get(event, :sequence),
      timestamp: Map.get(event, :timestamp),
      event: Map.get(event, :event),
      message: event_sentence(event)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp rejected_summary_tool_result(tool) do
    %{
      "success" => false,
      "output" => "Summary runs are read-only and cannot call #{tool || "tools"}.",
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => "Summary runs are read-only and cannot call #{tool || "tools"}."
        }
      ]
    }
  end

  defp collect_messages(ref, acc) do
    receive do
      {^ref, message} -> collect_messages(ref, [message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp agent_summary_text(messages) do
    text =
      messages
      |> Enum.flat_map(&agent_message_delta/1)
      |> Enum.join()
      |> String.trim()

    case text do
      "" -> {:error, :missing_summary_output}
      value -> {:ok, value}
    end
  end

  defp agent_message_delta(message) when is_map(message) do
    payload = Map.get(message, :payload) || Map.get(message, "payload") || message
    method = map_value(payload, ["method", :method])

    if method in @agent_message_methods do
      case first_text(payload, delta_paths()) do
        text when is_binary(text) -> [text]
        _ -> []
      end
    else
      []
    end
  end

  defp agent_message_delta(_message), do: []

  defp decode_summary_output(text) when is_binary(text) do
    text
    |> candidate_json_strings()
    |> Enum.reduce_while({:error, :invalid_summary_output}, fn candidate, _acc ->
      case Json.decode(candidate) do
        {:ok, %{} = decoded} -> {:halt, summary_from_decoded_output(decoded)}
        _ -> {:cont, {:error, :invalid_summary_output}}
      end
    end)
  end

  defp summary_from_decoded_output(%{"summary" => summary}) when is_binary(summary) do
    summary = String.trim(summary)

    if summary == "" do
      {:error, :empty_summary_output}
    else
      {:ok, summary}
    end
  end

  defp summary_from_decoded_output(%{"segments" => segments}) when is_list(segments) do
    summary =
      segments
      |> Enum.map(fn
        %{"summary" => summary} when is_binary(summary) -> String.trim(summary)
        _ -> ""
      end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")
      |> String.trim()

    if summary == "" do
      {:error, :empty_summary_output}
    else
      {:ok, summary}
    end
  end

  defp summary_from_decoded_output(_decoded), do: {:error, :invalid_summary_output}

  defp candidate_json_strings(text) do
    trimmed = String.trim(text)

    fenced =
      trimmed
      |> String.replace_prefix("```json", "")
      |> String.replace_prefix("```", "")
      |> String.replace_suffix("```", "")
      |> String.trim()

    extracted =
      case Regex.run(~r/\{.*\}/s, trimmed) do
        [json] -> [json]
        _ -> []
      end

    [trimmed, fenced | extracted]
    |> Enum.uniq()
  end

  defp event_sentence(event) do
    event
    |> StatusDashboard.humanize_codex_message()
    |> case do
      message when is_binary(message) and message != "" ->
        message

      _ ->
        event |> Map.get(:event, "event") |> to_string()
    end
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp compact_streaming_events(events) do
    {compacted, group} =
      Enum.reduce(events, {[], nil}, fn event, {compacted, group} ->
        case streaming_chunk(event) do
          {:ok, label, chunk} ->
            append_streaming(compacted, group, event, label, chunk)

          :error ->
            {flush_streaming(compacted, group) ++ [event], nil}
        end
      end)

    flush_streaming(compacted, group)
  end

  defp append_streaming(compacted, %{label: label} = group, event, label, chunk) do
    {compacted, %{group | timestamp: Map.get(event, :timestamp) || group.timestamp, chunks: group.chunks ++ [chunk]}}
  end

  defp append_streaming(compacted, group, event, label, chunk) do
    {flush_streaming(compacted, group), %{event: Map.get(event, :event), timestamp: Map.get(event, :timestamp), label: label, chunks: [chunk]}}
  end

  defp flush_streaming(compacted, nil), do: compacted

  defp flush_streaming(compacted, group) do
    text =
      group.chunks
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")
      |> String.replace(~r/\s+([.,;:!?)}\]])/, "\\1")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    compacted ++ [%{event: group.event, timestamp: group.timestamp, message: "#{group.label}: #{text}"}]
  end

  defp streaming_chunk(%{message: message}) when is_binary(message) do
    case String.split(message, ": ", parts: 2) do
      ["agent message streaming", chunk] -> {:ok, "Agent message", chunk}
      ["reasoning summary streaming", chunk] -> {:ok, "Reasoning", chunk}
      ["reasoning text streaming", chunk] -> {:ok, "Reasoning", chunk}
      _ -> :error
    end
  end

  defp streaming_chunk(_event), do: :error

  defp first_text(payload, paths) do
    Enum.find_value(paths, &map_path(payload, &1))
  end

  defp map_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp map_value(_map, _keys), do: nil

  defp map_path(map, path) when is_map(map) and is_list(path) do
    Enum.reduce_while(path, map, fn key, acc ->
      case acc do
        %{} -> {:cont, Map.get(acc, key)}
        _ -> {:halt, nil}
      end
    end)
  end

  defp map_path(_map, _path), do: nil

  defp delta_paths do
    [
      ["params", "delta"],
      [:params, :delta],
      ["params", "textDelta"],
      [:params, :textDelta],
      ["params", "text"],
      [:params, :text],
      ["params", "content"],
      [:params, :content],
      ["params", "msg", "delta"],
      [:params, :msg, :delta],
      ["params", "msg", "textDelta"],
      [:params, :msg, :textDelta],
      ["params", "msg", "text"],
      [:params, :msg, :text],
      ["params", "msg", "content"],
      [:params, :msg, :content],
      ["params", "msg", "payload", "delta"],
      [:params, :msg, :payload, :delta],
      ["params", "msg", "payload", "textDelta"],
      [:params, :msg, :payload, :textDelta],
      ["params", "msg", "payload", "text"],
      [:params, :msg, :payload, :text],
      ["params", "msg", "payload", "content"],
      [:params, :msg, :payload, :content]
    ]
  end
end
