defmodule ReyCode.Provider.OpenAICompatible.SSE do
  @moduledoc false

  defstruct buffer: "", tools: %{}, error: nil, done?: false

  @type protocol_error ::
          :invalid_json
          | :invalid_payload
          | :invalid_choice
          | :invalid_content
          | :invalid_tool_call
          | :invalid_usage
          | :data_after_done
          | :incomplete_tool_call
          | :unterminated_event

  @type t :: %__MODULE__{
          buffer: binary(),
          tools: map(),
          error: protocol_error() | nil,
          done?: boolean()
        }
  @type tool_event_kind :: :tool_started | :tool_completed
  @type event ::
          {:text, binary()}
          | {:usage, map()}
          | {tool_event_kind, binary(), term()}
          | {:protocol_error, protocol_error()}
          | :done

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec feed(t(), binary()) :: {[event()], t()}
  def feed(%__MODULE__{error: error} = parser, _data) when not is_nil(error), do: {[], parser}

  def feed(%__MODULE__{buffer: buffer, tools: tools, done?: done?} = parser, data)
      when is_binary(data) do
    {complete, rest} = split_events(buffer <> data)

    case parse_events(complete, tools, [], done?) do
      {:ok, events, next_tools, next_done?} ->
        {events, %{parser | buffer: rest, tools: next_tools, done?: next_done?}}

      {:error, reason, events, next_tools, next_done?} ->
        {events ++ [{:protocol_error, reason}],
         %{parser | buffer: rest, tools: next_tools, error: reason, done?: next_done?}}
    end
  end

  @spec finish(t()) :: :ok | {:error, protocol_error()}
  def finish(%__MODULE__{error: reason}) when not is_nil(reason), do: {:error, reason}

  def finish(%__MODULE__{buffer: buffer, tools: tools}) do
    cond do
      buffer != "" and not harmless_comment_tail?(buffer) -> {:error, :unterminated_event}
      map_size(tools) > 0 -> {:error, :incomplete_tool_call}
      true -> :ok
    end
  end

  defp split_events(buffer), do: split_events(buffer, [])

  defp split_events(buffer, events) do
    case next_separator(buffer) do
      nil ->
        {Enum.reverse(events), buffer}

      {index, length} ->
        <<event::binary-size(index), _separator::binary-size(length), rest::binary>> = buffer
        split_events(rest, [event | events])
    end
  end

  defp next_separator(buffer) do
    [separator_match(buffer, "\n\n"), separator_match(buffer, "\r\n\r\n")]
    |> Enum.reject(&is_nil/1)
    |> Enum.min_by(&elem(&1, 0), fn -> nil end)
  end

  defp separator_match(buffer, separator) do
    case :binary.match(buffer, separator) do
      {index, length} -> {index, length}
      :nomatch -> nil
    end
  end

  defp parse_events([], tools, events, done?),
    do: {:ok, Enum.reverse(events), tools, done?}

  defp parse_events([raw | rest], tools, events, done?) do
    if done? and data_record?(raw) do
      {:error, :data_after_done, Enum.reverse(events), tools, done?}
    else
      continue_parsing(parse_event(raw, tools), rest, tools, events, done?)
    end
  end

  defp continue_parsing({:ok, next_events, next_tools}, rest, tools, events, done?) do
    continue_after_terminal_state(
      terminal_state(next_events, done?),
      rest,
      tools,
      next_tools,
      next_events,
      events,
      done?
    )
  end

  defp continue_parsing({:error, reason, next_tools}, _rest, _tools, events, done?),
    do: {:error, reason, Enum.reverse(events), next_tools, done?}

  defp continue_after_terminal_state(
         {:ok, next_done?},
         rest,
         _tools,
         next_tools,
         next_events,
         events,
         _done?
       ),
       do: parse_events(rest, next_tools, Enum.reverse(next_events, events), next_done?)

  defp continue_after_terminal_state(
         {:error, reason},
         _rest,
         tools,
         _next_tools,
         _next_events,
         events,
         done?
       ),
       do: {:error, reason, Enum.reverse(events), tools, done?}

  defp terminal_state([], done?), do: {:ok, done?}
  defp terminal_state([:done], false), do: {:ok, true}
  defp terminal_state(_events, true), do: {:error, :data_after_done}
  defp terminal_state(events, false) when is_list(events), do: {:ok, false}

  defp parse_event(raw, tools) do
    data_lines =
      raw
      |> split_lines()
      |> Enum.reduce([], fn line, acc ->
        case data_line(line) do
          {:data, value} -> [value | acc]
          :other -> acc
        end
      end)
      |> Enum.reverse()

    case data_lines do
      [] -> {:ok, [], tools}
      lines -> lines |> Enum.join("\n") |> trim_ascii() |> decode_data(tools)
    end
  end

  defp split_lines(data), do: :binary.split(data, ["\r\n", "\n"], [:global])

  defp data_line(<<"data:", rest::binary>>), do: {:data, optional_space(rest)}
  defp data_line("data"), do: {:data, ""}
  defp data_line(_line), do: :other

  defp data_record?(raw) do
    raw
    |> split_lines()
    |> Enum.any?(fn line -> match?({:data, _value}, data_line(line)) end)
  end

  defp optional_space(<<" ", rest::binary>>), do: rest
  defp optional_space(rest), do: rest

  defp decode_data("[DONE]", tools), do: {:ok, [:done], tools}

  defp decode_data(payload, tools) do
    case Jason.decode(payload) do
      {:ok, %{"choices" => choices} = data} when is_list(choices) ->
        with {:ok, events, next_tools} <- parse_choices(choices, tools),
             {:ok, usage_events} <- usage_events(data) do
          {:ok, events ++ usage_events, next_tools}
        else
          {:error, reason} -> {:error, reason, tools}
        end

      {:ok, _other} ->
        {:error, :invalid_payload, tools}

      {:error, _reason} ->
        {:error, :invalid_json, tools}
    end
  end

  defp parse_choices(choices, tools) do
    Enum.reduce_while(choices, {:ok, [], tools}, fn choice, {:ok, events, current_tools} ->
      case parse_choice(choice, current_tools) do
        {:ok, choice_events, next_tools} ->
          {:cont, {:ok, events ++ choice_events, next_tools}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_choice(choice, tools) when is_map(choice) do
    with {:ok, delta} <- choice_delta(choice),
         :ok <- valid_finish_reason?(choice),
         {:ok, content_events} <- content_events(delta),
         {:ok, tool_events, tools} <- tool_events(delta, tools),
         {:ok, completion_events, tools} <- complete_tool_state(tools, choice["finish_reason"]) do
      {:ok, content_events ++ tool_events ++ completion_events, tools}
    end
  end

  defp parse_choice(_choice, _tools), do: {:error, :invalid_choice}

  defp choice_delta(%{"delta" => delta}) when is_map(delta), do: {:ok, delta}
  defp choice_delta(_choice), do: {:error, :invalid_choice}

  defp valid_finish_reason?(choice) do
    case Map.fetch(choice, "finish_reason") do
      :error -> :ok
      {:ok, nil} -> :ok
      {:ok, reason} when is_binary(reason) -> :ok
      {:ok, _invalid} -> {:error, :invalid_choice}
    end
  end

  defp content_events(delta) do
    case Map.fetch(delta, "content") do
      :error -> {:ok, []}
      {:ok, nil} -> {:ok, []}
      {:ok, ""} -> {:ok, []}
      {:ok, content} when is_binary(content) -> {:ok, [{:text, content}]}
      {:ok, _invalid} -> {:error, :invalid_content}
    end
  end

  defp tool_events(delta, tools) do
    case Map.fetch(delta, "tool_calls") do
      :error -> {:ok, [], tools}
      {:ok, nil} -> {:ok, [], tools}
      {:ok, calls} when is_list(calls) -> parse_tool_calls(calls, tools)
      {:ok, _invalid} -> {:error, :invalid_tool_call}
    end
  end

  defp parse_tool_calls(calls, tools) do
    calls
    |> Enum.sort_by(&tool_sort_key/1)
    |> Enum.reduce_while({:ok, [], tools}, fn call, {:ok, events, current_tools} ->
      case parse_tool_call(call, current_tools) do
        {:ok, next_events, next_tools} ->
          {:cont, {:ok, events ++ next_events, next_tools}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_tool_call(call, tools) when is_map(call) do
    with {:ok, key} <- tool_key(call, tools),
         {:ok, next} <- merge_tool_state(Map.get(tools, key, %{}), call) do
      tool = next["name"]

      cond do
        Map.has_key?(tools, key) ->
          {:ok, [], Map.put(tools, key, next)}

        is_binary(tool) and tool != "" ->
          {:ok, [{:tool_started, tool, tool_state_payload(next)}], Map.put(tools, key, next)}

        true ->
          {:ok, [], Map.put(tools, key, next)}
      end
    end
  end

  defp parse_tool_call(_call, _tools), do: {:error, :invalid_tool_call}

  defp merge_tool_state(state, call) do
    function = Map.get(call, "function")

    with :ok <- valid_function_map?(function),
         :ok <- valid_tool_fields?(call, function),
         updates = tool_updates(call),
         :ok <- consistent_tool_fields?(state, updates) do
      arguments = if is_map(function), do: function["arguments"]
      {:ok, state |> Map.merge(updates) |> append_arguments(arguments)}
    end
  end

  defp consistent_tool_fields?(state, updates) do
    if Enum.all?(updates, fn {key, value} ->
         not Map.has_key?(state, key) or state[key] == value
       end) do
      :ok
    else
      {:error, :invalid_tool_call}
    end
  end

  defp valid_function_map?(nil), do: :ok
  defp valid_function_map?(function) when is_map(function), do: :ok
  defp valid_function_map?(_invalid), do: {:error, :invalid_tool_call}

  defp valid_tool_fields?(call, function) do
    if invalid_optional_binary?(call, "id") or invalid_optional_binary?(call, "type") or
         invalid_optional_binary?(call, "tool") or invalid_index?(call) or
         invalid_function?(function) or invalid_tool_type?(call) or
         conflicting_tool_names?(call, function) do
      {:error, :invalid_tool_call}
    else
      :ok
    end
  end

  defp tool_updates(call) do
    [
      {"id", call["id"]},
      {"index", call["index"]},
      {"type", call["type"]},
      {"name", tool_name(call)}
    ]
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      if value == nil, do: acc, else: Map.put(acc, key, value)
    end)
  end

  defp invalid_optional_binary?(map, key) do
    case Map.fetch(map, key) do
      :error -> false
      {:ok, nil} -> false
      {:ok, value} -> not is_binary(value)
    end
  end

  defp invalid_function?(nil), do: false

  defp invalid_function?(function) do
    invalid_optional_binary?(function, "name") or
      invalid_optional_binary?(function, "arguments")
  end

  defp invalid_tool_type?(call) do
    case Map.fetch(call, "type") do
      :error -> false
      {:ok, nil} -> false
      {:ok, "function"} -> false
      {:ok, _invalid} -> true
    end
  end

  defp conflicting_tool_names?(%{"tool" => tool}, %{"name" => name})
       when is_binary(tool) and is_binary(name),
       do: tool != name

  defp conflicting_tool_names?(_call, _function), do: false

  defp invalid_index?(call) do
    case Map.fetch(call, "index") do
      :error -> false
      {:ok, index} when is_integer(index) -> false
      {:ok, index} when is_binary(index) and index != "" -> false
      {:ok, _invalid} -> true
    end
  end

  defp append_arguments(state, nil), do: state
  defp append_arguments(state, ""), do: state

  defp append_arguments(state, arguments),
    do: Map.update(state, "arguments", arguments, &(&1 <> arguments))

  defp complete_tool_state(tools, "tool_calls"), do: complete_tool_calls(tools)
  defp complete_tool_state(tools, _finish_reason), do: {:ok, [], tools}

  defp complete_tool_calls(tools) when map_size(tools) == 0,
    do: {:error, :incomplete_tool_call}

  defp complete_tool_calls(tools) do
    tools
    |> Map.values()
    |> Enum.sort_by(&tool_sort_key/1)
    |> Enum.reduce_while({:ok, []}, fn state, {:ok, events} ->
      case completed_tool(state) do
        {:ok, event} -> {:cont, {:ok, [event | events]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events), %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp completed_tool(%{"id" => id, "name" => name} = state)
       when is_binary(id) and id != "" and is_binary(name) and name != "" do
    arguments = Map.get(state, "arguments", "{}")

    case Jason.decode(arguments) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, {:tool_completed, name, Map.put(tool_state_payload(state), "arguments", arguments)}}

      _invalid ->
        {:error, :incomplete_tool_call}
    end
  end

  defp completed_tool(_state), do: {:error, :incomplete_tool_call}

  defp usage_events(data) do
    case Map.fetch(data, "usage") do
      :error -> {:ok, []}
      {:ok, nil} -> {:ok, []}
      {:ok, usage} when is_map(usage) -> {:ok, [{:usage, usage}]}
      {:ok, _invalid} -> {:error, :invalid_usage}
    end
  end

  defp tool_sort_key(state) when is_map(state) do
    case state["index"] do
      index when is_integer(index) -> {0, index}
      index when is_binary(index) -> string_index_sort_key(index)
      _other -> {3, state["id"]}
    end
  end

  defp tool_sort_key(_invalid), do: {4, nil}

  defp string_index_sort_key(index) do
    case Integer.parse(index) do
      {value, ""} -> {1, value}
      _other -> {2, index}
    end
  end

  defp tool_state_payload(state),
    do: Map.take(state, ["id", "index", "type", "name", "arguments"])

  defp tool_key(call, tools) do
    matches =
      tools
      |> Enum.filter(fn {_key, state} -> same_tool_identity?(call, state) end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()

    case matches do
      [key] -> {:ok, key}
      [] -> new_tool_key(call)
      _ambiguous -> {:error, :invalid_tool_call}
    end
  end

  defp same_tool_identity?(call, state) do
    same_nonempty?(call["id"], state["id"]) or same_index?(call["index"], state["index"])
  end

  defp same_nonempty?(left, right),
    do: is_binary(left) and left != "" and left == right

  defp same_index?(left, right),
    do: (is_integer(left) or is_binary(left)) and left == right

  defp new_tool_key(call) do
    cond do
      is_integer(call["index"]) -> {:ok, "index:#{call["index"]}"}
      is_binary(call["index"]) and call["index"] != "" -> {:ok, "index:#{call["index"]}"}
      is_binary(call["id"]) and call["id"] != "" -> {:ok, "id:#{call["id"]}"}
      true -> {:error, :invalid_tool_call}
    end
  end

  defp tool_name(call) do
    cond do
      is_binary(call["tool"]) ->
        call["tool"]

      is_map(call["function"]) and is_binary(call["function"]["name"]) ->
        call["function"]["name"]

      true ->
        nil
    end
  end

  defp trim_ascii(data) do
    data
    |> trim_ascii_leading()
    |> trim_ascii_trailing()
  end

  defp trim_ascii_leading(<<character, rest::binary>>) when character in [9, 10, 13, 32],
    do: trim_ascii_leading(rest)

  defp trim_ascii_leading(data), do: data

  defp trim_ascii_trailing(""), do: ""

  defp trim_ascii_trailing(data) do
    size = byte_size(data)
    <<prefix::binary-size(size - 1), character>> = data

    if character in [9, 10, 13, 32], do: trim_ascii_trailing(prefix), else: data
  end

  defp harmless_comment_tail?(buffer) do
    buffer
    |> split_lines()
    |> Enum.all?(fn
      "" -> true
      <<":", _rest::binary>> -> true
      _line -> false
    end)
  end
end
