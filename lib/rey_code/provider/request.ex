defmodule ReyCode.Provider.Request do
  @moduledoc "Normalized input for one provider round."

  alias ReyCode.Orchestration.Participant
  alias ReyCode.Provider.Message

  @enforce_keys [
    :invocation_id,
    :turn_id,
    :room_id,
    :mode,
    :participant,
    :system_prompt,
    :messages,
    :workspace,
    :resume_from,
    :round_index
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
    :round_index,
    :attempt,
    :label,
    :phase,
    :cycle,
    :logical_work_id,
    :model_tier,
    :token_budget_tokens,
    :used_tokens,
    agent_delay_ms: nil,
    simulator_opts: nil,
    dependencies: [],
    steering: []
  ]

  @type participant :: Participant.t()
  @type t :: %__MODULE__{
          invocation_id: String.t(),
          turn_id: String.t(),
          room_id: String.t(),
          mode: atom(),
          participant: participant(),
          system_prompt: String.t(),
          messages: [Message.t()],
          workspace: String.t(),
          resume_from: non_neg_integer(),
          round_index: non_neg_integer(),
          attempt: pos_integer() | nil,
          label: String.t() | nil,
          phase: String.t() | nil,
          cycle: non_neg_integer() | nil,
          logical_work_id: String.t() | nil,
          model_tier: :smol | :default | :slow,
          token_budget_tokens: pos_integer(),
          used_tokens: non_neg_integer() | nil,
          agent_delay_ms: non_neg_integer() | nil,
          simulator_opts: keyword() | nil,
          dependencies: [String.t()],
          steering: [map()]
        }
end
