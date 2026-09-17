defmodule ReyCode.TUI.SlashPaletteTest do
  use ExUnit.Case, async: true

  alias ReyCode.TUI.{Notice, PaletteMenu, SlashPalette}

  test "matches/1 filters commands by prefix" do
    assert Enum.take(Enum.map(SlashPalette.matches("/ag"), & &1.command), 2) == [
             "/agent",
             "/agents"
           ]

    assert SlashPalette.matches("/missing") == []
  end

  test "matches/1 prioritizes the compact default and searches the full registry" do
    assert Enum.map(SlashPalette.matches("/mo"), & &1.command) == ["/model"]
    assert Enum.map(SlashPalette.matches("/tl"), & &1.command) == ["/tools"]
    assert Enum.map(SlashPalette.matches("/res"), & &1.command) == ["/resume"]
    assert Enum.map(SlashPalette.matches("/exp"), & &1.command) == ["/export"]

    assert Enum.map(SlashPalette.matches("/"), & &1.command) ==
             ~w(/new /resume /agents /@agents /@review /@settings)
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

    assert SlashPalette.move(term, -1).assigns.slash.index ==
             length(SlashPalette.matches("/ag")) - 1

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
    assert length(SlashPalette.rows(assigns, 20)) == 10
    assert length(SlashPalette.rows(assigns, 10)) == 1
    assert SlashPalette.style(80, 10, assigns).height == 3
  end

  test "the root palette prepends commands relevant to current work" do
    labels =
      contextual_term().assigns
      |> SlashPalette.rows(40)
      |> Enum.map(fn {candidate, _index} -> candidate.label end)

    assert Enum.take(labels, 3) == ~w(/cancel /steer /dequeue)

    assert Enum.drop(labels, 3) == ~w(/new /resume /agents /@agents /@review /@settings)
  end

  test "cancel/1 restores the original draft" do
    result = term(query: "/mode", restore_draft: "original") |> SlashPalette.cancel()

    assert result.assigns.modal == nil
    assert result.assigns.slash == nil
    assert result.assigns.drafts["room-1"] == "original"
    assert result.focused == "prompt"
  end

  test "root uses goal labels and groups browse without replacing the original draft" do
    opened = SlashPalette.open(term(draft: "Keep my question"))

    labels =
      opened.assigns
      |> SlashPalette.rows(40)
      |> Enum.map(fn {candidate, _} -> PaletteMenu.label(candidate) end)

    assert labels == [
             "New conversation",
             "Resume a conversation",
             "Choose a model",
             "Work with task agents…",
             "Review work…",
             "Settings…"
           ]

    {:noreply, grouped} = opened |> SlashPalette.move(4) |> SlashPalette.execute_selected()
    assert grouped.assigns.modal == :slash
    assert grouped.assigns.slash.group == :review
    assert grouped.assigns.slash.restore_draft == "Keep my question"

    names =
      grouped.assigns
      |> SlashPalette.rows(40)
      |> Enum.map(fn {candidate, _} -> candidate.value end)

    assert "/challenge" in names and "/runs" in names and "/verify" in names
    assert SlashPalette.command("/@review") == nil
    {:noreply, root} = SlashPalette.handle_input("Escape", grouped)
    assert root.assigns.modal == :slash
    assert root.assigns.slash.group == :root
    {:noreply, closed} = SlashPalette.handle_input("Escape", root)
    assert closed.assigns.drafts["room-1"] == "Keep my question"
  end

  test "plain-language phrases find actions without breaking explicit argument completion" do
    assert hd(SlashPalette.matches("/switch model")).command == "/agents"
    assert hd(SlashPalette.matches("/why")).command == "/challenge"
    assert hd(SlashPalette.matches("/check changes")).command == "/verify"
    assert hd(SlashPalette.matches("/check changes")).palette_open?
    assert SlashPalette.matches("/not a real action zzzz") == []
    assert hd(SlashPalette.matches("/model")).command == "/model"
    assert SlashPalette.matches("/steer change direction") == []
  end

  test "a grouped action dispatches once and restores the existing draft" do
    root = SlashPalette.open(term(draft: "Keep my question"))
    {:noreply, settings} = root |> SlashPalette.move(5) |> SlashPalette.execute_selected()
    assert settings.assigns.slash.group == :settings
    {:noreply, help} = settings |> SlashPalette.move(4) |> SlashPalette.execute_selected()
    assert help.assigns.modal == :help
    assert help.assigns.slash == nil
    assert help.assigns.drafts["room-1"] == "Keep my question"
  end

  test "Tab browses a group without inserting an internal navigation token" do
    grouped = term(restore_draft: "Keep me") |> SlashPalette.move(4) |> SlashPalette.complete()
    assert grouped.assigns.slash.group == :review
    assert grouped.assigns.drafts["room-1"] == "/"
    refute grouped.assigns.drafts["room-1"] =~ "@review"
  end

  test "semantic activation retains trailing arguments and revalidates them" do
    searching =
      term(query: "/exit unexpected")
      |> put_in([Access.key(:assigns), :slash, :cursor], 5)

    assert {:noreply, result} = SlashPalette.execute_selected(searching)
    assert result.assigns.drafts["room-1"] == "/quit unexpected"
    assert result.assigns.modal == :slash
    assert %Notice{severity: :warning} = result.assigns.notice
  end

  test "palette placement stays inside very short terminals" do
    for height <- 1..10 do
      style = SlashPalette.style(50, height, %{query: "/"})
      assert style.height >= 1
      assert style.bottom >= 0
      assert style.bottom + style.height <= height
    end
  end

  test "an unmatched action search does not discard the original draft" do
    assert {:noreply, result} =
             SlashPalette.execute_selected(
               term(query: "/zzzz no action", restore_draft: "Keep my work")
             )

    assert result.assigns.drafts["room-1"] == "Keep my work"
    assert result.assigns.modal == nil
    assert %Notice{severity: :warning} = result.assigns.notice
  end

  test "pending approvals outrank routine navigation" do
    pending =
      contextual_term()
      |> put_in([Access.key(:assigns), :projection, :turns, "turn-active"], %{
        status: :running,
        invocation_order: ["invocation-review"]
      })
      |> put_in(
        [Access.key(:assigns), :projection, :invocations, "invocation-review", :status],
        :waiting_tool_approval
      )
      |> put_in(
        [
          Access.key(:assigns),
          :projection,
          :invocations,
          "invocation-review",
          :pending_tool_review
        ],
        %{tool: "write"}
      )

    {candidate, _} =
      Enum.find(SlashPalette.rows(pending.assigns, 40), fn {candidate, _} ->
        candidate.value == "/tools"
      end)

    assert candidate.value == "/tools"
    assert PaletteMenu.label(candidate) == "Review pending approval"
  end

  test "idle natural-language search hides pending-only actions while explicit shortcuts survive" do
    for phrase <- ["/approve", "/question", "/stop"] do
      refute Enum.any?(SlashPalette.matches(phrase), &(&1.command in ~w(/tools /answer /cancel)))
    end

    assert hd(SlashPalette.matches("/cancel")).command == "/cancel"
  end

  test "Stop remains visible with both pending approvals and questions" do
    pending =
      contextual_term()
      |> put_in(
        [
          Access.key(:assigns),
          :projection,
          :invocations,
          "invocation-review",
          :pending_tool_review
        ],
        %{tool: "write"}
      )
      |> put_in(
        [Access.key(:assigns), :projection, :invocations, "invocation-child", :coordination],
        %{pending_question: %{}}
      )

    names =
      pending.assigns
      |> SlashPalette.rows(40)
      |> Enum.take(3)
      |> Enum.map(fn {candidate, _} -> candidate.value end)

    assert names == ~w(/cancel /tools /answer)
  end

  test "merge approvals lead to task-agent review rather than tool approval" do
    pending =
      contextual_term()
      |> put_in(
        [
          Access.key(:assigns),
          :projection,
          :invocations,
          "invocation-child",
          :pending_tool_review
        ],
        %{tool: "merge"}
      )

    names =
      pending.assigns
      |> SlashPalette.rows(40)
      |> Enum.take(3)
      |> Enum.map(fn {candidate, _} -> candidate.value end)

    assert "/hub" in names
    refute "/tools" in names
  end

  test "close/2 clears palette state and preserves a notice" do
    result = SlashPalette.close(term(), Notice.new(:warning, "Unknown command"))

    assert result.assigns.modal == nil
    assert result.assigns.slash == nil
    assert %Notice{severity: :warning} = result.assigns.notice
  end

  defp term(opts \\ []) do
    query = Keyword.get(opts, :query, "/")
    restore_draft = Keyword.get(opts, :restore_draft)
    draft = Keyword.get(opts, :draft, query)

    %Breeze.Term{
      assigns: %{
        selected_session_id: "room-1",
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
    session = %{
      verified_change: nil,
      participants: [],
      workspace: "/tmp",
      active_turn_id: "turn-active",
      queued_turn_ids: ["turn-follow-up"],
      message_order: ["message-child"]
    }

    projection = %{
      sessions: %{"room-1" => session},
      session_order: ["room-1"],
      messages: %{"message-child" => %{invocation_id: "invocation-child"}},
      turns: %{
        "turn-follow-up" => %{input_kind: :follow_up, status: :queued}
      },
      invocations: %{
        "invocation-review" => %{
          id: "invocation-review",
          turn_id: "turn-active",
          pending_tool_review: nil,
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
