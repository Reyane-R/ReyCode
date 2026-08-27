defmodule ReyCode.SessionExportTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.{Author, Message, Projection, Room}
  alias ReyCode.SessionExport

  test "renders deterministic Markdown and escaped HTML without changing Projection" do
    room = %Room{
      id: "session-1",
      title: "Review <main>",
      workspace: "/workspace",
      message_order: ["assistant", "user"],
      parent_room_id: "session-parent",
      forked_from_sequence: 12
    }

    projection = %Projection{
      sequence: 20,
      rooms: %{room.id => room},
      room_order: [room.id],
      messages: %{
        "user" => %Message{
          id: "user",
          author: Author.user("You"),
          role: :user,
          status: :completed,
          body: "Ship it",
          created_sequence: 2
        },
        "assistant" => %Message{
          id: "assistant",
          author: %Author{kind: :agent, id: "assistant", name: "Assistant"},
          role: :assistant,
          status: :completed,
          body: "Done <safely>",
          created_sequence: 3
        }
      }
    }

    assert {:ok, markdown} = SessionExport.render(projection, room.id, :markdown)
    assert markdown =~ "# Review <main>"
    assert markdown =~ "Forked from `session-parent` at sequence 12"
    assert markdown =~ ~r/## You.*Ship it.*## Assistant.*Done <safely>/s

    assert {:ok, html} = SessionExport.render(projection, room.id, :html)
    assert html =~ "Review &lt;main&gt;"
    assert html =~ "Done &lt;safely&gt;"
    assert projection.sequence == 20
  end
end
