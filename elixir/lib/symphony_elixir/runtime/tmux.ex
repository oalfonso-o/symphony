defmodule SymphonyElixir.Runtime.Tmux do
  @moduledoc """
  tmux-backed local app-server transport.
  """

  alias SymphonyElixir.Config

  @spec enabled?() :: boolean()
  def enabled?, do: Config.settings!().runtime.tmux_enabled == true

  @spec start_app_server(Path.t(), String.t(), keyword()) :: {:ok, port(), map()} | {:error, term()}
  def start_app_server(workspace, command, opts \\ [])
      when is_binary(workspace) and is_binary(command) and is_list(opts) do
    with {:ok, tmux} <- tmux_executable(),
         {:ok, bash} <- bash_executable(),
         {:ok, paths} <- prepare_transport_paths(Keyword.get(opts, :run_id)),
         {:ok, target} <- start_tmux_target(tmux, workspace, command, paths, opts),
         {:ok, port} <- start_bridge_port(bash, paths) do
      {:ok, port,
       %{
         runtime_kind: "tmux",
         tmux_target: target,
         tmux_input_path: paths.input,
         tmux_output_path: paths.output,
         tmux_stderr_path: paths.stderr
       }}
    end
  end

  @spec target_live?(String.t()) :: boolean()
  def target_live?(target) when is_binary(target) do
    case tmux_executable() do
      {:ok, tmux} ->
        case System.cmd(tmux, ["has-session", "-t", target], stderr_to_stdout: true) do
          {_output, 0} -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  @spec stop_target(String.t()) :: :ok | {:error, term()}
  def stop_target(target) when is_binary(target) do
    with {:ok, tmux} <- tmux_executable() do
      case System.cmd(tmux, ["kill-window", "-t", target], stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, status} -> {:error, {:tmux_kill_window_failed, status, output}}
      end
    end
  end

  @spec session_name() :: String.t()
  def session_name do
    case Config.settings!().runtime.tmux_session do
      session when is_binary(session) and session != "" ->
        session

      _ ->
        root =
          Config.settings!().workspace.root
          |> Path.basename()
          |> sanitize_name()

        "symphony-" <> root
    end
  end

  @spec classify_target(String.t() | nil) :: {String.t(), String.t() | nil}
  def classify_target(target) when is_binary(target) do
    if target_live?(target) do
      {"detached_running", nil}
    else
      {"dead", "tmux target is missing"}
    end
  end

  def classify_target(_target), do: {"unknown", "no tmux target recorded"}

  defp start_tmux_target(tmux, workspace, command, paths, opts) do
    session = session_name()
    window = opts |> Keyword.get(:run_id, "run") |> sanitize_name() |> String.slice(0, 80)
    target = "#{session}:#{window}"
    pane_command = pane_command(workspace, command, paths)

    result =
      if session_exists?(tmux, session) do
        System.cmd(tmux, ["new-window", "-d", "-t", session, "-n", window, pane_command], stderr_to_stdout: true)
      else
        System.cmd(tmux, ["new-session", "-d", "-s", session, "-n", window, pane_command], stderr_to_stdout: true)
      end

    case result do
      {_output, 0} ->
        {:ok, target}

      {output, status} ->
        {:error, {:tmux_start_failed, status, output}}
    end
  end

  defp start_bridge_port(bash, paths) do
    bridge_command = "cat #{shell_escape(paths.output)} & cat > #{shell_escape(paths.input)}; wait"

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(bash)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [~c"-lc", String.to_charlist(bridge_command)],
          line: 1_048_576
        ]
      )

    {:ok, port}
  end

  defp prepare_transport_paths(run_id) do
    run_id = run_id || "run-#{System.unique_integer([:positive])}"
    root = Path.join([Config.runtime_state_root(), "tmux", sanitize_name(run_id)])

    paths = %{
      root: root,
      input: Path.join(root, "stdin.fifo"),
      output: Path.join(root, "stdout.fifo"),
      stderr: Path.join(root, "stderr.log")
    }

    with :ok <- File.mkdir_p(root),
         :ok <- ensure_fifo(paths.input),
         :ok <- ensure_fifo(paths.output) do
      {:ok, paths}
    end
  end

  defp ensure_fifo(path) do
    File.rm(path)

    case System.cmd("mkfifo", [path], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:mkfifo_failed, path, status, output}}
    end
  end

  defp pane_command(workspace, command, paths) do
    [
      "cd #{shell_escape(workspace)}",
      "exec 3<>#{shell_escape(paths.input)}",
      "exec #{command} < #{shell_escape(paths.input)} > #{shell_escape(paths.output)} 2>> #{shell_escape(paths.stderr)}"
    ]
    |> Enum.join(" && ")
  end

  defp session_exists?(tmux, session) do
    case System.cmd(tmux, ["has-session", "-t", session], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  end

  defp tmux_executable do
    case System.find_executable("tmux") do
      nil -> {:error, :tmux_not_found}
      path -> {:ok, path}
    end
  end

  defp bash_executable do
    case System.find_executable("bash") do
      nil -> {:error, :bash_not_found}
      path -> {:ok, path}
    end
  end

  defp sanitize_name(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_.-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "run"
      name -> name
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
