defmodule ReyCode.TUI.SlashPaletteTest do
  use ExUnit.Case, async: true

  alias ReyCode.TUI.SlashPalette

  test "matches/1 filters commands by prefix" do
    assert Enum.map(SlashPalette.matches("/ag"), & &1.command) == ["/agent", "/agents"]
    assert SlashPalette.matches("/missing") == []
  end

  test "matches/1 prioritizes the compact default and searches the full registry" do
    assert Enum.map(SlashPalette.matches("/mo"), & &1.command) == ["/model"]
    assert Enum.map(SlashPalette.matches("/tl"), & &1.command) == ["/tools"]
    assert Enum.map(SlashPalette.matches("/res"), & &1.command) == ["/resume"]
    assert Enum.map(SlashPalette.matches("/exp"), & &1.command) == ["/export"]

    assert Enum.map(SlashPalette.matches("/"), & &1.command) ==
             ~w(/task /agent /agents /model /connect /new /resume /help)
  end

  test "the registry is the single consistent source of commands and actions" do
    commands = SlashPalette.commands()

    assert Enum.map(commands, & &1.command) == Enum.sort(Enum.map(commands, & &1.command))
    assert Enum.uniq_by(commands, & &1.command) == commands

    assert Enum.all?(commands, fn entry ->
             String.starts_with?(entry.command, "/") and
               is_binary(entry.description) and entry.description != "" and is_atom(entry.action) and
               SlashPalette.command(entry.command) == entry
           end)

    refute SlashPalette.command("/models")
    refute Map.has_key?(SlashPalette.command("/connect"), :argument)
  end

  test "direct command submission dispatches the registry action" do
    direct_term =
      term()
      |> put_in([Access.key(:assigns), :modal], nil)
      |> put_in([Access.key(:assigns), :slash], nil)

    assert {:noreply, result} =
             ReyCode.TUI.handle_event("prompt_submitted", %{value: "/workspace"}, direct_term)

    assert result.assigns.modal == :workspace
    assert result.assigns.slash == nil
    assert result.assigns.drafts["room-1"] == ""
  end

  test "direct help command opens the transient capability modal" do
    direct_term =
      term()
      |> put_in([Access.key(:assigns), :modal], nil)
      |> put_in([Access.key(:assigns), :slash], nil)

    assert {:noreply, result} =
             ReyCode.TUI.handle_event("prompt_submitted", %{value: "/help"}, direct_term)

    assert result.assigns.modal == :help
    assert result.assigns.slash == nil
    assert result.assigns.drafts["room-1"] == ""
  end

  test "open/1 preserves the room draft and focuses the prompt" do
    result = SlashPalette.open(term(draft: "keep me"))

    assert result.assigns.modal == :slash

    assert result.assigns.slash == %{
             query: "/",
             cursor: 1,
             index: 0,
             accepted_id: nil,
             restore_draft: "keep me"
           }

    assert result.assigns.drafts["room-1"] == "/"
    assert result.focused == "prompt"
  end

  test "move/2 wraps around matching commands" do
    term = term(query: "/ag")

    assert SlashPalette.move(term, -1).assigns.slash.index == 1
    assert SlashPalette.move(term, 1).assigns.slash.index == 1
  end

  test "complete/1 accepts the highlighted candidate without executing it" do
    result =
      term(query: "/ag")
      |> put_in([Access.key(:assigns), :slash, :index], 1)
      |> SlashPalette.complete()

    assert result.assigns.slash.query == "/agents"
    assert result.assigns.slash.accepted_id == "command:/agents"
    assert result.assigns.drafts["room-1"] == "/agents"
  end

  test "rows stay within the viewport and a compact menu cap" do
    models = Enum.map(1..20, &"model-#{&1}")

    assigns =
      term(query: "/model ").assigns
      |> Map.put(:providers, %{
        provider: %{id: :provider, name: "Provider", status: :configured, models: models}
      })

    assert length(SlashPalette.rows(assigns, 40)) == 12
    assert length(SlashPalette.rows(assigns, 20)) == 11
    assert length(SlashPalette.rows(assigns, 10)) == 1
    assert SlashPalette.style(80, 10, assigns).height == 2
  end

  test "the root palette prepends commands relevant to current work" do
    labels =
      contextual_term().assigns
      |> SlashPalette.rows(40)
      |> Enum.map(fn {candidate, _index} -> candidate.label end)

    assert Enum.take(labels, 5) == ~w(/tools /steer /cancel /unqueue /hub)
    assert Enum.slice(labels, 5, 7) == ~w(/task /agent /agents /model /connect /new /resume)
  end

  test "cancel/1 restores the original draft" do
    result = term(query: "/mode", restore_draft: "original") |> SlashPalette.cancel()

    assert result.assigns.modal == nil
    assert result.assigns.slash == nil
    assert result.assigns.drafts["room-1"] == "original"
    assert result.focused == "prompt"
  end

  test "close/2 clears palette state and preserves a notice" do
    result = SlashPalette.close(term(), "Unknown command")

    assert result.assigns.modal == nil
    assert result.assigns.slash == nil
    assert result.assigns.notice == "Unknown command"
  end

  defp term(opts \\ []) do
    query = Keyword.get(opts, :query, "/")
    restore_draft = Keyword.get(opts, :restore_draft)
    draft = Keyword.get(opts, :draft, query)

    %Breeze.Term{
      assigns: %{
        selected_room_id: "room-1",
        drafts: %{"room-1" => draft},
        modal: :slash,
        slash: %{
          query: query,
          cursor: String.length(query),
          index: 0,
          accepted_id: nil,
          restore_draft: restore_draft
        },
        notice: nil
      }
    }
  end

  defp contextual_term do
    room = %{
      participants: [],
      workspace: "/tmp",
      active_turn_id: "turn-active",
      queued_turn_ids: ["turn-follow-up"],
      message_order: ["message-child"]
    }

    projection = %{
      rooms: %{"room-1" => room},
      room_order: ["room-1"],
      messages: %{"message-child" => %{invocation_id: "invocation-child"}},
      turns: %{
        "turn-follow-up" => %{input_kind: :follow_up, status: :queued}
      },
      invocations: %{
        "invocation-review" => %{
          id: "invocation-review",
          turn_id: "turn-active",
          pending_tool_review: %{},
          delegated_from_invocation_id: nil
        },
        "invocation-child" => %{
          id: "invocation-child",
          turn_id: "turn-active",
          pending_tool_review: nil,
          delegated_from_invocation_id: "invocation-parent"
        }
      }
    }

    term()
    |> put_in([Access.key(:assigns), :projection], projection)
  end
end
