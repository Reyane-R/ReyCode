defmodule ReyCode.Orchestration.OperatorQuestion do
  @moduledoc "A bounded durable OperatorQuestion request envelope awaiting the Operator."

  defmodule Item do
    @moduledoc "One ordered question in an OperatorQuestion request envelope."

    @fields [:id, :header, :question, :options, :recommended_id, :multi?, :allow_other?]
    @enforce_keys [:id, :header, :question, :options, :recommended_id]
    defstruct @enforce_keys ++ [multi?: false, allow_other?: false]

    @type option :: %{
            id: String.t(),
            label: String.t(),
            description: String.t(),
            preview: String.t()
          }
    @type t :: %__MODULE__{
            id: String.t(),
            header: String.t(),
            question: String.t(),
            options: [option()],
            recommended_id: String.t() | nil,
            multi?: boolean(),
            allow_other?: boolean()
          }

    @doc false
    @spec from_map(t() | map()) :: t()
    def from_map(%__MODULE__{} = item), do: item |> Map.from_struct() |> from_map()

    def from_map(item) when is_map(item) do
      item
      |> attributes(@fields)
      |> then(&struct!(__MODULE__, &1))
      |> normalize()
    end

    @doc false
    @spec to_wire(t()) :: map()
    def to_wire(item) do
      %{
        "question_id" => item.id,
        "header" => item.header,
        "question" => item.question,
        "options" => Enum.map(item.options, &option_to_wire/1),
        "recommended_id" => item.recommended_id,
        "multi" => item.multi?,
        "allow_other" => item.allow_other?
      }
    end

    defp normalize(item) do
      %{
        item
        | options: Enum.map(item.options, &normalize_option/1),
          multi?: item.multi? == true,
          allow_other?: item.allow_other? == true
      }
    end

    defp normalize_option(option) do
      %{
        id: fetch(option, :id),
        label: fetch(option, :label),
        description: fetch(option, :description, ""),
        preview: fetch(option, :preview, "")
      }
    end

    defp option_to_wire(option) do
      %{
        "id" => option.id,
        "label" => option.label,
        "description" => Map.get(option, :description, ""),
        "preview" => Map.get(option, :preview, "")
      }
    end

    defp attributes(map, fields) do
      fields
      |> Enum.reduce(%{}, fn field, attributes ->
        if has_field?(map, field) do
          Map.put(attributes, field, fetch(map, field))
        else
          attributes
        end
      end)
    end

    defp has_field?(map, key),
      do:
        Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key)) or
          Map.has_key?(map, wire_key(key))

    defp fetch(map, key, default \\ nil) do
      Map.get(map, key, Map.get(map, Atom.to_string(key), Map.get(map, wire_key(key), default)))
    end

    defp wire_key(:id), do: "question_id"
    defp wire_key(:multi?), do: "multi"
    defp wire_key(:allow_other?), do: "allow_other"
    defp wire_key(key), do: Atom.to_string(key)
  end

  @fields [
    :id,
    :tool_run_id,
    :questions,
    :question,
    :options,
    :recommended_id,
    :multi?,
    :allow_other?,
    :legacy_singular?,
    :asked_at
  ]
  @enforce_keys [:id, :tool_run_id, :question, :options, :recommended_id, :asked_at]
  defstruct @enforce_keys ++
              [questions: [], multi?: false, allow_other?: false, legacy_singular?: false]

  @type option :: Item.option()
  @type t :: %__MODULE__{
          id: String.t(),
          tool_run_id: String.t(),
          questions: [Item.t()],
          question: String.t(),
          options: [option()],
          recommended_id: String.t() | nil,
          multi?: boolean(),
          allow_other?: boolean(),
          legacy_singular?: boolean(),
          asked_at: String.t()
        }

  @doc "Converts a decoded or historical singular question map into the typed envelope."
  @spec from_map(t() | map()) :: t()
  def from_map(%__MODULE__{} = question), do: question |> Map.from_struct() |> from_map()

  def from_map(question) when is_map(question) do
    legacy_singular? = legacy_singular?(question)

    question
    |> attributes(@fields)
    |> Map.put(:legacy_singular?, legacy_singular?)
    |> then(&struct!(__MODULE__, &1))
    |> normalize()
  end

  @doc "Encodes a question envelope as an event-safe wire map."
  @spec to_wire(t()) :: map()
  def to_wire(question) do
    question = from_map(question)

    %{
      "question_id" => question.id,
      "tool_run_id" => question.tool_run_id,
      "questions" => Enum.map(question.questions, &Item.to_wire/1),
      "question" => question.question,
      "options" => Enum.map(question.options, &option_to_wire/1),
      "recommended_id" => question.recommended_id,
      "multi" => question.multi?,
      "allow_other" => question.allow_other?
    }
  end

  defp normalize(question) do
    questions = normalize_items(question)
    [first | _rest] = questions

    %{
      question
      | questions: questions,
        question: first.question,
        options: first.options,
        recommended_id: first.recommended_id,
        multi?: first.multi?,
        allow_other?: first.allow_other?
    }
  end

  defp normalize_items(%{questions: questions}) when is_list(questions) and questions != [],
    do: Enum.map(questions, &Item.from_map/1)

  defp normalize_items(question) do
    [
      %Item{
        id: "question-0",
        header: "Question",
        question: question.question,
        options: Enum.map(question.options, &normalize_option/1),
        recommended_id: question.recommended_id,
        multi?: question.multi? == true,
        allow_other?: question.allow_other? == true
      }
    ]
  end

  defp normalize_option(option) do
    %{
      id: fetch(option, :id),
      label: fetch(option, :label),
      description: fetch(option, :description, ""),
      preview: fetch(option, :preview, "")
    }
  end

  defp option_to_wire(option) do
    %{
      "id" => option.id,
      "label" => option.label,
      "description" => Map.get(option, :description, ""),
      "preview" => Map.get(option, :preview, "")
    }
  end

  defp attributes(map, fields) do
    fields
    |> Enum.reduce(%{}, fn field, attributes ->
      if Map.has_key?(map, field) or Map.has_key?(map, Atom.to_string(field)) do
        Map.put(attributes, field, fetch(map, field))
      else
        attributes
      end
    end)
  end

  defp fetch(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp legacy_singular?(question) do
    questions = fetch(question, :questions, [])
    fetch(question, :legacy_singular?, false) == true or questions in [nil, []]
  end
end
