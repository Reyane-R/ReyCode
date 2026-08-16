defmodule ReyCode.Provider.OpenCode.Prompt do
  @moduledoc "Builds the OpenCode prompt from a normalized request."

  alias ReyCode.Provider.Request

  @spec build(Request.t()) :: binary()
  def build(%Request{} = request) do
    history =
      Enum.map_join(request.messages, "\n\n", fn message ->
        name = get_in(message, [:author, :name]) || Atom.to_string(message.role)
        "#{name}: #{message.content}"
      end)

    [
      request.system_prompt,
      "You are responding as #{request.participant.name} with the perspective: #{request.participant.perspective}.",
      "Conversation context:\n#{history}",
      "Respond to the latest user request."
    ]
    |> Enum.join("\n\n")
  end
end
