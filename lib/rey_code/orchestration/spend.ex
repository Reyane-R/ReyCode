defmodule ReyCode.Orchestration.Spend do
  @moduledoc """
  Estimates session spend in USD from provider-reported token usage.

  Rates are USD list prices per one million tokens, keyed by model id with
  case-insensitive lookup. Overrides load from a bounded `pricing.json`;
  malformed files or entries are skipped with a warning, never fatal.
  Estimation fails closed: a round whose usage lacks a known input/output
  split, or a model with no rate, leaves the aggregate unavailable rather
  than guessing. Costs are computed at display time from current rates and
  never persisted, so historical sessions reprice when rates change.
  """

  require Logger

  @max_file_bytes 32_768
  @max_model_count 256
  @max_model_id_bytes 128
  @tokens_per_mtok 1_000_000

  @type rate :: %{input_per_mtok: number(), output_per_mtok: number()}
  @type rates :: %{String.t() => rate()}

  # USD per 1M tokens, checked 2026-09-17: Z.ai list prices
  # (docs.z.ai/guides/overview/pricing) and DeepSeek peak list prices
  # (api-docs.deepseek.com/quick_start/pricing). No cache discount is
  # modeled; override any entry from pricing.json.
  @built_in %{
    "deepseek-flash" => %{input_per_mtok: 0.3, output_per_mtok: 1.2},
    "deepseek-v4-pro" => %{input_per_mtok: 1.32, output_per_mtok: 3.96},
    "glm-4.5" => %{input_per_mtok: 0.6, output_per_mtok: 2.2},
    "glm-4.5-air" => %{input_per_mtok: 0.2, output_per_mtok: 1.1},
    "glm-4.5-flash" => %{input_per_mtok: 0.0, output_per_mtok: 0.0},
    "glm-4.6" => %{input_per_mtok: 0.6, output_per_mtok: 2.2},
    "glm-4.7" => %{input_per_mtok: 0.6, output_per_mtok: 2.2},
    "glm-4.7-flash" => %{input_per_mtok: 0.0, output_per_mtok: 0.0},
    "glm-5" => %{input_per_mtok: 1.0, output_per_mtok: 3.2},
    "glm-5.1" => %{input_per_mtok: 1.4, output_per_mtok: 4.4},
    "glm-5.2" => %{input_per_mtok: 1.4, output_per_mtok: 4.4},
    "glm-5.3" => %{input_per_mtok: 1.4, output_per_mtok: 4.4},
    "glm-5.3-flash" => %{input_per_mtok: 0.15, output_per_mtok: 0.5}
  }

  @doc "Built-in list prices, USD per 1M tokens, keyed by model id."
  @spec built_in() :: rates()
  def built_in, do: @built_in

  @doc "Merges optional JSON overrides over built-in rates; malformed files fall back to built-ins."
  @spec resolve(String.t()) :: rates()
  def resolve(path) when is_binary(path) do
    case read_overrides(path) do
      {:ok, overrides, 0} ->
        Map.merge(@built_in, overrides)

      {:ok, overrides, ignored_count} ->
        Logger.warning(
          "pricing overrides: ignored #{ignored_count} invalid #{Path.basename(path)} entries"
        )

        Map.merge(@built_in, overrides)

      {:error, reason} ->
        Logger.warning(
          "pricing overrides ignored (#{Path.basename(path)}): #{format_reason(reason)}"
        )

        @built_in
    end
  end

  @doc "Returns the rate for one model id, or nil when the model has no known price."
  @spec rate_for(rates(), String.t() | nil) :: rate() | nil
  def rate_for(_rates, nil), do: nil

  def rate_for(rates, model_id) when is_binary(model_id) do
    Map.get(rates, String.trim(model_id) |> String.downcase())
  end

  @doc "Cost of one usage map, or nil without a known input and output token split."
  @spec round_cost_usd(map() | nil, rate()) :: float() | nil
  def round_cost_usd(nil, _rate), do: nil

  def round_cost_usd(usage, rate) when is_map(usage) do
    with input when is_number(input) <- pick(usage, "prompt_tokens", "input_tokens"),
         output when is_number(output) <- pick(usage, "completion_tokens", "output_tokens"),
         true <- input >= 0 and output >= 0 do
      (input * rate.input_per_mtok + output * rate.output_per_mtok) / @tokens_per_mtok
    else
      _miss -> nil
    end
  end

  def round_cost_usd(_usage, _rate), do: nil

  @doc """
  Sums spend across invocations. Returns :unavailable when no round reports
  usage or when any usage-bearing round cannot be priced.
  """
  @spec session_cost_usd([map()], rates()) :: {:ok, float()} | :unavailable
  def session_cost_usd(invocations, rates) when is_list(invocations) and is_map(rates) do
    invocations
    |> Enum.flat_map(&round_usages/1)
    |> sum_rounds(rates)
  end

  defp sum_rounds([], _rates), do: :unavailable

  defp sum_rounds(rounds, rates) do
    Enum.reduce(rounds, {:ok, 0.0}, fn {usage, model}, acc ->
      add_round(acc, usage, model, rates)
    end)
  end

  defp add_round(:unavailable, _usage, _model, _rates), do: :unavailable

  defp add_round({:ok, total}, usage, model, rates) do
    with rate when not is_nil(rate) <- rate_for(rates, model),
         cost when not is_nil(cost) <- round_cost_usd(usage, rate) do
      {:ok, total + cost}
    else
      _unpriceable -> :unavailable
    end
  end

  @doc "One-line spend label for an aggregate: a dollar amount when known, an em dash when not."
  @spec label([map()], rates()) :: String.t()
  def label(invocations, rates) do
    case session_cost_usd(invocations, rates) do
      {:ok, usd} -> "$" <> format_usd(usd)
      :unavailable -> "—"
    end
  end

  @doc "Formats USD with two decimals, four below one cent."
  @spec format_usd(number()) :: String.t()
  def format_usd(usd) when is_number(usd) do
    decimals = if usd < 0.01, do: 4, else: 2
    :erlang.float_to_binary(usd * 1.0, decimals: decimals)
  end

  defp read_overrides(path) do
    case File.read(path) do
      {:ok, bytes} when byte_size(bytes) <= @max_file_bytes -> decode_overrides(bytes)
      {:ok, _bytes} -> {:error, :file_too_large}
      {:error, :enoent} -> {:ok, %{}, 0}
      {:error, reason} -> {:error, {:unreadable, reason}}
    end
  end

  defp decode_overrides(bytes) do
    with {:ok, decoded} <- Jason.decode(bytes),
         true <- is_map(decoded) || {:error, :not_an_object},
         true <- map_size(decoded) <= @max_model_count || {:error, :too_many_entries} do
      collect_entries(decoded)
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      {:error, reason} -> {:error, reason}
    end
  end

  defp collect_entries(decoded) do
    {overrides, ignored_count} =
      Enum.reduce(decoded, {%{}, 0}, fn entry, {acc, ignored} ->
        case parse_entry(entry) do
          {:ok, id, rate} -> {Map.put(acc, id, rate), ignored}
          :error -> {acc, ignored + 1}
        end
      end)

    {:ok, overrides, ignored_count}
  end

  defp parse_entry({model_id, raw}) when is_binary(model_id) do
    id = model_id |> String.trim() |> String.downcase()

    if valid_id?(id) do
      case parse_rate(raw) do
        {:ok, rate} -> {:ok, id, rate}
        :error -> :error
      end
    else
      :error
    end
  end

  defp parse_entry(_entry), do: :error

  defp valid_id?(id), do: id != "" and byte_size(id) <= @max_model_id_bytes

  defp parse_rate(%{"input_per_mtok" => input, "output_per_mtok" => output})
       when is_number(input) and is_number(output) and input >= 0 and output >= 0,
       do: {:ok, %{input_per_mtok: input, output_per_mtok: output}}

  defp parse_rate(_raw), do: :error

  defp format_reason(:file_too_large), do: "file exceeds 32 KB"
  defp format_reason(:not_an_object), do: "JSON must be an object"
  defp format_reason(:too_many_entries), do: "too many model entries"
  defp format_reason(:invalid_json), do: "invalid JSON"
  defp format_reason({:unreadable, reason}), do: "unreadable: #{inspect(reason)}"

  defp round_usages(invocation) do
    model = invocation |> Map.get(:participant) |> model_id()

    usage_maps =
      invocation
      |> Map.get(:rounds, [])
      |> Enum.map(&Map.get(&1, :usage))
      |> Enum.reject(&is_nil/1)

    usage_maps =
      case usage_maps do
        [] -> invocation_usage(Map.get(invocation, :usage))
        present -> present
      end

    Enum.map(usage_maps, &{&1, model})
  end

  defp invocation_usage(nil), do: []
  defp invocation_usage(usage), do: [usage]

  defp model_id(nil), do: nil
  defp model_id(participant), do: Map.get(participant, :model)

  defp pick(usage, primary, alias_key) do
    case Map.get(usage, primary) do
      nil -> Map.get(usage, alias_key)
      value -> value
    end
  end
end
