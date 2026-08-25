defmodule ReyCode.Provider.OpenCode.Prompt do
  @moduledoc "Builds the OpenCode prompt from a normalized request."

  alias ReyCode.Capabilities
  alias ReyCode.Provider.{Message, Request}

  @spec build(Request.t()) :: binary()
  def build(%Request{} = request) do
    history =
      Enum.map_join(request.messages, "\n\n", fn %Message{} = message ->
        "#{author_name(message)}: #{message.content}"
      end)

    [
      request.system_prompt,
      Capabilities.prompt_hint(),
      "You are responding as #{request.participant.name} with the perspective: #{request.participant.perspective}.",
      "Conversation context:\n#{history}",
      "Respond to the latest user request."
    ]
    |> Enum.join("\n\n")
  end

  defp author_name(%Message{author: %{name: name}}) when is_binary(name) and name != "", do: name
  defp author_name(%Message{role: role}), do: Atom.to_string(role)
end
