defmodule ReyCode.Tool.Result do
  @moduledoc "The outcome of executing one tool against the workspace."

  @enforce_keys [:ok]
  defstruct [:ok, :output, :error]

  @type t :: %__MODULE__{
          ok: boolean(),
          output: String.t() | nil,
          error: term()
        }

  @spec ok(String.t()) :: t()
  def ok(output) when is_binary(output), do: %__MODULE__{ok: true, output: output}

  @spec error(term()) :: t()
  def error(reason), do: %__MODULE__{ok: false, output: nil, error: reason}
end
