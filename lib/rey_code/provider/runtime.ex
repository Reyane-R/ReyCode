defmodule ReyCode.Provider.Runtime do
  @moduledoc "Frozen model API or simulator runtime for one invocation."

  alias ReyCode.RuntimeConfig.{OpenAICompatible, Simulator, Workspace}

  @type status :: :available | :checking | :configured | :error | :missing | :unchecked

  @enforce_keys [:module, :status]
  defstruct [:module, :provider_id, :config, :workspace_policy, models: [], status: :unchecked]

  @type t :: %__MODULE__{
          module: module(),
          provider_id: atom() | nil,
          config: OpenAICompatible.t() | Simulator.t() | nil,
          workspace_policy: Workspace.t() | nil,
          models: [binary()],
          status: status()
        }
end
