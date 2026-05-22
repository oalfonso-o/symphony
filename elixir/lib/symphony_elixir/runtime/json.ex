defmodule SymphonyElixir.Runtime.Json do
  @moduledoc false

  @spec encode!(term()) :: String.t()
  def encode!(value) do
    value
    |> to_json_value()
    |> Jason.encode!()
  end

  @spec encode_pretty!(term()) :: String.t()
  def encode_pretty!(value) do
    value
    |> to_json_value()
    |> Jason.encode!(pretty: true)
  end

  @spec decode(String.t()) :: {:ok, term()} | {:error, term()}
  def decode(value) when is_binary(value), do: Jason.decode(value)

  @spec to_json_value(term()) :: term()
  def to_json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def to_json_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def to_json_value(%Date{} = value), do: Date.to_iso8601(value)
  def to_json_value(%Time{} = value), do: Time.to_iso8601(value)

  def to_json_value(%_{} = value) do
    value
    |> Map.from_struct()
    |> to_json_value()
  end

  def to_json_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), to_json_value(nested)} end)
  end

  def to_json_value(value) when is_list(value), do: Enum.map(value, &to_json_value/1)
  def to_json_value(value) when is_atom(value), do: Atom.to_string(value)
  def to_json_value(value), do: value
end
