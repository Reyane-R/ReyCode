defmodule ReyCode.Orchestration.Validation do
  @moduledoc "Normalizes and validates commands before durable orchestration state changes."

  alias ReyCode.Orchestration.Squad
  alias ReyCode.Security.Workspace

  @max_room_title 120
  @max_message_bytes 100_000
  @max_directive 2_000
  @max_participant_name 80
  @max_participant_responsibility 2_000
  @max_model_id 512
  @max_cancellation_reason_bytes 1_000
  @max_gate_reason_bytes 1_000

  @spec room(term(), term()) :: {:ok, String.t(), String.t()} | {:error, atom()}
  @spec room(term(), term(), keyword()) :: {:ok, String.t(), String.t()} | {:error, atom()}
  def room(title, workspace, opts \\ []) do
    with {:ok, title} <- text(title, :empty_title, :invalid_title, @max_room_title),
         {:ok, workspace} <- Workspace.validate(workspace, opts) do
      {:ok, title, workspace}
    else
      {:error, reason} when reason in [:empty_title, :invalid_title] -> {:error, reason}
      {:error, _reason} -> {:error, :invalid_workspace}
    end
  end

  @spec message(term()) :: {:ok, String.t()} | {:error, atom()}
  def message(body) do
    text(body, :empty_message, :invalid_message, @max_message_bytes, :bytes)
  end

  @doc "Validates the display title derived for a new session."
  @spec session_title(term()) :: {:ok, String.t()} | {:error, atom()}
  def session_title(title), do: text(title, :empty_title, :invalid_title, @max_room_title)

  @doc "Validates an owner-typed shell command."
  @spec owner_command(term()) :: {:ok, String.t()} | {:error, atom()}
  def owner_command(command),
    do: text(command, :empty_command, :invalid_command, 2_000, :bytes)

  @doc "Validates a user-created task participant profile."
  @spec task_participant(term(), term()) :: {:ok, String.t(), String.t()} | {:error, atom()}
  def task_participant(name, responsibility) do
    with {:ok, name} <-
           text(
             name,
             :participant_name_required,
             :invalid_participant_name,
             @max_participant_name
           ),
         {:ok, responsibility} <-
           text(
             responsibility,
             :participant_responsibility_required,
             :invalid_participant_responsibility,
             @max_participant_responsibility
           ) do
      {:ok, name, responsibility}
    end
  end

  @spec model(term()) :: {:ok, String.t()} | {:error, atom()}
  def model(model), do: text(model, :model_required, :invalid_model, @max_model_id)

  @spec directive(term()) :: {:ok, String.t()} | {:error, atom()}
  def directive(directive),
    do: text(directive, :empty_directive, :invalid_directive, @max_directive)

  @doc "Validates a turn cancellation and normalizes its reason."
  @spec cancellation(map() | nil, term()) ::
          {:ok, String.t()} | {:ok, :already_finished} | {:error, atom()}
  def cancellation(nil, _reason), do: {:error, :turn_not_found}

  def cancellation(%{status: :terminal}, _reason), do: {:ok, :already_finished}

  def cancellation(_turn, reason) do
    reason = if is_binary(reason), do: String.trim(reason), else: ""

    if reason == "" or byte_size(reason) > @max_cancellation_reason_bytes or
         String.contains?(reason, <<0>>) do
      {:error, :invalid_cancellation_reason}
    else
      {:ok, reason}
    end
  end

  @doc "Checks squad directive preconditions before normalizing its text."
  @spec squad_directive(map() | nil, term()) :: {:ok, String.t()} | {:error, atom()}
  def squad_directive(turn, raw_directive) do
    case directive_turn_ready(turn) do
      :ok -> directive(raw_directive)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Checks gate preconditions and normalizes a human gate decision.

  The decision must carry the review id of the gate that was displayed, so a
  stale modal can never resolve a newer gate opened by the same turn.
  """
  @spec gate_resolution(map() | nil, term(), term(), term(), term()) ::
          {:ok, map(), atom(), String.t() | nil, [String.t()]} | {:error, atom()}
  def gate_resolution(turn, raw_review_id, raw_decision, raw_target_phase, raw_reasons) do
    with {:ok, review} <- pending_gate_review(turn),
         :ok <- require_requested_review(review, raw_review_id),
         {:ok, decision} <- normalize_gate_decision(raw_decision),
         {:ok, target_phase} <- normalize_gate_target(decision, raw_target_phase),
         {:ok, reasons} <- normalize_gate_reasons(raw_reasons) do
      {:ok, review, decision, target_phase, reasons}
    end
  end

  @doc """
  Checks invocation preconditions and normalizes a human tool decision.

  The decision must be addressed to the ToolRun ID carried by the pending
  review, so a stale UI can never resolve a different request.
  """
  @spec tool_run_resolution(map() | nil, term(), term()) ::
          {:ok, map(), atom()} | {:error, atom()}
  def tool_run_resolution(invocation, raw_run_id, raw_decision) do
    with {:ok, review} <- pending_tool_review(invocation),
         :ok <- require_requested_run(review, raw_run_id),
         {:ok, decision} <- normalize_tool_decision(raw_decision) do
      {:ok, review, decision}
    end
  end

  defp require_requested_run(%{request_id: request_id}, raw_run_id)
       when is_binary(raw_run_id),
       do: if(raw_run_id == request_id, do: :ok, else: {:error, :tool_run_not_found})

  defp require_requested_run(_review, _raw_run_id), do: {:error, :tool_run_not_found}

  defp require_requested_review(%{id: review_id}, raw_review_id)
       when is_binary(raw_review_id),
       do: if(raw_review_id == review_id, do: :ok, else: {:error, :gate_review_not_found})

  defp require_requested_review(_review, _raw_review_id), do: {:error, :gate_review_not_found}

  defp directive_turn_ready(nil), do: {:error, :turn_not_found}

  defp directive_turn_ready(%{mode: :squad, status: :running, squad: squad})
       when not is_nil(squad),
       do: :ok

  defp directive_turn_ready(%{mode: :squad}), do: {:error, :squad_not_running}
  defp directive_turn_ready(_turn), do: {:error, :not_a_squad_turn}

  defp pending_gate_review(nil), do: {:error, :turn_not_found}

  defp pending_gate_review(%{mode: :squad, status: :running, squad: squad}) do
    case squad && squad.pending_review do
      nil -> {:error, :gate_review_not_pending}
      review -> {:ok, review}
    end
  end

  defp pending_gate_review(%{mode: :squad}), do: {:error, :squad_not_running}
  defp pending_gate_review(_turn), do: {:error, :not_a_squad_turn}

  defp pending_tool_review(nil), do: {:error, :invocation_not_found}

  defp pending_tool_review(%{pending_tool_review: nil}), do: {:error, :tool_review_not_pending}

  defp pending_tool_review(%{status: status, pending_tool_review: review})
       when status in [:running, :waiting_tool_approval],
       do: {:ok, review}

  defp pending_tool_review(_invocation), do: {:error, :invocation_not_running}

  defp normalize_tool_decision(decision) when decision in [:approve, :deny], do: {:ok, decision}
  defp normalize_tool_decision("approve"), do: {:ok, :approve}
  defp normalize_tool_decision("deny"), do: {:ok, :deny}
  defp normalize_tool_decision(_decision), do: {:error, :invalid_tool_decision}

  defp normalize_gate_decision(decision) when decision in [:approve, :rework, :abort],
    do: {:ok, decision}

  defp normalize_gate_decision("approve"), do: {:ok, :approve}
  defp normalize_gate_decision("rework"), do: {:ok, :rework}
  defp normalize_gate_decision("abort"), do: {:ok, :abort}
  defp normalize_gate_decision(_decision), do: {:error, :invalid_gate_decision}

  defp normalize_gate_target(:rework, nil), do: {:ok, nil}

  defp normalize_gate_target(:rework, target) when is_binary(target) do
    if Squad.phase(target), do: {:ok, target}, else: {:error, :invalid_rework_target}
  end

  defp normalize_gate_target(decision, target)
       when decision in [:approve, :abort] and target in [nil, ""],
       do: {:ok, nil}

  defp normalize_gate_target(_decision, _target), do: {:error, :invalid_rework_target}

  defp normalize_gate_reasons(reasons) when is_list(reasons) do
    normalized = Enum.map(reasons, &if(is_binary(&1), do: String.trim(&1), else: &1))

    if Enum.all?(normalized, &(is_binary(&1) and byte_size(&1) <= @max_gate_reason_bytes)) do
      {:ok, Enum.reject(normalized, &(&1 == ""))}
    else
      {:error, :invalid_gate_reasons}
    end
  end

  defp normalize_gate_reasons(_reasons), do: {:error, :invalid_gate_reasons}

  defp text(value, empty_error, invalid_error, maximum, unit \\ :graphemes)

  defp text(value, empty_error, invalid_error, maximum, unit) when is_binary(value) do
    value = String.trim(value)
    size = if unit == :bytes, do: byte_size(value), else: String.length(value)

    cond do
      value == "" -> {:error, empty_error}
      String.contains?(value, <<0>>) -> {:error, invalid_error}
      size > maximum -> {:error, invalid_error}
      true -> {:ok, value}
    end
  end

  defp text(_value, _empty_error, invalid_error, _maximum, _unit), do: {:error, invalid_error}
end
