defmodule ReyCode.Orchestration.OperatorQuestions do
  @moduledoc "Fail-closed bounds and normalization for `ask_operator`."

  alias ReyCode.Orchestration.OperatorQuestion

  @tool_name "ask_operator"
  @question_max_bytes 4_096
  @option_label_max_bytes 160
  @option_description_max_bytes 1_024
  @option_min_count 2
  @option_max_count 5

  @type rejection :: :invalid_question_arguments | :question_too_large

  @doc "Returns the provider-visible question tool name."
  @spec tool_name() :: String.t()
  def tool_name, do: @tool_name

  @doc "Builds one bounded frozen OperatorQuestion."
  @spec build(term(), String.t(), String.t(), String.t()) ::
          {:ok, OperatorQuestion.t()} | {:error, rejection()}
  def build(arguments, question_id, tool_run_id, asked_at) when is_map(arguments) do
    keys = arguments |> Map.keys() |> Enum.map(&to_string/1)
    question = value(arguments, "question")
    options = value(arguments, "options")
    recommended = value(arguments, "recommended")

    with true <- Enum.all?(keys, &(&1 in ~w(question options recommended))),
         true <- valid_text?(question, @question_max_bytes),
         {:ok, options} <- normalize_options(options),
         {:ok, recommended_id} <- recommended_id(recommended, options) do
      {:ok,
       %OperatorQuestion{
         id: question_id,
         tool_run_id: tool_run_id,
         question: question,
         options: options,
         recommended_id: recommended_id,
         asked_at: asked_at
       }}
    else
      false -> {:error, :invalid_question_arguments}
      {:error, _reason} = error -> error
    end
  end

  def build(_arguments, _question_id, _tool_run_id, _asked_at),
    do: {:error, :invalid_question_arguments}

  defp normalize_options(options)
       when is_list(options) and length(options) >= @option_min_count and
              length(options) <= @option_max_count do
    options
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {option, index}, {:ok, normalized} ->
      case normalize_option(option, index) do
        {:ok, value} -> {:cont, {:ok, normalized ++ [value]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_options(_options), do: {:error, :invalid_question_arguments}

  defp normalize_option(option, index) when is_map(option) do
    keys = option |> Map.keys() |> Enum.map(&to_string/1)
    label = value(option, "label")
    description = value(option, "description", "")

    if Enum.all?(keys, &(&1 in ~w(label description))) and
         valid_text?(label, @option_label_max_bytes) and
         is_binary(description) and byte_size(description) <= @option_description_max_bytes do
      {:ok, %{id: "option-#{index}", label: label, description: description}}
    else
      {:error, :invalid_question_arguments}
    end
  end

  defp normalize_option(_option, _index), do: {:error, :invalid_question_arguments}

  defp recommended_id(nil, _options), do: {:ok, nil}

  defp recommended_id(index, options)
       when is_integer(index) and index >= 0 and index < length(options),
       do: {:ok, Enum.at(options, index).id}

  defp recommended_id(_index, _options), do: {:error, :invalid_question_arguments}

  defp valid_text?(text, max_bytes),
    do: is_binary(text) and text != "" and byte_size(text) <= max_bytes

  defp value(map, key, default \\ nil) do
    atom_key =
      %{
        "question" => :question,
        "options" => :options,
        "recommended" => :recommended,
        "label" => :label,
        "description" => :description
      }[key]

    Map.get(map, key, Map.get(map, atom_key, default))
  end
end
