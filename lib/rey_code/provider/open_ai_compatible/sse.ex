defmodule ReyCode.Provider.OpenAICompatible.SSE do
  @moduledoc false

  defstruct buffer: ""

  @type t :: %__MODULE__{buffer: binary()}
  @type event :: {:text, binary()} | {:usage, map()} | :done | :ignore

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec feed(t(), binary()) :: {[event()], t()}
  def feed(%__MODULE__{buffer: buffer}, data) do
    {complete, rest} = split_events(buffer <> data)
    events = Enum.flat_map(complete, &parse_event/1)
    {events, %__MODULE__{buffer: rest}}
  end

  defp split_events(buffer) do
    case String.split(buffer, ~r/\r?\n\r?\n/) do
      [] -> {[], ""}
      [single] -> {[], single}
      parts -> {Enum.drop(parts, -1), List.last(parts)}
    end
  end

  defp parse_event(raw) do
    raw
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.map(&String.trim_leading/1)
    |> Enum.filter(&String.starts_with?(&1, "data:"))
    |> Enum.map(&decode_payload/1)
    |> List.flatten()
  end

  defp decode_payload(line) do
    payload = line |> String.trim_leading("data:") |> String.trim()
    decode_data(payload)
  end

  defp decode_data("[DONE]"), do: :done

  defp decode_data(payload) do
    case Jason.decode(payload) do
      {:ok, %{"choices" => choices} = data} when is_list(choices) ->
        content_events(choices) ++ usage_event(data)

      {:ok, _other} ->
        [:ignore]

      {:error, _reason} ->
        [:ignore]
    end
  end

  defp content_events(choices) do
    Enum.flat_map(choices, fn choice ->
      case get_in(choice, ["delta", "content"]) do
        content when is_binary(content) and content != "" -> [{:text, content}]
        _ -> []
      end
    end)
  end

  defp usage_event(%{"usage" => usage}) when is_map(usage), do: [{:usage, usage}]
  defp usage_event(_data), do: []
end
