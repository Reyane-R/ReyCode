defmodule ReyCode.Provider.ToolCall do
  @moduledoc "A normalized tool call returned by one provider round."

  @enforce_keys [:id, :tool, :arguments]
  defstruct [:id, :tool, :arguments]

  @type t :: %__MODULE__{
          id: String.t(),
          tool: String.t(),
          arguments: map()
        }

  @spec new(String.t(), String.t() | atom(), map()) :: t()
  def new(id, tool, arguments) when is_binary(id) and is_map(arguments) do
    %__MODULE__{id: id, tool: to_string(tool), arguments: arguments}
  end

  @doc "Encodes the call as canonical, string-keyed wire data."
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = call) do
    %{"id" => call.id, "tool" => call.tool, "arguments" => call.arguments}
  end

  @doc "Rebuilds a call from canonical wire data, returning an error when malformed."
  @spec from_wire(term()) :: {:ok, t()} | {:error, :invalid_tool_call}
  def from_wire(%{"id" => id, "tool" => tool, "arguments" => arguments})
      when is_binary(id) and id != "" and is_binary(tool) and tool != "" and is_map(arguments),
      do: {:ok, %__MODULE__{id: id, tool: tool, arguments: arguments}}

  def from_wire(_other), do: {:error, :invalid_tool_call}
end
