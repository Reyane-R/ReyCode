defmodule ReyCode.Orchestration.ModelTier do
  @moduledoc "Legacy Participant tier normalization and informational provider usage accounting."

  @tiers [:smol, :default, :slow]

  @type t :: :smol | :default | :slow

  @doc "Returns the recognized legacy tier labels."
  @spec all() :: [t()]
  def all, do: @tiers

  @doc "Normalizes one configured tier without creating atoms."
  @spec normalize(t() | String.t()) :: {:ok, t()} | {:error, :invalid_model_tier}
  def normalize(value) when value in @tiers, do: {:ok, value}
  def normalize("smol"), do: {:ok, :smol}
  def normalize("default"), do: {:ok, :default}
  def normalize("slow"), do: {:ok, :slow}
  def normalize(_value), do: {:error, :invalid_model_tier}

  @doc "Returns the default tier for one Participant kind."
  @spec default(atom()) :: t()
  def default(:task), do: :smol
  def default(_kind), do: :default

  @doc "Sums known provider-reported tokens across recorded rounds."
  @spec used_tokens(map()) :: non_neg_integer() | nil
  def used_tokens(invocation) do
    usages =
      invocation
      |> Map.get(:rounds, [])
      |> Enum.map(&Map.get(&1, :usage))
      |> Enum.reject(&is_nil/1)

    case usages do
      [] -> usage_tokens(Map.get(invocation, :usage))
      present -> sum_known(Enum.map(present, &usage_tokens/1))
    end
  end

  defp sum_known(values) do
    known = Enum.reject(values, &is_nil/1)
    if known == [], do: nil, else: Enum.sum(known)
  end

  defp usage_tokens(nil), do: nil

  defp usage_tokens(usage) when is_map(usage) do
    nested = Map.get(usage, "tokens", Map.get(usage, :tokens))

    value(usage, "total_tokens") ||
      value(usage, "total") ||
      nested_total(nested) ||
      sum_known([
        value(usage, "prompt_tokens") || value(usage, "input_tokens"),
        value(usage, "completion_tokens") || value(usage, "output_tokens")
      ])
  end

  defp nested_total(tokens) when is_number(tokens), do: trunc(tokens)

  defp nested_total(tokens) when is_map(tokens) do
    value(tokens, "total") ||
      sum_known([
        value(tokens, "input"),
        value(tokens, "output"),
        value(tokens, "reasoning")
      ])
  end

  defp nested_total(_tokens), do: nil

  defp value(map, key) do
    case Map.get(map, key, Map.get(map, key_atom(key))) do
      number when is_number(number) -> trunc(number)
      _other -> nil
    end
  end

  defp key_atom("tokens"), do: :tokens
  defp key_atom("total_tokens"), do: :total_tokens
  defp key_atom("total"), do: :total
  defp key_atom("prompt_tokens"), do: :prompt_tokens
  defp key_atom("completion_tokens"), do: :completion_tokens
  defp key_atom("input_tokens"), do: :input_tokens
  defp key_atom("output_tokens"), do: :output_tokens
  defp key_atom("input"), do: :input
  defp key_atom("output"), do: :output
  defp key_atom("reasoning"), do: :reasoning
end
