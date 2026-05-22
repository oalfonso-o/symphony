defmodule SymphonyElixir.Runtime.SummaryStore do
  @moduledoc """
  Persisted summary state for durable worker event logs.
  """

  alias SymphonyElixir.Runtime.Json

  @empty %{
    cursor: -1,
    status: "ready",
    status_reason: nil,
    schema_version: 1,
    segments: []
  }

  @type summary :: map()

  @spec empty() :: summary()
  def empty, do: @empty

  @spec read(Path.t() | nil) :: {:ok, summary()} | {:error, term()}
  def read(nil), do: {:ok, empty()}

  def read(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        decode_summary(content)

      {:error, :enoent} ->
        {:ok, empty()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_summary(content) do
    case Json.decode(content) do
      {:ok, %{} = decoded} -> {:ok, normalize(decoded)}
      {:error, %Jason.DecodeError{} = error} -> {:error, {:malformed_summary, Exception.message(error)}}
      _ -> {:error, :invalid_summary}
    end
  end

  @spec write(Path.t(), summary()) :: {:ok, summary()} | {:error, term()}
  def write(path, summary) when is_binary(path) and is_map(summary) do
    normalized = normalize(summary)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Json.encode_pretty!(normalized) <> "\n") do
      {:ok, normalized}
    end
  end

  @spec fail(Path.t(), term()) :: {:ok, summary()} | {:error, term()}
  def fail(path, reason) when is_binary(path) do
    with {:ok, summary} <- read(path) do
      write(path, %{summary | status: "failed", status_reason: inspect(reason)})
    end
  end

  defp normalize(summary) when is_map(summary) do
    %{
      cursor: integer(summary["cursor"] || summary[:cursor], -1),
      status: to_string(summary["status"] || summary[:status] || "ready"),
      status_reason: summary["status_reason"] || summary[:status_reason],
      schema_version: integer(summary["schema_version"] || summary[:schema_version], 1),
      segments: normalize_segments(summary["segments"] || summary[:segments] || [])
    }
  end

  defp normalize_segments(segments) when is_list(segments), do: Enum.map(segments, &normalize_segment/1)
  defp normalize_segments(_segments), do: []

  defp normalize_segment(segment) when is_map(segment) do
    %{
      source_start_sequence: integer(segment_value(segment, "source_start_sequence", :source_start_sequence), 0),
      source_end_sequence: integer(segment_value(segment, "source_end_sequence", :source_end_sequence), 0),
      started_at: segment_value(segment, "started_at", :started_at),
      ended_at: segment_value(segment, "ended_at", :ended_at),
      model: segment_value(segment, "model", :model),
      command: segment_value(segment, "command", :command),
      prompt_version: segment_value(segment, "prompt_version", :prompt_version),
      source_event_count: integer(segment_value(segment, "source_event_count", :source_event_count), 0),
      summary: segment_value(segment, "summary", :summary, "")
    }
  end

  defp normalize_segment(_segment), do: normalize_segment(%{})

  defp segment_value(segment, string_key, atom_key, default \\ nil) do
    case Map.get(segment, string_key) do
      nil -> Map.get(segment, atom_key, default)
      value -> value
    end
  end

  defp integer(value, _default) when is_integer(value), do: value

  defp integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _rest} -> integer
      :error -> default
    end
  end

  defp integer(_value, default), do: default
end
