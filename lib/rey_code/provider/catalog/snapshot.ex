defmodule ReyCode.Provider.Catalog.Snapshot do
  @moduledoc """
  A versioned provider-catalog view.

  `generation` increases by one on every catalog broadcast, independent of
  wall-clock timestamps. Consumers hold the generation of their current view
  and ignore snapshots at or below it, so a notification queued before a
  newer snapshot reply can never regress the observed catalog.
  """

  @enforce_keys [:generation, :providers]
  defstruct [:generation, :providers]

  @type generation :: pos_integer()
  @type t :: %__MODULE__{
          generation: generation(),
          providers: %{optional(atom()) => map()}
        }
end
