defmodule ReyCode.Provider.ModelBudget do
  @moduledoc """
  Resolves byte and token budgets for one exact provider/model pair.

  Provider profile limits are the fallback. Exact built-in metadata refines
  that fallback, and exact configured overrides take final precedence. Model
  identifiers are compared as supplied; resolution never trims, folds case,
  or converts them to atoms.
  """

  @enforce_keys [:max_prompt_bytes, :context_window_tokens, :output_reserve_tokens]
  defstruct @enforce_keys ++ [output_limit_parameter: :none]

  @type t :: %__MODULE__{
          max_prompt_bytes: pos_integer(),
          context_window_tokens: pos_integer() | nil,
          output_reserve_tokens: pos_integer(),
          output_limit_parameter: :none | :max_tokens | :max_completion_tokens
        }

  @type override :: %{
          optional(:max_prompt_bytes) => pos_integer(),
          optional(:context_window_tokens) => pos_integer(),
          optional(:output_reserve_tokens) => pos_integer(),
          optional(:output_limit_parameter) => :none | :max_tokens | :max_completion_tokens
        }

  # Z.ai's GLM-4.7 model guide identifies the exact API model ID and reports a
  # 200K context with 128K maximum output: https://docs.z.ai/guides/llm/glm-4.7
  # Maximum output is a capability, not the amount every request must reserve.
  # Keep the profile's planned reserve and raise only the independent bounded
  # request-body ceiling needed to make the advertised context usable.
  @built_ins %{
    {:zai, "glm-4.7"} => %{
      context_window_tokens: 200_000,
      max_prompt_bytes: 2_000_000,
      output_limit_parameter: :max_tokens
    },
    {:zai_coding, "glm-4.7"} => %{
      context_window_tokens: 200_000,
      max_prompt_bytes: 2_000_000,
      output_limit_parameter: :max_tokens
    }
  }

  @doc "Resolves an exact provider/model budget over the provider fallback."
  @spec resolve(atom(), String.t(), t(), %{
          optional(atom()) => %{optional(String.t()) => override()}
        }) ::
          t()
  def resolve(provider_id, model_id, %__MODULE__{} = fallback, overrides)
      when is_atom(provider_id) and is_binary(model_id) and is_map(overrides) do
    configured =
      overrides
      |> Map.get(provider_id, %{})
      |> Map.get(model_id, %{})

    fallback
    |> Map.from_struct()
    |> Map.merge(Map.get(@built_ins, {provider_id, model_id}, %{}))
    |> Map.merge(configured)
    |> then(&struct!(__MODULE__, &1))
    |> validate!()
  end

  defp validate!(%__MODULE__{} = budget) do
    validate_positive!(:max_prompt_bytes, budget.max_prompt_bytes)
    validate_optional_positive!(:context_window_tokens, budget.context_window_tokens)
    validate_positive!(:output_reserve_tokens, budget.output_reserve_tokens)
    validate_output_limit_parameter!(budget.output_limit_parameter)

    if budget.context_window_tokens &&
         budget.output_reserve_tokens >= budget.context_window_tokens do
      raise ArgumentError,
            "invalid model budget: output_reserve_tokens must be less than context_window_tokens"
    end

    budget
  end

  defp validate_optional_positive!(_field, nil), do: :ok
  defp validate_optional_positive!(field, value), do: validate_positive!(field, value)

  defp validate_positive!(_field, value) when is_integer(value) and value > 0, do: :ok

  defp validate_positive!(field, value) do
    raise ArgumentError,
          "invalid model budget #{field}: #{inspect(value)} (expected integer >= 1)"
  end

  defp validate_output_limit_parameter!(value)
       when value in [:none, :max_tokens, :max_completion_tokens],
       do: :ok

  defp validate_output_limit_parameter!(value) do
    raise ArgumentError,
          "invalid model budget output_limit_parameter: #{inspect(value)}"
  end
end
