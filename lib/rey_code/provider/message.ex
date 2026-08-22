defmodule ReyCode.Provider.Message do
  @moduledoc """
  One normalized conversation message supplied to a provider round.

  Messages carry room context (`:user` and plain `:assistant` text), assistant
  tool-call batches, and tool results keyed by call ID (`:tool`).
  """

  alias ReyCode.Provider.ToolCall

  @enforce_keys [:role, :content]
  defstruct [:role, :content, :author, :tool_calls, :tool_call_id, :name]

  @type role :: :user | :assistant | :tool
  @type t :: %__MODULE__{
          role: role(),
          content: String.t() | nil,
          author: map() | nil,
          tool_calls: [ToolCall.t()],
          tool_call_id: String.t() | nil,
          name: String.t() | nil
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      role: Keyword.fetch!(opts, :role),
      content: Keyword.get(opts, :content),
      author: Keyword.get(opts, :author),
      tool_calls: Keyword.get(opts, :tool_calls, []),
      tool_call_id: Keyword.get(opts, :tool_call_id),
      name: Keyword.get(opts, :name)
    }
  end
end
