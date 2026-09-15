defmodule ReyCode.TUI.ChallengeTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.{
    Challenge,
    Invocation,
    Message,
    Participant,
    Projection,
    Session,
    Turn
  }

  alias ReyCode.TUI.Challenge, as: ChallengeUI

  defmodule TestView do
    use Breeze.View
    alias ReyCode.TUI.Challenge, as: ChallengeUI

    @impl true
    def mount(opts, term) do
      term = assign(term, opts)
      {:ok, ChallengeUI.open(term)}
    end

    @impl true
    def render(assigns) do
      if assigns.modal == :challenge do
        ChallengeUI.modal(Map.put(assigns, :term, assigns))
      else
        ~H"""
        <box id="prompt" focusable>Prepared: {@drafts["s"]}</box>
        """
      end
    end

    @impl true
    def handle_event(:input, %{"key" => key}, term), do: ChallengeUI.handle_input(key, term)
    def handle_event(_event, _payload, term), do: {:noreply, term}
  end

  test "a selected answer queues the chosen question, never a tool", context do
    owner = self()

    submit = fn session, advisor, selection, _engine ->
      send(owner, {:challenge, session, advisor, selection})
      {:ok, "review"}
    end

    view = start(context, submit)
    assert Breeze.Test.render!(view) =~ "Answer · The fix works"
    Breeze.Test.input(view, "Enter")
    assert Breeze.Test.render!(view) =~ "What evidence supports"
    Breeze.Test.input(view, "ArrowDown")
    Breeze.Test.input(view, "Enter")

    assert_receive {:challenge, "s", "advisor",
                    %{"kind" => "answer", "id" => "answer", "question" => "contradict"}}
  end

  test "narrow and short terminals retain selection controls", context do
    for size <- [{50, 20}, {80, 24}, {140, 40}] do
      view = start(Map.put(context, :size, size), fn _, _, _, _ -> {:error, :test_only} end)
      screen = Breeze.Test.render!(view)
      assert screen =~ "Enter select"
      assert screen =~ "Answer · The fix works"
      Breeze.Test.input(view, "Enter")
      assert Breeze.Test.render!(view) =~ "What evidence supports"
      Breeze.Test.input(view, "Escape")
      assert Breeze.Test.render!(view) =~ "Existing draft"
    end
  end

  test "captured evidence is navigable and an experiment becomes a draft without submission",
       context do
    owner = self()
    submit = fn _, _, _, _ -> send(owner, :unexpected_submission) end
    view = start(context, submit, true)
    assert Breeze.Test.render!(view) =~ "Evidence / follow-up"
    Breeze.Test.input(view, "Enter")
    assert Breeze.Test.render!(view) =~ "Evidence T1"
    Breeze.Test.input(view, "Enter")
    assert Breeze.Test.render!(view) =~ "Frozen evidence preview"
    Breeze.Test.input(view, "ArrowDown")
    assert Breeze.Test.render!(view) =~ "Missing/clipped"
    Breeze.Test.input(view, "Escape")
    Breeze.Test.input(view, "ArrowDown")
    Breeze.Test.input(view, "ArrowDown")
    Breeze.Test.input(view, "Enter")
    screen = Breeze.Test.render!(view)
    assert screen =~ "Existing draft"
    assert screen =~ "Follow-up to evidence review review"
    assert screen =~ "Reproduce the original bug"
    refute_receive :unexpected_submission
  end

  defp start(context, submit, review? \\ false) do
    advisor = %Participant{
      id: "advisor",
      name: "Advisor",
      kind: :task,
      provider: :zai_coding,
      model: "glm"
    }

    session = %Session{
      id: "s",
      workspace: "/workspace",
      message_order: ["answer"],
      participants: [advisor]
    }

    message = %Message{
      id: "answer",
      session_id: "s",
      turn_id: "t",
      invocation_id: "i",
      role: :assistant,
      body: "The fix works"
    }

    invocation = %Invocation{id: "i", session_id: "s", turn_id: "t", message_id: "answer"}

    turn = %Turn{
      id: "t",
      session_id: "s",
      status: :terminal,
      outcome: :completed,
      invocation_order: ["i"]
    }

    projection = %Projection{
      sessions: %{"s" => session},
      turns: %{"t" => turn},
      messages: %{"answer" => message},
      invocations: %{"i" => invocation}
    }

    projection = if review?, do: with_review(projection, session), else: projection

    view =
      Breeze.Test.start!(TestView,
        size: Map.get(context, :size, {100, 30}),
        start_opts: [
          projection: projection,
          selected_session_id: "s",
          drafts: %{"s" => "Existing draft"},
          engine: :unused,
          challenge_submit: submit,
          memory_store: :missing_challenge_memory,
          slash: nil,
          notice: nil
        ]
      )

    on_exit(fn -> Breeze.Test.stop(view) end)
    view
  end

  defp with_review(projection, session) do
    {:ok, packet} =
      Challenge.capture(projection, session, [], %{
        "kind" => "answer",
        "id" => "answer",
        "question" => "support"
      })

    report =
      Jason.encode!(%{
        summary: "Limited evidence",
        limitations: "No independent test",
        findings: [
          %{
            observation: "An answer exists",
            hypothesis: "It may be correct",
            alternative: "Try a minimal fix",
            tradeoffs: "Less code",
            experiment: "Reproduce the original bug",
            uncertainty: "No test output",
            recurring: false,
            citations: ["T1.I1"]
          }
        ]
      })

    message = %{
      projection.messages["answer"]
      | id: "review-answer",
        turn_id: "review",
        body: report
    }

    turn = %{projection.turns["t"] | id: "review", strategy_review: packet}

    %{
      projection
      | sessions: %{"s" => %{session | message_order: [message.id, "answer"]}},
        messages: Map.put(projection.messages, message.id, message),
        turns: Map.put(projection.turns, turn.id, turn)
    }
  end
end
