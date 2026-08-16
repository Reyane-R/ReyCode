defmodule ReyCode.JSON do
  @moduledoc "JSON boundary helpers for normalized durable data."

  @doc "Round-trips a value through JSON to normalize keys and supported values."
  @spec normalize(term()) :: term()
  def normalize(value), do: value |> Jason.encode!() |> Jason.decode!()
end
