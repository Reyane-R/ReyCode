defmodule ReyCode.Provider.Request do
  @moduledoc "Normalized input for one provider round."

  alias ReyCode.Failure
  alias ReyCode.Orchestration.Participant
  alias ReyCode.Provider.Message

  @enforce_keys [
    :invocation_id,
    :turn_id,
    :session_id,
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
    :session_id,
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
    :provider_retry_failure,
    :session_context_summary_bytes,
    :tool_names,
    system_prompt_mode: :augmented,
    agent_delay_ms: nil,
    simulator_opts: nil,
    dependencies: [],
    steering: []
  ]

  @type participant :: Participant.t()
  @type t :: %__MODULE__{
          invocation_id: String.t(),
          turn_id: String.t(),
          session_id: String.t(),
          mode: atom(),
          participant: participant(),
          system_prompt: String.t(),
          system_prompt_mode: :augmented | :frozen,
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
          provider_retry_failure: Failure.t() | nil,
          session_context_summary_bytes: non_neg_integer() | nil,
          tool_names: [String.t()] | nil,
          agent_delay_ms: non_neg_integer() | nil,
          simulator_opts: keyword() | nil,
          dependencies: [String.t()],
          steering: [map()]
        }
end
