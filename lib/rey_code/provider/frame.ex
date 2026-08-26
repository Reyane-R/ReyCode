defmodule ReyCode.Provider.Frame do
  @moduledoc "A provider-independent streaming frame."

  @enforce_keys [:sequence, :kind, :data]
  defstruct [:sequence, :kind, :data]

  @type kind ::
          :text_delta
          | :agent_note
          | :usage
          | :tool_started
          | :tool_completed
          | :tool_request
          | :tool_result

  @type data ::
          %{text: String.t()}
          | %{note: String.t()}
          | %{usage: map()}
          | %{tool: String.t(), state: term()}
          | %{tool: String.t(), request_id: String.t(), arguments: map()}
          | %{tool: String.t(), request_id: String.t(), result: term()}

  @type t :: %__MODULE__{sequence: pos_integer(), kind: kind(), data: data()}

  @spec text_delta(pos_integer(), String.t()) :: t()
  def text_delta(sequence, text),
    do: %__MODULE__{sequence: sequence, kind: :text_delta, data: %{text: text}}

  @doc "A native-agent activity line: intermediate reasoning surfaced beside the reply."
  @spec agent_note(pos_integer(), String.t()) :: t()
  def agent_note(sequence, note),
    do: %__MODULE__{sequence: sequence, kind: :agent_note, data: %{note: note}}

  @doc "Encodes the frame as canonical, string-keyed event payload data."
  @spec to_event_data(t()) :: map()
  def to_event_data(%__MODULE__{sequence: sequence, kind: kind, data: data}) do
    %{
      "frame_sequence" => sequence,
      "kind" => Atom.to_string(kind),
      "data" => to_wire_data(kind, data)
    }
  end

  @spec usage(pos_integer(), map()) :: t()
  def usage(sequence, usage),
    do: %__MODULE__{sequence: sequence, kind: :usage, data: %{usage: usage}}

  @spec tool_completed(pos_integer(), String.t(), term()) :: t()
  def tool_completed(sequence, tool, state) do
    %__MODULE__{sequence: sequence, kind: :tool_completed, data: %{tool: tool, state: state}}
  end

  @spec tool_started(pos_integer(), String.t(), term()) :: t()
  def tool_started(sequence, tool, state) do
    %__MODULE__{sequence: sequence, kind: :tool_started, data: %{tool: tool, state: state}}
  end

  @spec tool_request(pos_integer(), String.t(), String.t(), map()) :: t()
  def tool_request(sequence, request_id, tool, arguments) do
    %__MODULE__{
      sequence: sequence,
      kind: :tool_request,
      data: %{request_id: request_id, tool: tool, arguments: arguments}
    }
  end

  @spec tool_result(pos_integer(), String.t(), String.t(), term()) :: t()
  def tool_result(sequence, request_id, tool, result) do
    %__MODULE__{
      sequence: sequence,
      kind: :tool_result,
      data: %{request_id: request_id, tool: tool, result: result}
    }
  end

  @spec validate(term()) :: :ok | {:error, atom()}
  def validate(%__MODULE__{} = frame) do
    if valid_payload?(frame) and json_safe?(frame.data), do: :ok, else: {:error, :invalid_frame}
  end

  def validate(_other), do: {:error, :invalid_frame}

  defp to_wire_data(:text_delta, %{text: text}), do: %{"text" => text}

  defp to_wire_data(:agent_note, %{note: note}), do: %{"note" => note}

  defp to_wire_data(:usage, %{usage: usage}), do: %{"usage" => usage}

  defp to_wire_data(kind, %{tool: tool, state: tool_state})
       when kind in [:tool_started, :tool_completed],
       do: %{"tool" => tool, "state" => tool_state}

  defp to_wire_data(:tool_request, %{request_id: request_id, tool: tool, arguments: arguments}),
    do: %{"request_id" => request_id, "tool" => tool, "arguments" => arguments}

  defp to_wire_data(:tool_result, %{request_id: request_id, tool: tool, result: result}),
    do: %{"request_id" => request_id, "tool" => tool, "result" => result}

  defp valid_payload?(%__MODULE__{sequence: sequence, kind: :text_delta, data: %{text: text}})
       when is_integer(sequence) and sequence > 0 and is_binary(text),
       do: true

  defp valid_payload?(%__MODULE__{sequence: sequence, kind: :agent_note, data: %{note: note}})
       when is_integer(sequence) and sequence > 0 and is_binary(note),
       do: true

  defp valid_payload?(%__MODULE__{sequence: sequence, kind: :usage, data: %{usage: usage}})
       when is_integer(sequence) and sequence > 0 and is_map(usage),
       do: true

  defp valid_payload?(%__MODULE__{
         sequence: sequence,
         kind: kind,
         data: %{tool: tool, state: _state}
       })
       when is_integer(sequence) and sequence > 0 and kind in [:tool_started, :tool_completed] and
              is_binary(tool),
       do: true

  defp valid_payload?(%__MODULE__{
         sequence: sequence,
         kind: :tool_request,
         data: %{request_id: request_id, tool: tool, arguments: arguments}
       })
       when is_integer(sequence) and sequence > 0 and is_binary(request_id) and
              is_binary(tool) and is_map(arguments),
       do: true

  defp valid_payload?(%__MODULE__{
         sequence: sequence,
         kind: :tool_result,
         data: %{request_id: request_id, tool: tool, result: _result}
       })
       when is_integer(sequence) and sequence > 0 and is_binary(request_id) and is_binary(tool),
       do: true

  defp valid_payload?(%__MODULE__{}), do: false

  defp json_safe?(data), do: match?({:ok, _encoded}, Jason.encode(data))
end
