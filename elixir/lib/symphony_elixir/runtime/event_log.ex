defmodule SymphonyElixir.Runtime.EventLog do
  @moduledoc """
  Durable JSONL event logs for worker runs.
  """

  alias SymphonyElixir.Runtime.Json

  @type event :: %{
          optional(:sequence) => non_neg_integer(),
          optional(:timestamp) => DateTime.t() | String.t(),
          optional(:event) => atom() | String.t(),
          optional(:message) => term()
        }

  @spec append(Path.t(), map()) :: {:ok, map()} | {:error, term()}
  def append(path, event) when is_binary(path) and is_map(event) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, event} <- normalize_event(path, event),
         :ok <- File.write(path, Json.encode!(event) <> "\n", [:append]) do
      {:ok, event}
    end
  end

  @spec tail(Path.t(), non_neg_integer()) :: {:ok, [map()]} | {:error, term()}
  def tail(path, limit) when is_binary(path) and is_integer(limit) and limit >= 0 do
    with {:ok, events} <- read(path) do
      {:ok, Enum.take(events, -limit)}
    end
  end

  @spec read(Path.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def read(path, opts \\ []) when is_binary(path) and is_list(opts) do
    after_sequence = Keyword.get(opts, :after_sequence)

    case File.read(path) do
      {:ok, content} ->
        events =
          content
          |> String.split("\n", trim: true)
          |> Enum.flat_map(&decode_line/1)
          |> Enum.filter(&after_sequence?(&1, after_sequence))

        {:ok, events}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec next_sequence(Path.t()) :: non_neg_integer()
  def next_sequence(path) when is_binary(path) do
    case read(path) do
      {:ok, events} ->
        events
        |> Enum.map(&Map.get(&1, :sequence, -1))
        |> Enum.filter(&is_integer/1)
        |> Enum.max(fn -> -1 end)
        |> Kernel.+(1)

      {:error, _reason} ->
        0
    end
  end

  defp normalize_event(path, event) do
    normalized =
      event
      |> Map.put_new(:sequence, next_sequence(path))
      |> Map.put_new(:timestamp, DateTime.utc_now())

    {:ok, normalized}
  end

  defp decode_line(line) when is_binary(line) do
    case Json.decode(line) do
      {:ok, %{} = event} -> [atomize_event(event)]
      _ -> []
    end
  end

  defp atomize_event(event) do
    %{
      sequence: integer_value(Map.get(event, "sequence")),
      timestamp: Map.get(event, "timestamp"),
      event: Map.get(event, "event"),
      message: Map.get(event, "message"),
      payload: Map.get(event, "payload"),
      raw: Map.get(event, "raw"),
      metadata: Map.get(event, "metadata")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp after_sequence?(_event, nil), do: true

  defp after_sequence?(event, after_sequence) when is_integer(after_sequence) do
    case Map.get(event, :sequence) do
      sequence when is_integer(sequence) -> sequence > after_sequence
      _ -> false
    end
  end

  defp after_sequence?(_event, _after_sequence), do: true

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _rest} -> integer
      :error -> nil
    end
  end

  defp integer_value(_value), do: nil
end
