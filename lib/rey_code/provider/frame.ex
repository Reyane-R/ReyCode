defmodule ReyCode.Provider.Frame do
  @moduledoc "A provider-independent streaming frame."

  @enforce_keys [:sequence, :kind, :data]
  defstruct [:sequence, :kind, :data]

  @type kind :: :text_delta | :usage | :session_started | :tool_started | :tool_completed
  @type data ::
          %{text: String.t()}
          | %{session_id: String.t()}
          | %{usage: map()}
          | %{tool: String.t(), state: term()}

  @type t :: %__MODULE__{sequence: pos_integer(), kind: kind(), data: data()}

  @spec text_delta(pos_integer(), String.t()) :: t()
  def text_delta(sequence, text),
    do: %__MODULE__{sequence: sequence, kind: :text_delta, data: %{text: text}}

  @doc "Encodes the frame as canonical, string-keyed event payload data."
  @spec to_event_data(t()) :: map()
  def to_event_data(%__MODULE__{sequence: sequence, kind: kind, data: data}) do
    %{
      "frame_sequence" => sequence,
      "kind" => Atom.to_string(kind),
      "data" => to_wire_data(kind, data)
    }
  end

  @spec session_started(pos_integer(), String.t()) :: t()
  def session_started(sequence, session_id) do
    %__MODULE__{sequence: sequence, kind: :session_started, data: %{session_id: session_id}}
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

  @spec validate(t()) :: :ok | {:error, atom()}
  def validate(%__MODULE__{} = frame) do
    if valid_payload?(frame) and json_safe?(frame.data), do: :ok, else: {:error, :invalid_frame}
  end

  defp to_wire_data(:text_delta, %{text: text}), do: %{"text" => text}

  defp to_wire_data(:session_started, %{session_id: session_id}),
    do: %{"session_id" => session_id}

  defp to_wire_data(:usage, %{usage: usage}), do: %{"usage" => usage}

  defp to_wire_data(kind, %{tool: tool, state: tool_state})
       when kind in [:tool_started, :tool_completed],
       do: %{"tool" => tool, "state" => tool_state}

  defp valid_payload?(%__MODULE__{sequence: sequence, kind: :text_delta, data: %{text: text}})
       when is_integer(sequence) and sequence > 0 and is_binary(text),
       do: true

  defp valid_payload?(%__MODULE__{
         sequence: sequence,
         kind: :session_started,
         data: %{session_id: id}
       })
       when is_integer(sequence) and sequence > 0 and is_binary(id) and id != "",
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

  defp valid_payload?(%__MODULE__{}), do: false

  defp json_safe?(data), do: match?({:ok, _encoded}, Jason.encode(data))
end
