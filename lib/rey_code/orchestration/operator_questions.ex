defmodule ReyCode.Orchestration.OperatorQuestions do
  @moduledoc "Fail-closed bounds and normalization for `ask_operator`."

  alias ReyCode.Orchestration.OperatorQuestion

  @tool_name "ask_operator"
  @question_max_bytes 4_096
  @option_label_max_bytes 160
  @option_description_max_bytes 1_024
  @option_preview_max_bytes 8_192
  @other_max_bytes 4_096
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
    multi? = value(arguments, "multi", false)
    allow_other? = value(arguments, "allow_other", false)

    with true <-
           Enum.all?(keys, &(&1 in ~w(question options recommended multi allow_other))),
         true <- valid_text?(question, @question_max_bytes),
         true <- is_boolean(multi?) and is_boolean(allow_other?),
         {:ok, options} <- normalize_options(options),
         {:ok, recommended_id} <- recommended_id(recommended, options) do
      {:ok,
       %OperatorQuestion{
         id: question_id,
         tool_run_id: tool_run_id,
         question: question,
         options: options,
         recommended_id: recommended_id,
         multi?: multi?,
         allow_other?: allow_other?,
         asked_at: asked_at
       }}
    else
      false -> {:error, :invalid_question_arguments}
      {:error, _reason} = error -> error
    end
  end

  def build(_arguments, _question_id, _tool_run_id, _asked_at),
    do: {:error, :invalid_question_arguments}

  @doc "Validates one single/multi/Other answer against a frozen question."
  @spec resolve(OperatorQuestion.t(), term()) ::
          {:ok, %{option_ids: [String.t()], labels: [String.t()], other: String.t() | nil}}
          | {:error, :invalid_question_selection}
  def resolve(question, selection) do
    {option_ids, other} = answer_parts(selection)
    option_ids = Enum.uniq(option_ids)

    selected =
      Enum.map(option_ids, &Enum.find(question.options, fn option -> option.id == &1 end))

    if valid_answer?(question, option_ids, selected, other) do
      {:ok,
       %{
         option_ids: option_ids,
         labels: Enum.map(selected, & &1.label),
         other: other
       }}
    else
      {:error, :invalid_question_selection}
    end
  end

  defp valid_answer?(question, option_ids, selected, other) do
    Enum.all?(selected, &(not is_nil(&1))) and
      (question.multi? or length(option_ids) <= 1) and
      valid_other?(question, other) and
      (option_ids != [] or not is_nil(other)) and
      (question.multi? or is_nil(other) or option_ids == [])
  end

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
    preview = value(option, "preview", "")

    if Enum.all?(keys, &(&1 in ~w(label description preview))) and
         valid_text?(label, @option_label_max_bytes) and
         is_binary(description) and byte_size(description) <= @option_description_max_bytes and
         is_binary(preview) and byte_size(preview) <= @option_preview_max_bytes do
      {:ok, %{id: "option-#{index}", label: label, description: description, preview: preview}}
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
        "multi" => :multi,
        "allow_other" => :allow_other,
        "label" => :label,
        "description" => :description,
        "preview" => :preview,
        "option_ids" => :option_ids,
        "other" => :other
      }[key]

    Map.get(map, key, Map.get(map, atom_key, default))
  end

  defp answer_parts(selection) when is_binary(selection), do: {[selection], nil}
  defp answer_parts(selection) when is_list(selection), do: {selection, nil}

  defp answer_parts(selection) when is_map(selection) do
    option_ids = value(selection, "option_ids", [])
    other = value(selection, "other")
    {if(is_list(option_ids), do: option_ids, else: []), normalize_other(other)}
  end

  defp answer_parts(_selection), do: {[], nil}

  defp normalize_other(other) when is_binary(other) do
    other = String.trim(other)
    if other == "", do: nil, else: other
  end

  defp normalize_other(_other), do: nil

  defp valid_other?(_question, nil), do: true

  defp valid_other?(question, other),
    do:
      question.allow_other? and is_binary(other) and
        byte_size(other) <= @other_max_bytes
end
