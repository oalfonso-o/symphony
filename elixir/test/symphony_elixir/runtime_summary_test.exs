defmodule SymphonyElixir.RuntimeSummaryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config
  alias SymphonyElixir.Runtime.{EventLog, EventSummarizer, SummaryStore}

  test "event summarizer uses the configured Spark profile without dynamic tools" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-summary-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      runtime_state_root = Path.join(workspace_root, ".symphony_runtime")
      event_log_path = Path.join([runtime_state_root, "events", "run-summary.jsonl"])
      summary_path = Path.join([runtime_state_root, "summaries", "run-summary.json"])
      codex_binary = Path.join(test_root, "fake-spark-codex")
      trace_file = Path.join(test_root, "summary.trace")
      previous_trace = System.get_env("SYMP_TEST_SUMMARY_TRACE")

      on_exit(fn -> restore_env("SYMP_TEST_SUMMARY_TRACE", previous_trace) end)

      System.put_env("SYMP_TEST_SUMMARY_TRACE", trace_file)
      File.mkdir_p!(workspace_root)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SUMMARY_TRACE:-/tmp/symphony-summary.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-summary"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-summary"}}}'
            printf '%s\\n' '{"method":"item/agentMessage/delta","params":{"delta":"{\\"summary\\":\\"Spark saw tests pass and no blocker.\\"}"}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        runtime_state_root: runtime_state_root,
        runtime_summary_profile: "spark",
        runtime_summary_timeout_ms: 1_000,
        codex_profiles: %{
          "spark" => %{
            "command" => "#{codex_binary} app-server"
          }
        }
      )

      assert {:ok, _event} =
               EventLog.append(event_log_path, %{
                 event: :worker_started,
                 message: "worker started",
                 timestamp: ~U[2026-05-22 10:00:00Z]
               })

      assert {:ok, _event} =
               EventLog.append(event_log_path, %{
                 event: :notification,
                 message: "agent message streaming: tests passed",
                 timestamp: ~U[2026-05-22 10:01:00Z]
               })

      assert {:ok, summary} =
               EventSummarizer.summarize_entry(%{
                 event_log_path: event_log_path,
                 summary_path: summary_path
               })

      assert summary.cursor == 1
      assert [%{summary: "Spark saw tests pass and no blocker."} = segment] = summary.segments
      assert segment.model == "spark"
      assert segment.command == "#{codex_binary} app-server"
      assert segment.source_event_count == 2

      trace_payloads =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&(&1 |> String.trim_leading("JSON:") |> Jason.decode!()))

      thread_start = Enum.find(trace_payloads, &(&1["method"] == "thread/start"))
      assert get_in(thread_start, ["params", "dynamicTools"]) == []

      turn_start = Enum.find(trace_payloads, &(&1["method"] == "turn/start"))
      prompt = get_in(turn_start, ["params", "input", Access.at(0), "text"])
      assert prompt =~ "Return exactly one JSON object"
      assert prompt =~ "tests passed"
    after
      File.rm_rf(test_root)
    end
  end

  test "event summarizer expands tilde runtime paths before launching Spark" do
    root_name = "symphony-elixir-runtime-summary-tilde-#{System.unique_integer([:positive])}"

    test_root =
      Path.join(
        System.user_home!(),
        root_name
      )

    try do
      previous_trace = System.get_env("SYMP_TEST_SUMMARY_TRACE")
      codex_binary = Path.join(test_root, "fake-spark-codex")
      trace_file = Path.join(test_root, "summary.trace")
      runtime_state_root = Path.join([test_root, "workspaces", ".symphony_runtime"])
      event_log_path = Path.join([runtime_state_root, "events", "run-summary-tilde.jsonl"])
      summary_path = Path.join([runtime_state_root, "summaries", "run-summary-tilde.json"])
      summary_workspace = Path.join(runtime_state_root, "summary_workspace")

      on_exit(fn ->
        restore_env("SYMP_TEST_SUMMARY_TRACE", previous_trace)
      end)

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SUMMARY_TRACE", trace_file)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SUMMARY_TRACE:-/tmp/symphony-summary.trace}"
      printf 'PWD:%s\\n' "$(pwd)" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-summary"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-summary"}}}'
            printf '%s\\n' '{"method":"item/agentMessage/delta","params":{"delta":"{\\"summary\\":\\"Spark summarized tilde workspace events.\\"}"}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "~/#{root_name}/workspaces",
        runtime_state_root: nil,
        runtime_summary_profile: "spark",
        runtime_summary_timeout_ms: 1_000,
        codex_profiles: %{
          "spark" => %{
            "command" => "#{codex_binary} app-server"
          }
        }
      )

      assert Config.runtime_state_root() == runtime_state_root

      assert {:ok, _event} =
               EventLog.append(event_log_path, %{
                 event: :notification,
                 message: "agent message streaming: tests passed",
                 timestamp: ~U[2026-05-22 10:01:00Z]
               })

      assert {:ok, summary} =
               EventSummarizer.summarize_entry(%{
                 event_log_path: event_log_path,
                 summary_path: summary_path
               })

      assert [%{summary: "Spark summarized tilde workspace events."}] = summary.segments
      assert File.dir?(summary_workspace)
      assert File.read!(trace_file) =~ "PWD:#{summary_workspace}"
    after
      File.rm_rf(test_root)
    end
  end

  test "event summarizer fails visibly instead of falling back to the strong command when Spark is missing" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-summary-missing-profile-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      runtime_state_root = Path.join(workspace_root, ".symphony_runtime")
      event_log_path = Path.join([runtime_state_root, "events", "run-missing-profile.jsonl"])
      summary_path = Path.join([runtime_state_root, "summaries", "run-missing-profile.json"])

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        runtime_state_root: runtime_state_root,
        runtime_summary_profile: "spark",
        codex_command: "codex app-server",
        codex_profiles: %{}
      )

      assert {:ok, _event} =
               EventLog.append(event_log_path, %{
                 event: :worker_started,
                 message: "worker started"
               })

      assert {:error, {:missing_codex_profile, "spark"}} =
               EventSummarizer.summarize_entry(%{
                 event_log_path: event_log_path,
                 summary_path: summary_path
               })

      assert {:ok, failed_summary} = SummaryStore.read(summary_path)
      assert failed_summary.cursor == -1
      assert failed_summary.status == "failed"
      assert failed_summary.status_reason =~ "missing_codex_profile"
      assert failed_summary.segments == []
    after
      File.rm_rf(test_root)
    end
  end
end
