defmodule ReyCode.TUI.AdvisorStrategyTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.{Participant, Projection, Session}
  alias ReyCode.TUI.{Advisor, Notice, SlashPalette}

  setup do
    advisor = %Participant{
      id: "advisor",
      name: "Advisor",
      kind: :task,
      provider: :simulator,
      model: "test"
    }

    session = %Session{id: "room", participants: [advisor]}

    term = %Breeze.Term{
      assigns: %{
        projection: %Projection{sessions: %{"room" => session}},
        selected_session_id: "room",
        engine: self(),
        advisor_strategy: fn room, participant, focus, engine ->
          send(self(), {:strategy, room, participant, focus, engine})
          {:ok, "strategy-turn"}
        end,
        advisor_delegate: fn room, participant, brief, engine ->
          send(self(), {:ordinary, room, participant, brief, engine})
          {:ok, "ordinary-turn"}
        end,
        drafts: %{"room" => ""},
        modal: :slash,
        slash: nil,
        notice: nil
      }
    }

    %{term: term}
  end

  test "typed strategy commands use the distinct seam with optional focus", %{term: term} do
    for {command, focus} <- [
          {"/advise strategy", nil},
          {"/advise strategy reduce repeated test failures", "reduce repeated test failures"},
          {"/advise strategy   \"release readiness\"", "release readiness"}
        ] do
      assert {:noreply, next} = SlashPalette.run_typed(term, command)
      assert %Notice{severity: :success} = next.assigns.notice
      assert next.assigns.modal == nil
      assert next.assigns.slash == nil
      engine = self()
      assert_receive {:strategy, "room", "advisor", ^focus, ^engine}
      refute_received {:ordinary, _, _, _, _}
    end
  end

  test "palette submission routes strategy and preserves the existing draft", %{term: term} do
    term = put_in(term.assigns.drafts["room"], "unfinished draft")
    term = term |> SlashPalette.open() |> SlashPalette.set_query("/advise strategy test coverage")

    assert {:noreply, next} = SlashPalette.submit(term)
    assert next.assigns.drafts["room"] == "unfinished draft"
    assert_receive {:strategy, "room", "advisor", "test coverage", _}
  end

  test "ordinary default and custom briefs retain the delegation seam", %{term: term} do
    assert {:noreply, _next} = Advisor.run(term)
    assert_receive {:ordinary, "room", "advisor", default_brief, _}
    assert default_brief =~ "Review the current Session's latest work."

    for brief <- ["Review the diff", "strategies for tests", "strategy-review", "Review strategy"] do
      assert {:noreply, _next} = SlashPalette.run_typed(term, "/advise " <> brief)
      assert_receive {:ordinary, "room", "advisor", ^brief, _}
    end

    refute_received {:strategy, _, _, _, _}
  end

  test "strategy admission errors are visible without ordinary fallback", %{term: term} do
    term =
      put_in(term.assigns.advisor_strategy, fn _, _, _, _ ->
        {:error, :strategy_memory_unavailable}
      end)

    assert {:noreply, next} = SlashPalette.run_typed(term, "/advise strategy")
    assert %Notice{severity: :error, message: message} = next.assigns.notice
    assert message =~ "strategy_memory_unavailable"
    refute_received {:ordinary, _, _, _, _}
  end

  test "strategy requires an existing configured Advisor", %{term: term} do
    for participants <- [
          [],
          [%Participant{id: "advisor", name: "Advisor", kind: :primary}],
          [%Participant{id: "advisor", name: "Advisor", kind: :task}],
          [%Participant{id: "advisor", name: "Advisor", kind: :task, provider: :simulator}]
        ] do
      term = put_in(term.assigns.projection.sessions["room"].participants, participants)
      assert {:noreply, next} = SlashPalette.run_typed(term, "/advise strategy")
      assert %Notice{severity: :warning} = next.assigns.notice
      refute_received {:strategy, _, _, _, _}
      refute_received {:ordinary, _, _, _, _}
    end
  end
end
