defmodule ReyCode.Orchestration.OperatorQuestion do
  @moduledoc "A bounded durable multiple-choice question awaiting the Operator."

  @fields [:id, :tool_run_id, :question, :options, :recommended_id, :asked_at]
  @enforce_keys @fields
  defstruct @fields

  @type option :: %{id: String.t(), label: String.t(), description: String.t()}
  @type t :: %__MODULE__{
          id: String.t(),
          tool_run_id: String.t(),
          question: String.t(),
          options: [option()],
          recommended_id: String.t() | nil,
          asked_at: String.t()
        }

  @doc "Converts a decoded question map into the typed record."
  @spec from_map(t() | map()) :: t()
  def from_map(%__MODULE__{} = question), do: question

  def from_map(question) when is_map(question) do
    question = struct!(__MODULE__, Map.take(question, @fields))
    %{question | options: Enum.map(question.options, &normalize_option/1)}
  end

  @doc "Encodes a question as an event-safe wire map."
  @spec to_wire(t()) :: map()
  def to_wire(question) do
    %{
      "question_id" => question.id,
      "tool_run_id" => question.tool_run_id,
      "question" => question.question,
      "options" =>
        Enum.map(question.options, fn option ->
          %{
            "id" => option.id,
            "label" => option.label,
            "description" => option.description
          }
        end),
      "recommended_id" => question.recommended_id
    }
  end

  defp normalize_option(option) do
    %{
      id: Map.get(option, :id, Map.get(option, "id")),
      label: Map.get(option, :label, Map.get(option, "label")),
      description: Map.get(option, :description, Map.get(option, "description", ""))
    }
  end
end
