defmodule ReyCode.TUI.Keybindings do
  @moduledoc "Loads bounded action-to-chord overrides while preserving typed handlers."

  @max_file_bytes 32_768
  @max_action_count 64
  @max_chords_per_action 4
  @max_chord_bytes 32

  @type definition :: %{
          id: String.t(),
          label: String.t(),
          default_chords: [String.t()],
          handler: function()
        }

  @type resolved :: %{entries: [map()], errors: [String.t()], path: String.t()}

  @doc "Resolves built-in chords without reading a configuration file."
  @spec defaults([definition()]) :: resolved()
  def defaults(definitions) do
    entries = Enum.map(definitions, &Map.put(&1, :chords, &1.default_chords))
    %{entries: entries, errors: [], path: "built-in defaults"}
  end

  @doc "Resolves defaults with an optional JSON action map; malformed files fail to defaults."
  @spec resolve([definition()], String.t()) :: resolved()
  def resolve(definitions, path) when is_list(definitions) and is_binary(path) do
    defaults = Map.new(definitions, &{&1.id, &1.default_chords})

    case read_overrides(path, defaults) do
      {:ok, overrides, errors} ->
        entries = Enum.map(definitions, &Map.put(&1, :chords, Map.fetch!(overrides, &1.id)))
        %{entries: entries, errors: errors, path: path}

      {:error, reason} ->
        entries = Enum.map(definitions, &Map.put(&1, :chords, &1.default_chords))
        %{entries: entries, errors: [error_message(reason)], path: path}
    end
  end

  @doc "Converts resolved actions into Breeze global keybinding tuples."
  @spec breeze_bindings(resolved()) :: [{String.t(), String.t(), function()}]
  def breeze_bindings(%{entries: entries}) do
    Enum.flat_map(entries, fn entry ->
      Enum.map(entry.chords, &{&1, entry.label, entry.handler})
    end)
  end

  defp read_overrides(path, defaults) do
    case File.read(path) do
      {:ok, bytes} when byte_size(bytes) <= @max_file_bytes -> decode_overrides(bytes, defaults)
      {:ok, _bytes} -> {:error, :keybindings_file_too_large}
      {:error, :enoent} -> {:ok, defaults, []}
      {:error, reason} -> {:error, {:keybindings_unreadable, reason}}
    end
  end

  defp decode_overrides(bytes, defaults) do
    with {:ok, decoded} <- Jason.decode(bytes),
         true <- is_map(decoded) || {:error, :keybindings_not_an_object},
         true <- map_size(decoded) <= @max_action_count || {:error, :too_many_keybindings} do
      Enum.reduce(decoded, {:ok, defaults, []}, &apply_override/2)
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_keybindings_json}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_override({action_id, raw_chords}, {:ok, bindings, errors}) do
    if Map.has_key?(bindings, action_id) do
      case normalize_chords(raw_chords) do
        {:ok, chords} ->
          {:ok, Map.put(bindings, action_id, chords), errors}

        {:error, reason} ->
          {:ok, bindings, errors ++ ["#{action_id}: #{error_message(reason)}"]}
      end
    else
      {:ok, bindings, errors ++ ["Unknown action #{action_id}"]}
    end
  end

  defp normalize_chords(chord) when is_binary(chord), do: normalize_chords([chord])

  defp normalize_chords(chords)
       when is_list(chords) and length(chords) <= @max_chords_per_action do
    if Enum.all?(chords, &valid_chord?/1),
      do: {:ok, Enum.uniq(chords)},
      else: {:error, :invalid_chord}
  end

  defp normalize_chords(_chords), do: {:error, :invalid_chord_list}

  defp valid_chord?(chord),
    do: is_binary(chord) and chord != "" and byte_size(chord) <= @max_chord_bytes

  defp error_message(:keybindings_file_too_large), do: "Keybindings file exceeds 32 KB"
  defp error_message(:keybindings_not_an_object), do: "Keybindings JSON must be an object"
  defp error_message(:too_many_keybindings), do: "Keybindings file has too many actions"
  defp error_message(:invalid_keybindings_json), do: "Keybindings file is invalid JSON"
  defp error_message(:invalid_chord), do: "Chord must be a non-empty bounded string"

  defp error_message(:invalid_chord_list),
    do: "Use one chord string or at most four chord strings"

  defp error_message({:keybindings_unreadable, reason}),
    do: "Keybindings file unreadable: #{reason}"

  defp error_message(reason), do: to_string(reason)
end
