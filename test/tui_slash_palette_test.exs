defmodule ReyCode.TUI.SlashPaletteTest do
  use ExUnit.Case, async: true

  alias ReyCode.TUI.SlashPalette

  test "matches/1 filters commands by prefix" do
    assert Enum.map(SlashPalette.matches("/ag"), & &1.command) == ["/agent", "/agents"]
    assert SlashPalette.matches("/missing") == []
  end

  test "matches/1 ranks exact, prefix, substring, then subsequence" do
    assert Enum.map(SlashPalette.matches("/mo"), & &1.command) == ["/model"]
    assert Enum.map(SlashPalette.matches("/tl"), & &1.command) == ["/tools"]
    assert Enum.map(SlashPalette.matches("/res"), & &1.command) == ["/resume"]

    assert Enum.map(SlashPalette.matches("/"), & &1.command) ==
             Enum.map(SlashPalette.commands(), & &1.command)
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

  test "open/1 preserves the room draft and focuses the prompt" do
    result = SlashPalette.open(term(draft: "keep me"))

    assert result.assigns.modal == :slash
    assert result.assigns.slash == %{query: "/", index: 0, restore_draft: "keep me"}
    assert result.assigns.drafts["room-1"] == "/"
    assert result.focused == "prompt"
  end

  test "move/2 wraps around matching commands" do
    term = term(query: "/ag")

    assert SlashPalette.move(term, -1).assigns.slash.index == 1
    assert SlashPalette.move(term, 1).assigns.slash.index == 1
  end

  test "complete/1 uses the first matching command" do
    result = term(query: "/ag") |> SlashPalette.complete()

    assert result.assigns.slash.query == "/agent"
    assert result.assigns.drafts["room-1"] == "/agent"
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
        slash: %{query: query, index: 0, restore_draft: restore_draft},
        notice: nil
      }
    }
  end
end
