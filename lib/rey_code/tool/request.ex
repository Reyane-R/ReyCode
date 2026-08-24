defmodule ReyCode.Tool.Request do
  @moduledoc "A normalized tool execution request emitted by a provider."

  @enforce_keys [:tool, :arguments, :workspace]
  defstruct [:tool, :arguments, :workspace, :roots, :request_id]

  @type t :: %__MODULE__{
          tool: String.t() | atom(),
          arguments: map(),
          workspace: String.t(),
          roots: [String.t()] | nil,
          request_id: String.t() | nil
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      tool: Keyword.fetch!(opts, :tool),
      arguments: Keyword.get(opts, :arguments, %{}),
      workspace: Keyword.fetch!(opts, :workspace),
      roots: Keyword.get(opts, :roots),
      request_id: Keyword.get(opts, :request_id)
    }
  end

  @doc "Returns the trusted roots stamped onto this request by the tool registry."
  @spec roots(t()) :: [String.t()]
  def roots(%__MODULE__{roots: roots}) when is_list(roots), do: roots
  def roots(%__MODULE__{}), do: raise(ArgumentError, "tool request is missing trusted roots")
end
