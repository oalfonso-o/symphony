defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000
  @stream_labels %{
    "agent message streaming" => "Agent message",
    "agent message content streaming" => "Agent message",
    "reasoning summary streaming" => "Reasoning",
    "reasoning text streaming" => "Reasoning",
    "reasoning streaming" => "Reasoning",
    "reasoning content streaming" => "Reasoning",
    "plan streaming" => "Plan",
    "command output streaming" => "Command output",
    "file change output streaming" => "File change output"
  }

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())
      |> assign(:expanded_issues, MapSet.new())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("toggle-issue", %{"issue" => issue_identifier}, socket) do
    expanded_issues = socket.assigns.expanded_issues

    expanded_issues =
      if MapSet.member?(expanded_issues, issue_identifier) do
        MapSet.delete(expanded_issues, issue_identifier)
      else
        MapSet.put(expanded_issues, issue_identifier)
      end

    {:noreply, assign(socket, :expanded_issues, expanded_issues)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for entry <- @payload.running do %>
                    <tr>
                      <td>
                        <div class="issue-stack">
                          <span class="issue-id"><%= entry.issue_identifier %></span>
                          <div class="link-row">
                            <button
                              type="button"
                              class="subtle-button"
                              phx-click="toggle-issue"
                              phx-value-issue={entry.issue_identifier}
                            >
                              <%= if expanded_issue?(@expanded_issues, entry.issue_identifier), do: "Hide details", else: "Show details" %>
                            </button>
                            <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON</a>
                          </div>
                        </div>
                      </td>
                      <td>
                        <span class={state_badge_class(entry.state)}>
                          <%= entry.state %>
                        </span>
                      </td>
                      <td>
                        <div class="session-stack">
                          <%= if entry.session_id do %>
                            <button
                              type="button"
                              class="subtle-button"
                              data-label="Copy ID"
                              data-copy={entry.session_id}
                              onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                            >
                              Copy ID
                            </button>
                          <% else %>
                            <span class="muted">n/a</span>
                          <% end %>
                        </div>
                      </td>
                      <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                      <td>
                        <div class="detail-stack">
                          <span
                            class="event-text"
                            title={display_last_message(entry)}
                          ><%= display_last_message(entry) %></span>
                          <span class="muted event-meta">
                            <%= entry.last_event || "n/a" %>
                            <%= if entry.last_event_at do %>
                              · <span class="mono numeric"><%= entry.last_event_at %></span>
                            <% end %>
                          </span>
                        </div>
                      </td>
                      <td>
                        <div class="token-stack numeric">
                          <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                          <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                        </div>
                      </td>
                    </tr>
                    <tr :if={expanded_issue?(@expanded_issues, entry.issue_identifier)} class="expanded-row">
                      <td colspan="6">
                        <div class="issue-detail-panel">
                          <div class="detail-grid">
                            <div>
                              <span class="detail-label">Workspace</span>
                              <span class="mono detail-value"><%= entry.workspace_path || "n/a" %></span>
                            </div>
                            <div>
                              <span class="detail-label">Session</span>
                              <span class="mono detail-value"><%= entry.session_id || "n/a" %></span>
                            </div>
                            <div>
                              <span class="detail-label">Last event</span>
                              <span class="detail-value"><%= display_last_message(entry) %></span>
                            </div>
                            <div>
                              <span class="detail-label">JSON</span>
                              <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}><%= entry.issue_identifier %> API payload</a>
                            </div>
                          </div>

                          <div class="event-log">
                            <div class="event-log-header">
                              <span>Recent Codex events</span>
                              <span class="muted"><%= length(recent_events_for_display(entry.recent_events)) %> shown</span>
                            </div>
                            <%= if (entry.recent_events || []) == [] do %>
                              <p class="empty-state">No Codex events captured yet.</p>
                            <% else %>
                              <ol class="event-list">
                                <li :for={event <- recent_events_for_display(entry.recent_events)} class="event-row">
                                  <time class="mono event-time"><%= event.at || "n/a" %></time>
                                  <span class="event-summary"><%= event.message || to_string(event.event || "n/a") %></span>
                                </li>
                              </ol>
                            <% end %>
                          </div>
                        </div>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp expanded_issue?(expanded_issues, issue_identifier) do
    MapSet.member?(expanded_issues, issue_identifier)
  end

  defp recent_events_for_display(events) when is_list(events) do
    events
    |> compact_streaming_events()
    |> Enum.reverse()
    |> Enum.take(30)
  end

  defp recent_events_for_display(_events), do: []

  defp display_last_message(entry) do
    case recent_events_for_display(Map.get(entry, :recent_events, [])) do
      [%{message: message} | _] when is_binary(message) and message != "" ->
        message

      _ ->
        entry.last_message || to_string(entry.last_event || "n/a")
    end
  end

  defp compact_streaming_events(events) do
    {compacted, streaming_group} =
      Enum.reduce(events, {[], nil}, fn event, {compacted, streaming_group} ->
        case streaming_event(event) do
          {:ok, label, chunk} ->
            append_streaming_event(compacted, streaming_group, event, label, chunk)

          :error ->
            compacted = flush_streaming_group(compacted, streaming_group)
            {compacted ++ [event], nil}
        end
      end)

    flush_streaming_group(compacted, streaming_group)
  end

  defp append_streaming_event(compacted, %{label: label} = group, event, label, chunk) do
    group = %{group | at: event.at || group.at, chunks: group.chunks ++ [chunk], count: group.count + 1}
    {compacted, group}
  end

  defp append_streaming_event(compacted, streaming_group, event, label, chunk) do
    compacted = flush_streaming_group(compacted, streaming_group)
    {compacted, %{at: event.at, event: event.event, label: label, chunks: [chunk], count: 1}}
  end

  defp flush_streaming_group(compacted, nil), do: compacted

  defp flush_streaming_group(compacted, %{at: at, event: event, label: label, chunks: chunks, count: count}) do
    message =
      case compact_streaming_text(chunks) do
        "" -> "#{label} streaming (#{count} chunks)"
        text -> "#{label}: #{text}"
      end

    compacted ++ [%{at: at, event: event, message: message}]
  end

  defp streaming_event(%{message: message}) when is_binary(message) do
    case String.split(message, ": ", parts: 2) do
      [prefix, chunk] -> stream_label(prefix, chunk)
      [prefix] -> stream_label(prefix, "")
    end
  end

  defp streaming_event(_event), do: :error

  defp stream_label(prefix, chunk) do
    case Map.fetch(@stream_labels, prefix) do
      {:ok, label} -> {:ok, label, chunk}
      :error -> :error
    end
  end

  defp compact_streaming_text(chunks) do
    chunks
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
    |> String.replace(~r/\s+([.,;:!?)}\]])/, "\\1")
    |> String.replace(~r/([({\[])\s+/, "\\1")
    |> String.replace(~r/\s+(['’])\s*/, "\\1")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
