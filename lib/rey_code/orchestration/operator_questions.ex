defmodule ReyCode.Orchestration.OperatorQuestions do
  @moduledoc "Fail-closed bounds and normalization for `ask_operator`."

  alias ReyCode.Orchestration.OperatorQuestion
  alias ReyCode.Orchestration.OperatorQuestion.Item

  @tool_name "ask_operator"
  @header_max_codepoints 80
  @question_max_codepoints 4_096
  @option_label_max_codepoints 160
  @option_description_max_codepoints 1_024
  @option_preview_max_codepoints 8_192
  @other_max_bytes 4_096
  @id_max_bytes 128
  @question_min_count 1
  @question_max_count 4
  @option_min_count 2
  @option_max_count 5

  @singular_keys ~w(question options recommended multi allow_other)
  @item_keys ~w(header question options recommended multi allow_other)
  @answer_keys ~w(question_id option_ids other)
  @answer_wire_keys ~w(question_id question option_ids labels other)

  @type rejection :: :invalid_question_arguments | :question_too_large
  @type answer :: %{
          question_id: String.t(),
          question: String.t(),
          option_ids: [String.t()],
          labels: [String.t()],
          other: String.t() | nil
        }
  @type resolution :: %{
          answers: [answer()],
          option_ids: [String.t()],
          labels: [String.t()],
          other: String.t() | nil
        }

  @doc "Returns the provider-visible question tool name."
  @spec tool_name() :: String.t()
  def tool_name, do: @tool_name

  @doc "Builds one bounded frozen OperatorQuestion request envelope."
  @spec build(term(), String.t(), String.t(), String.t()) ::
          {:ok, OperatorQuestion.t()} | {:error, rejection()}
  def build(arguments, request_id, tool_run_id, asked_at) when is_map(arguments) do
    result =
      if has_key?(arguments, "questions") do
        build_grouped(arguments)
      else
        build_legacy(arguments)
      end

    case result do
      {:ok, questions} ->
        [first | _rest] = questions

        {:ok,
         %OperatorQuestion{
           id: request_id,
           tool_run_id: tool_run_id,
           questions: questions,
           question: first.question,
           options: first.options,
           recommended_id: first.recommended_id,
           multi?: first.multi?,
           allow_other?: first.allow_other?,
           asked_at: asked_at
         }}

      {:error, _reason} = error ->
        error
    end
  end

  def build(_arguments, _request_id, _tool_run_id, _asked_at),
    do: {:error, :invalid_question_arguments}

  @doc "Restores and validates one durable OperatorQuestion envelope."
  @spec restore(term()) :: {:ok, OperatorQuestion.t()} | {:error, :invalid_question_arguments}
  def restore(question) do
    if legacy_envelope?(question),
      do: restore(question, 1, false),
      else: restore(question, @option_min_count, true)
  end

  @doc false
  @spec restore_grouped(term()) ::
          {:ok, OperatorQuestion.t()} | {:error, :invalid_question_arguments}
  def restore_grouped(question) do
    if legacy_envelope?(question),
      do: {:error, :invalid_question_arguments},
      else: restore(question, @option_min_count, true)
  end

  defp restore(question, option_min_count, strict_ids?) when is_map(question) do
    question = OperatorQuestion.from_map(question)

    if valid_envelope?(question, option_min_count, strict_ids?),
      do: {:ok, question},
      else: {:error, :invalid_question_arguments}
  rescue
    _error in [ArgumentError, FunctionClauseError, KeyError, MatchError, Protocol.UndefinedError] ->
      {:error, :invalid_question_arguments}
  end

  defp restore(_question, _option_min_count, _strict_ids?),
    do: {:error, :invalid_question_arguments}

  @doc "Restores one durable OperatorQuestion envelope, raising when it is invalid."
  @spec restore!(term()) :: OperatorQuestion.t()
  def restore!(question) do
    case restore(question) do
      {:ok, restored} ->
        restored

      {:error, :invalid_question_arguments} ->
        raise ArgumentError, "invalid OperatorQuestion envelope"
    end
  end

  @doc "Validates grouped answers or a legacy singleton selection against the frozen envelope."
  @spec resolve(OperatorQuestion.t(), term()) ::
          {:ok, resolution()} | {:error, :invalid_question_selection}
  def resolve(question, selection) do
    case restore(question) do
      {:ok, question} -> resolve_selection(question, selection)
      {:error, :invalid_question_arguments} -> {:error, :invalid_question_selection}
    end
  end

  @doc "Encodes one validated answer as the shared event and provider wire shape."
  @spec answer_to_wire(answer()) :: map()
  def answer_to_wire(answer) do
    %{
      "question_id" => answer.question_id,
      "question" => answer.question,
      "option_ids" => answer.option_ids,
      "labels" => answer.labels,
      "other" => answer.other
    }
  end

  @doc false
  @spec validate_answer_wire(term()) :: :ok | {:error, :invalid_question_selection}
  def validate_answer_wire(answers) do
    valid? =
      list_count_between?(answers, @question_min_count, @question_max_count) and
        answers
        |> Enum.with_index()
        |> Enum.all?(fn {answer, index} -> valid_wire_answer?(answer, index) end)

    if valid?, do: :ok, else: {:error, :invalid_question_selection}
  end

  defp build_grouped(arguments) do
    questions = value(arguments, "questions")

    with true <- exact_keys?(arguments, ["questions"]),
         true <- list_count_between?(questions, @question_min_count, @question_max_count) do
      normalize_questions(questions)
    else
      false -> {:error, :invalid_question_arguments}
    end
  end

  defp build_legacy(arguments) do
    with true <- exact_keys?(arguments, @singular_keys),
         {:ok, item} <- normalize_item(arguments, 0, "Question") do
      {:ok, [item]}
    else
      false -> {:error, :invalid_question_arguments}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_questions(questions) do
    questions
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {question, index}, {:ok, normalized} ->
      case normalize_item(question, index, nil) do
        {:ok, item} -> {:cont, {:ok, [item | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_item(item, index, default_header) when is_map(item) do
    header = value(item, "header", default_header)
    question = value(item, "question")
    options = value(item, "options")
    recommended = value(item, "recommended")
    multi? = value(item, "multi", false)
    allow_other? = value(item, "allow_other", false)
    allowed_keys = if is_nil(default_header), do: @item_keys, else: @singular_keys

    with true <- exact_keys?(item, allowed_keys),
         true <- valid_text?(header, @header_max_codepoints),
         true <- valid_text?(question, @question_max_codepoints),
         true <- is_boolean(multi?) and is_boolean(allow_other?),
         {:ok, options} <- normalize_options(options),
         {:ok, recommended_id} <- recommended_id(recommended, options) do
      {:ok,
       %Item{
         id: "question-#{index}",
         header: header,
         question: question,
         options: options,
         recommended_id: recommended_id,
         multi?: multi?,
         allow_other?: allow_other?
       }}
    else
      false -> {:error, :invalid_question_arguments}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_item(_item, _index, _default_header),
    do: {:error, :invalid_question_arguments}

  defp normalize_options(options) do
    if list_count_between?(options, @option_min_count, @option_max_count) do
      normalize_option_list(options)
    else
      {:error, :invalid_question_arguments}
    end
  end

  defp normalize_option_list(options) do
    options
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {option, index}, {:ok, normalized} ->
      case normalize_option(option, index) do
        {:ok, value} -> {:cont, {:ok, [value | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_option(option, index) when is_map(option) do
    label = value(option, "label")
    description = value(option, "description", "")
    preview = value(option, "preview", "")

    if exact_keys?(option, ~w(label description preview)) and
         valid_text?(label, @option_label_max_codepoints) and
         valid_optional_text?(description, @option_description_max_codepoints) and
         valid_optional_text?(preview, @option_preview_max_codepoints) do
      {:ok, %{id: "option-#{index}", label: label, description: description, preview: preview}}
    else
      {:error, :invalid_question_arguments}
    end
  end

  defp normalize_option(_option, _index), do: {:error, :invalid_question_arguments}

  defp recommended_id(nil, _options), do: {:ok, nil}

  defp recommended_id(index, options)
       when is_integer(index) and index >= 0 and index < length(options) do
    {:ok, "option-#{index}"}
  end

  defp recommended_id(_index, _options), do: {:error, :invalid_question_arguments}

  defp grouped_answers(selection) when is_map(selection) do
    if has_key?(selection, "answers") do
      answers = value(selection, "answers")

      if exact_keys?(selection, ["answers"]) and
           list_count_between?(answers, @question_min_count, @question_max_count),
         do: {:ok, answers},
         else: :error
    else
      :legacy
    end
  end

  defp grouped_answers(_selection), do: :legacy

  defp resolve_selection(question, selection) do
    case grouped_answers(selection) do
      {:ok, submitted} ->
        resolve_grouped(question.questions, submitted)

      :legacy when length(question.questions) == 1 ->
        resolve_legacy(question.questions, selection)

      _legacy_or_error ->
        {:error, :invalid_question_selection}
    end
  end

  defp resolve_grouped(questions, submitted) when length(questions) == length(submitted) do
    with {:ok, by_id} <- index_answers(submitted),
         true <- map_size(by_id) == length(questions),
         {:ok, answers} <- resolve_in_order(questions, by_id) do
      resolution(answers)
    else
      false -> {:error, :invalid_question_selection}
      {:error, _reason} = error -> error
    end
  end

  defp resolve_grouped(_questions, _submitted), do: {:error, :invalid_question_selection}

  defp index_answers(submitted) do
    Enum.reduce_while(submitted, {:ok, %{}}, fn answer, {:ok, indexed} ->
      question_id = if is_map(answer), do: value(answer, "question_id"), else: nil

      if is_map(answer) and exact_keys?(answer, @answer_keys) and
           has_key?(answer, "option_ids") and valid_id?(question_id) and
           not Map.has_key?(indexed, question_id) do
        {:cont, {:ok, Map.put(indexed, question_id, answer)}}
      else
        {:halt, {:error, :invalid_question_selection}}
      end
    end)
  end

  defp resolve_in_order(questions, by_id) do
    Enum.reduce_while(questions, {:ok, []}, fn question, {:ok, answers} ->
      case resolve_submitted(question, by_id) do
        {:ok, answer} -> {:cont, {:ok, [answer | answers]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, answers} -> {:ok, Enum.reverse(answers)}
      {:error, _reason} = error -> error
    end
  end

  defp resolve_submitted(question, by_id) do
    case Map.fetch(by_id, question.id) do
      {:ok, submitted} -> resolve_item(question, submitted)
      :error -> {:error, :invalid_question_selection}
    end
  end

  defp resolve_legacy([question], selection) do
    with true <- legacy_selection?(selection),
         {:ok, answer} <- resolve_item(question, selection) do
      resolution([answer])
    else
      false -> {:error, :invalid_question_selection}
      {:error, _reason} = error -> error
    end
  end

  defp resolve_item(question, selection) do
    with {:ok, option_ids, other} <- answer_parts(selection),
         selected <-
           Enum.map(option_ids, &Enum.find(question.options, fn option -> option.id == &1 end)),
         true <- valid_answer?(question, option_ids, selected, other) do
      {:ok,
       %{
         question_id: question.id,
         question: question.question,
         option_ids: option_ids,
         labels: Enum.map(selected, & &1.label),
         other: other
       }}
    else
      false -> {:error, :invalid_question_selection}
      {:error, _reason} = error -> error
    end
  end

  defp resolution([first | _rest] = answers) do
    {:ok,
     %{
       answers: answers,
       option_ids: first.option_ids,
       labels: first.labels,
       other: first.other
     }}
  end

  defp valid_answer?(question, option_ids, selected, other) do
    unique_known_options?(option_ids, selected) and
      selection_count_valid?(question, option_ids) and
      valid_other?(question, other) and
      answer_present?(option_ids, other) and
      single_answer_shape_valid?(question, option_ids, other)
  end

  defp unique_known_options?(option_ids, selected),
    do: option_ids == Enum.uniq(option_ids) and Enum.all?(selected, &(not is_nil(&1)))

  defp selection_count_valid?(%{multi?: true}, _option_ids), do: true
  defp selection_count_valid?(_question, option_ids), do: length(option_ids) <= 1

  defp answer_present?(option_ids, other), do: option_ids != [] or not is_nil(other)

  defp single_answer_shape_valid?(%{multi?: true}, _option_ids, _other), do: true
  defp single_answer_shape_valid?(_question, [], _other), do: true
  defp single_answer_shape_valid?(_question, _option_ids, nil), do: true
  defp single_answer_shape_valid?(_question, _option_ids, _other), do: false

  defp legacy_selection?(selection) when is_binary(selection) or is_list(selection), do: true

  defp legacy_selection?(selection) when is_map(selection),
    do: exact_keys?(selection, ~w(option_ids other))

  defp legacy_selection?(_selection), do: false

  defp answer_parts(selection) when is_binary(selection) do
    if valid_id?(selection),
      do: {:ok, [selection], nil},
      else: {:error, :invalid_question_selection}
  end

  defp answer_parts(selection) when is_list(selection) do
    if valid_option_ids?(selection),
      do: {:ok, selection, nil},
      else: {:error, :invalid_question_selection}
  end

  defp answer_parts(selection) when is_map(selection) do
    option_ids = value(selection, "option_ids", [])
    other = value(selection, "other")

    with true <- valid_option_ids?(option_ids),
         {:ok, other} <- normalize_other(other) do
      {:ok, option_ids, other}
    else
      false -> {:error, :invalid_question_selection}
      {:error, _reason} = error -> error
    end
  end

  defp answer_parts(_selection), do: {:error, :invalid_question_selection}

  defp normalize_other(nil), do: {:ok, nil}

  defp normalize_other(other) when is_binary(other) do
    if String.valid?(other) and byte_size(other) <= @other_max_bytes do
      other = String.trim(other)
      {:ok, if(other == "", do: nil, else: other)}
    else
      {:error, :invalid_question_selection}
    end
  end

  defp normalize_other(_other), do: {:error, :invalid_question_selection}

  defp valid_other?(_question, nil), do: true

  defp valid_other?(question, other),
    do:
      question.allow_other? and is_binary(other) and
        byte_size(other) <= @other_max_bytes and String.valid?(other)

  defp valid_envelope?(question, option_min_count, strict_ids?) do
    valid_id?(question.id) and valid_id?(question.tool_run_id) and
      valid_text?(question.asked_at, @id_max_bytes) and
      list_count_between?(question.questions, @question_min_count, @question_max_count) and
      question.questions
      |> Enum.with_index()
      |> Enum.all?(fn {item, index} ->
        valid_item?(item, index, option_min_count, strict_ids?)
      end)
  end

  defp valid_item?(item, index, option_min_count, strict_ids?) do
    item.id == "question-#{index}" and
      valid_text?(item.header, @header_max_codepoints) and
      valid_text?(item.question, @question_max_codepoints) and is_boolean(item.multi?) and
      is_boolean(item.allow_other?) and valid_item_options?(item, option_min_count, strict_ids?)
  end

  defp valid_item_options?(item, option_min_count, strict_ids?) do
    list_count_between?(item.options, option_min_count, @option_max_count) and
      item.options
      |> Enum.with_index()
      |> Enum.all?(fn {option, option_index} ->
        valid_option?(option, option_index, strict_ids?)
      end) and
      Enum.uniq_by(item.options, & &1.id) == item.options and valid_recommendation?(item)
  end

  defp valid_recommendation?(%{recommended_id: nil}), do: true

  defp valid_recommendation?(item),
    do: Enum.any?(item.options, &(&1.id == item.recommended_id))

  defp valid_option?(option, index, strict_ids?) do
    (not strict_ids? or option.id == "option-#{index}") and valid_id?(option.id) and
      valid_text?(option.label, @option_label_max_codepoints) and
      valid_optional_text?(option.description, @option_description_max_codepoints) and
      valid_optional_text?(option.preview, @option_preview_max_codepoints)
  end

  defp valid_option_ids?(option_ids) do
    list_count_between?(option_ids, 0, @option_max_count) and
      Enum.all?(option_ids, &valid_id?/1)
  end

  defp valid_wire_answer?(answer, index) when is_map(answer) do
    option_ids = value(answer, "option_ids")
    labels = value(answer, "labels")
    other = value(answer, "other")

    valid_wire_answer_shape?(answer, index) and
      valid_wire_selection?(option_ids, labels, other)
  end

  defp valid_wire_answer?(_answer, _index), do: false

  defp valid_wire_answer_shape?(answer, index) do
    exact_keys?(answer, @answer_wire_keys) and
      Enum.all?(@answer_wire_keys, &has_key?(answer, &1)) and
      value(answer, "question_id") == "question-#{index}" and
      valid_text?(value(answer, "question"), @question_max_codepoints)
  end

  defp valid_wire_selection?(option_ids, labels, other) do
    valid_option_ids?(option_ids) and option_ids == Enum.uniq(option_ids) and
      valid_wire_labels?(labels, option_ids) and valid_wire_other?(other) and
      (option_ids != [] or not is_nil(other))
  end

  defp valid_wire_labels?(labels, option_ids) do
    list_count_between?(labels, 0, @option_max_count) and length(labels) == length(option_ids) and
      Enum.all?(labels, &valid_text?(&1, @option_label_max_codepoints))
  end

  defp valid_wire_other?(nil), do: true

  defp valid_wire_other?(other),
    do:
      is_binary(other) and String.valid?(other) and byte_size(other) <= @other_max_bytes and
        String.trim(other) != ""

  defp legacy_envelope?(question) when is_map(question) do
    questions = Map.get(question, :questions, Map.get(question, "questions", []))

    Map.get(
      question,
      :legacy_singular?,
      Map.get(question, "legacy_singular?", false)
    ) == true or questions in [nil, []]
  end

  defp legacy_envelope?(_question), do: false

  defp valid_id?(value),
    do:
      is_binary(value) and value != "" and byte_size(value) <= @id_max_bytes and
        String.valid?(value)

  defp valid_text?(text, max_codepoints),
    do:
      is_binary(text) and text != "" and String.valid?(text) and
        codepoint_count_within?(text, max_codepoints)

  defp valid_optional_text?(text, max_codepoints),
    do: is_binary(text) and String.valid?(text) and codepoint_count_within?(text, max_codepoints)

  defp codepoint_count_within?(text, max_count),
    do: do_codepoint_count_within?(text, max_count)

  defp do_codepoint_count_within?(<<>>, _remaining_count), do: true
  defp do_codepoint_count_within?(_text, 0), do: false

  defp do_codepoint_count_within?(<<_codepoint::utf8, rest::binary>>, remaining_count),
    do: do_codepoint_count_within?(rest, remaining_count - 1)

  defp list_count_between?(list, min_count, max_count) when is_list(list),
    do: bounded_list_count(list, 0, max_count) in min_count..max_count

  defp list_count_between?(_list, _min_count, _max_count), do: false

  defp bounded_list_count([], count, _max_count), do: count
  defp bounded_list_count(_list, count, max_count) when count == max_count, do: max_count + 1

  defp bounded_list_count([_item | rest], count, max_count),
    do: bounded_list_count(rest, count + 1, max_count)

  defp exact_keys?(map, allowed) do
    keys = Enum.map(Map.keys(map), &key_name/1)

    Enum.all?(keys, &(&1 in allowed)) and
      length(keys) == length(Enum.uniq(keys))
  end

  defp key_name(key) when is_binary(key), do: key
  defp key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp key_name(_key), do: nil

  defp has_key?(map, key),
    do: Map.has_key?(map, key) or Map.has_key?(map, known_atom_key(key))

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, known_atom_key(key), default))

  defp known_atom_key("questions"), do: :questions
  defp known_atom_key("header"), do: :header
  defp known_atom_key("question"), do: :question
  defp known_atom_key("options"), do: :options
  defp known_atom_key("recommended"), do: :recommended
  defp known_atom_key("multi"), do: :multi
  defp known_atom_key("allow_other"), do: :allow_other
  defp known_atom_key("label"), do: :label
  defp known_atom_key("description"), do: :description
  defp known_atom_key("preview"), do: :preview
  defp known_atom_key("answers"), do: :answers
  defp known_atom_key("question_id"), do: :question_id
  defp known_atom_key("labels"), do: :labels
  defp known_atom_key("option_ids"), do: :option_ids
  defp known_atom_key("other"), do: :other
end
