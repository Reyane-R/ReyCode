defmodule ReyCode.Provider.OpenAICompatible.PreparedRequest do
  @moduledoc "Exact encoded OpenAI-compatible request and its context-budget assessment."

  alias ReyCode.Provider.ContextBudget

  @enforce_keys [:body, :budget]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          body: binary(),
          budget: ContextBudget.t()
        }
end
