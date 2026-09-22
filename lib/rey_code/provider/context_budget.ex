defmodule ReyCode.Provider.ContextBudget do
  @moduledoc "Assesses one encoded provider request against byte and token budgets."

  @bytes_per_token 4
  @maintenance_percent 80
  @target_percent 60

  @enforce_keys [
    :status,
    :prompt_bytes,
    :max_prompt_bytes,
    :maintenance_prompt_bytes,
    :target_prompt_bytes,
    :estimated_prompt_tokens,
    :input_budget_tokens,
    :maintenance_input_tokens,
    :target_input_tokens,
    :model_context_percent
  ]
  defstruct @enforce_keys

  @type status :: :ready | :maintenance_required | :too_large

  @type t :: %__MODULE__{
          status: status(),
          prompt_bytes: pos_integer(),
          max_prompt_bytes: pos_integer(),
          maintenance_prompt_bytes: pos_integer(),
          target_prompt_bytes: pos_integer(),
          estimated_prompt_tokens: pos_integer(),
          input_budget_tokens: pos_integer(),
          maintenance_input_tokens: pos_integer(),
          target_input_tokens: pos_integer(),
          model_context_percent: non_neg_integer() | nil
        }

  @doc "Assesses exact wire bytes and an explicitly approximate token count."
  @spec assess(pos_integer(), pos_integer(), pos_integer(), pos_integer() | nil, pos_integer()) ::
          t()
  def assess(
        prompt_bytes,
        max_prompt_bytes,
        context_budget_tokens,
        model_context_tokens,
        output_reserve_tokens
      ) do
    estimated_prompt_tokens = div(prompt_bytes + @bytes_per_token - 1, @bytes_per_token)

    input_budget_tokens =
      input_budget_tokens(context_budget_tokens, model_context_tokens, output_reserve_tokens)

    maintenance_prompt_bytes = percent(max_prompt_bytes, @maintenance_percent)
    target_prompt_bytes = percent(max_prompt_bytes, @target_percent)
    maintenance_input_tokens = percent(input_budget_tokens, @maintenance_percent)
    target_input_tokens = percent(input_budget_tokens, @target_percent)

    status =
      cond do
        prompt_bytes > max_prompt_bytes or estimated_prompt_tokens > input_budget_tokens ->
          :too_large

        prompt_bytes >= maintenance_prompt_bytes or
            estimated_prompt_tokens >= maintenance_input_tokens ->
          :maintenance_required

        true ->
          :ready
      end

    %__MODULE__{
      status: status,
      prompt_bytes: prompt_bytes,
      max_prompt_bytes: max_prompt_bytes,
      maintenance_prompt_bytes: maintenance_prompt_bytes,
      target_prompt_bytes: target_prompt_bytes,
      estimated_prompt_tokens: estimated_prompt_tokens,
      input_budget_tokens: input_budget_tokens,
      maintenance_input_tokens: maintenance_input_tokens,
      target_input_tokens: target_input_tokens,
      model_context_percent: model_context_percent(estimated_prompt_tokens, model_context_tokens)
    }
  end

  defp input_budget_tokens(context_budget_tokens, nil, _output_reserve_tokens),
    do: context_budget_tokens

  defp input_budget_tokens(context_budget_tokens, model_context_tokens, output_reserve_tokens),
    do: min(context_budget_tokens, model_context_tokens - output_reserve_tokens)

  defp model_context_percent(_estimated_prompt_tokens, nil), do: nil

  defp model_context_percent(estimated_prompt_tokens, model_context_tokens),
    do: div(estimated_prompt_tokens * 100, model_context_tokens)

  defp percent(value, percentage), do: max(div(value * percentage, 100), 1)
end
