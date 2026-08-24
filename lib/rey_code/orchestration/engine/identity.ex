defmodule ReyCode.Orchestration.Engine.Identity do
  @moduledoc "Pure helpers for generating aggregate IDs and room slugs."

  alias ReyCode.Orchestration.Projection

  @doc "Generates a prefixed, timestamped aggregate ID."
  @spec new_id(String.t()) :: String.t()
  def new_id(prefix) do
    timestamp = System.system_time(:millisecond)
    unique = System.unique_integer([:positive, :monotonic])
    "#{prefix}-#{timestamp}-#{unique}"
  end

  @doc "Normalizes a title into a lowercase URL-safe slug."
  @spec slugify(term()) :: String.t()
  def slugify(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "room"
      slug -> slug
    end
  end

  @doc "Disambiguates a base slug against the room slugs in a projection."
  @spec unique_slug(String.t(), Projection.t()) :: String.t()
  def unique_slug(base, projection) do
    used = MapSet.new(projection.rooms, fn {_id, room} -> room.slug end)

    Stream.iterate(1, &(&1 + 1))
    |> Enum.find_value(fn
      1 ->
        if not MapSet.member?(used, base), do: base

      suffix ->
        candidate = "#{base}-#{suffix}"
        if not MapSet.member?(used, candidate), do: candidate
    end)
  end
end
