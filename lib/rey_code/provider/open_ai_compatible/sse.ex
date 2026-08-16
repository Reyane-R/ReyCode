defmodule ReyCode.Provider.OpenAICompatible.SSE do
  @moduledoc false

  defstruct buffer: "", tools: %{}

  @type t :: %__MODULE__{buffer: binary(), tools: map()}
  @type tool_event_kind :: :tool_started | :tool_completed
  @type event ::
          {:text, binary()}
          | {:usage, map()}
          | {tool_event_kind, binary(), term()}
          | :done
          | :ignore

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec feed(t(), binary()) :: {[event()], t()}
  def feed(%__MODULE__{buffer: buffer, tools: tools}, data) do
    {complete, rest} = split_events(buffer <> data)

    {events, tools} =
      Enum.reduce(complete, {[], tools}, fn raw, {acc, current_tools} ->
        {next_events, next_tools} = parse_event(raw, current_tools)
        {acc ++ next_events, next_tools}
      end)

    {events, %__MODULE__{buffer: rest, tools: tools}}
  end

  defp split_events(buffer) do
    case String.split(buffer, ~r/\r?\n\r?\n/) do
      [] -> {[], ""}
      [single] -> {[], single}
      parts -> {Enum.drop(parts, -1), List.last(parts)}
    end
  end

  defp parse_event(raw, tools) do
    data_lines =
      raw
      |> String.split(~r/\r?\n/, trim: true)
      |> Enum.map(&parse_data_line/1)
      |> Enum.reject(&is_nil/1)

    if data_lines == [] do
      {[], tools}
    else
      decode_payload(data_lines, tools)
    end
  end

  defp decode_payload(data_lines, tools) when is_list(data_lines) do
    data_lines
    |> Enum.join("\n")
    |> decode_payload(tools)
  end

  defp decode_payload(payload, tools) when is_binary(payload) do
    payload = String.trim(payload)
    decode_data(payload, tools)
  end

  defp parse_data_line(line) do
    line = String.trim_leading(line)

    if String.starts_with?(line, "data:") do
      payload = line |> String.trim_leading("data:") |> String.trim()
      if payload == "", do: nil, else: payload
    end
  end

  defp decode_data("[DONE]", tools), do: {[:done], tools}

  defp decode_data(payload, tools) do
    case Jason.decode(payload) do
      {:ok, %{"choices" => choices} = data} when is_list(choices) ->
        parse_choices(choices, data["usage"], tools)

      {:ok, _other} ->
        {[:ignore], tools}

      {:error, _reason} ->
        {[:ignore], tools}
    end
  end

  defp parse_choices(choices, usage, tools) do
    {events, tools} =
      Enum.reduce(choices, {[], tools}, fn choice, {acc, current_tools} ->
        {choice_events, next_tools} = parse_choice(choice, current_tools)
        {acc ++ choice_events, next_tools}
      end)

    {events ++ usage_events(usage), tools}
  end

  defp parse_choice(choice, tools) do
    delta = choice["delta"] || %{}
    finish_reason = choice["finish_reason"]

    {content_events, tools} = content_events(delta, tools)
    {tool_events, tools} = tool_events(delta["tool_calls"], tools)
    {completion_events, tools} = complete_tool_state_if_needed(tools, finish_reason)

    {content_events ++ tool_events ++ completion_events, tools}
  end

  defp complete_tool_state_if_needed(tools, finish_reason) do
    if tool_calls_finished?(finish_reason), do: complete_tool_calls(tools), else: {[], tools}
  end

  defp tool_events(tool_calls, tools) when is_list(tool_calls) do
    tool_calls
    |> Enum.sort_by(&tool_call_sort_key/1)
    |> Enum.reduce({[], tools}, fn tool_call, {events, current_tools} ->
      {next_events, next_tools} = parse_tool_call(tool_call, current_tools)
      {events ++ next_events, next_tools}
    end)
  end

  defp tool_events(_tool_calls, tools), do: {[], tools}

  defp content_events(%{"content" => content}, tools)
       when is_binary(content) and content != "" do
    {[{:text, content}], tools}
  end

  defp content_events(_delta, tools), do: {[], tools}

  defp parse_tool_call(call, tools) when is_map(call) do
    parse_tool_call(tool_key(call), call, tools)
  end

  defp parse_tool_call(key, call, tools) when is_binary(key) do
    current = Map.get(tools, key, %{})
    next = merge_tool_state(current, call)
    tool = tool_name(call) || current["name"] || next["name"]

    if Map.has_key?(tools, key) do
      {[], Map.put(tools, key, next)}
    else
      emit_tool_start(key, tool, next, tools)
    end
  end

  defp parse_tool_call(_key, _call, tools), do: {[], tools}

  defp emit_tool_start(key, nil, next, tools), do: {[], Map.put(tools, key, next)}

  defp emit_tool_start(key, tool, next, tools) when is_binary(tool) do
    {[{:tool_started, tool, tool_state_payload(next)}], Map.put(tools, key, next)}
  end

  defp merge_tool_state(state, call) do
    updates =
      [
        {"id", call["id"]},
        {"index", call["index"]},
        {"type", call["type"]},
        {"name", tool_name(call)},
        {"function", call["function"]}
      ]
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        if value == nil, do: acc, else: Map.put(acc, key, value)
      end)

    arguments = get_in(call, ["function", "arguments"])

    state
    |> Map.merge(updates)
    |> append_arguments(arguments)
  end

  defp append_arguments(state, nil), do: state
  defp append_arguments(state, ""), do: state

  defp append_arguments(state, arguments) when is_binary(arguments),
    do: Map.update(state, "arguments", arguments, &append_arguments_value(&1, arguments))

  defp append_arguments_value(existing, chunk) when is_binary(existing), do: existing <> chunk

  defp complete_tool_calls(tools) do
    completed =
      tools
      |> Map.values()
      |> Enum.filter(&(is_binary(&1["name"]) and &1["name"] != ""))
      |> Enum.sort_by(&tool_sort_key/1)
      |> Enum.map(fn state ->
        {:tool_completed, state["name"], tool_state_payload(state)}
      end)

    if completed == [] do
      {[], tools}
    else
      {completed, %{}}
    end
  end

  defp tool_call_sort_key(tool_call) do
    tool_sort_key(tool_call)
  end

  defp tool_sort_key(state) do
    case state["index"] do
      index when is_integer(index) ->
        {0, index}

      index when is_binary(index) ->
        case Integer.parse(index) do
          {value, ""} -> {1, value}
          _ -> {2, index}
        end

      _ ->
        {3, state["id"]}
    end
  end

  defp tool_state_payload(state) do
    Map.take(state, ["id", "index", "type", "name", "arguments", "function"])
  end

  defp usage_events(usage) when is_map(usage), do: [{:usage, usage}]
  defp usage_events(_), do: []

  defp tool_calls_finished?(finish_reason)
       when is_binary(finish_reason) and finish_reason in ["tool_calls"] do
    true
  end

  defp tool_calls_finished?(_), do: false

  defp tool_key(call) do
    cond do
      is_binary(call["id"]) -> "id:#{call["id"]}"
      is_integer(call["index"]) -> "index:#{call["index"]}"
      is_binary(call["index"]) -> "index:#{call["index"]}"
      true -> nil
    end
  end

  defp tool_name(call) do
    cond do
      is_binary(call["tool"]) -> call["tool"]
      is_binary(get_in(call, ["function", "name"])) -> get_in(call, ["function", "name"])
      true -> nil
    end
  end
end
