defmodule ReyCode.Provider.Request do
  @moduledoc "Normalized input for one provider invocation."

  @enforce_keys [
    :invocation_id,
    :turn_id,
    :room_id,
    :mode,
    :participant,
    :system_prompt,
    :messages,
    :workspace,
    :resume_from
  ]
  defstruct [
    :invocation_id,
    :turn_id,
    :room_id,
    :mode,
    :participant,
    :system_prompt,
    :messages,
    :workspace,
    :resume_from,
    :session_id,
    :attempt,
    :label,
    :phase,
    :cycle,
    :logical_work_id,
    agent_delay_ms: nil,
    dependencies: []
  ]

  @type participant :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:perspective) => String.t(),
          required(:provider) => atom() | String.t(),
          required(:model) => String.t() | nil
        }
  @type message :: %{
          required(:role) => :user | :assistant,
          required(:content) => String.t(),
          required(:author) => map()
        }
  @type t :: %__MODULE__{
          invocation_id: String.t(),
          turn_id: String.t(),
          room_id: String.t(),
          mode: atom(),
          participant: participant(),
          system_prompt: String.t(),
          messages: [message()],
          workspace: String.t(),
          resume_from: non_neg_integer(),
          session_id: String.t() | nil,
          attempt: pos_integer() | nil,
          label: String.t() | nil,
          phase: String.t() | nil,
          cycle: non_neg_integer() | nil,
          logical_work_id: String.t() | nil,
          agent_delay_ms: non_neg_integer() | nil,
          dependencies: [String.t()]
        }
end
