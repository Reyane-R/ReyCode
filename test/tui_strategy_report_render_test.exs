defmodule ReyCode.TUI.StrategyReportRenderTest do
  use ExUnit.Case, async: false

  alias ReyCode.Orchestration.{Invocation, Message, Participant, StrategicReview, Turn}

  defmodule TimelineView do
    use Breeze.View
    import ReyCode.TUI.Components.MainScreen.Timeline

    alias ReyCode.TUI.State

    @impl true
    def mount(opts, term), do: ReyCode.TUI.mount(opts, term)

    @impl true
    def render(assigns) do
      assigns = State.prepare_render(assigns)

      ~H"""
      <box class="w-screen h-screen">
        <.timeline
          messages={@messages}
          timeline_id="timeline"
          message_width={@message_width}
          activity_frame="*"
        />
      </box>
      """
    end

    @impl true
    def handle_info({:projection_snapshot, projection}, term),
      do: {:noreply, assign(term, projection: projection)}
  end

  test "completed strategic reports render readably at narrow and wide widths without rewriting history" do
    for width <- [40, 120] do
      {view, projection, body} = start_report(width)
      screen = plain(Breeze.Test.render!(view))

      for text <- [
            "Strategic Review",
            "Review summary",
            "Limitations:",
            "Finding 1",
            "Observation:",
            "Hypothesis:",
            "Alternative:",
            "Tradeoffs:",
            "Experiment:",
            "Uncertainty:",
            "Recurring:",
            "Citations:",
            "T1"
          ] do
        assert screen =~ text
      end

      refute screen =~ "\"summary\""
      assert Breeze.Test.metadata(view).assigns.projection == projection
      assert projection.messages["report"].body == body
    end
  end

  test "streaming, failed, ordinary and user messages never acquire validated report presentation" do
    {view, projection, _body} = start_report(120)

    variants = [
      put_in(projection.messages["report"].status, :streaming),
      put_in(projection.messages["report"].status, :failed),
      put_in(projection.messages["report"].role, :user),
      put_in(projection.turns["review"].strategy_review, nil),
      put_in(projection.turns["review"].status, :running),
      put_in(projection.turns["review"].outcome, :failed),
      put_in(projection.invocations["invocation"].status, :running),
      put_in(projection.invocations["invocation"].status, :failed)
    ]

    for variant <- variants do
      Breeze.Test.info(view, {:projection_snapshot, variant})
      screen = plain(Breeze.Test.render!(view))
      assert screen =~ "\"summary\""
      refute screen =~ "Strategic Review"
      refute screen =~ "Finding 1"
      assert Breeze.Test.metadata(view).assigns.projection == variant
    end
  end

  test "invalid output and incomplete JSON pass through in unvalidated states" do
    {view, projection, _body} = start_report(40)

    for {status, body} <- [{:failed, "{\"summary\":\"invalid\"}"}, {:streaming, "{\"summary\":"}] do
      variant = put_in(projection.messages["report"].status, status)
      variant = put_in(variant.messages["report"].body, body)
      Breeze.Test.info(view, {:projection_snapshot, variant})
      screen = plain(Breeze.Test.render!(view))
      assert screen =~ body
      refute screen =~ "Strategic Review"
      assert Breeze.Test.metadata(view).assigns.projection == variant
    end
  end

  defp start_report(width) do
    view = Breeze.Test.start!(TimelineView, size: {width, 60})
    on_exit(fn -> Breeze.Test.stop(view) end)
    assigns = Breeze.Test.metadata(view).assigns
    session_id = assigns.selected_session_id
    session = assigns.projection.sessions[session_id]

    participant = %Participant{
      id: "advisor",
      name: "Advisor",
      kind: :task,
      provider: :simulator,
      model: "test"
    }

    turn = %Turn{
      id: "review",
      session_id: session_id,
      mode: :delegate,
      status: :terminal,
      outcome: :completed,
      invocation_order: ["invocation"]
    }

    invocation = %Invocation{
      id: "invocation",
      session_id: session_id,
      turn_id: turn.id,
      message_id: "report",
      participant: participant,
      status: :completed
    }

    body =
      Jason.encode!(%{
        "summary" => "Review summary",
        "limitations" => "Limited evidence",
        "findings" => [
          %{
            "observation" => "Observed risk",
            "hypothesis" => "Possible cause",
            "alternative" => "Other approach",
            "tradeoffs" => "More test effort",
            "experiment" => "Try one check",
            "uncertainty" => "Not proven",
            "recurring" => false,
            "citations" => ["T1"]
          }
        ]
      })

    message = %Message{
      id: "report",
      session_id: session_id,
      turn_id: turn.id,
      invocation_id: invocation.id,
      role: :assistant,
      author: participant,
      status: :completed,
      body: body,
      created_at: "2026-09-10T10:00:00Z"
    }

    projection = %{
      assigns.projection
      | sessions: %{session_id => %{session | message_order: [message.id]}},
        session_order: [session_id],
        turns: %{turn.id => turn},
        invocations: %{invocation.id => invocation},
        messages: %{message.id => message}
    }

    {:ok, packet} = StrategicReview.capture(projection, session, [], nil)
    assert {:ok, ^body} = StrategicReview.validate_output(packet, body)
    projection = put_in(projection.turns[turn.id].strategy_review, packet)
    Breeze.Test.info(view, {:projection_snapshot, projection})
    {view, projection, body}
  end

  defp plain(screen), do: String.replace(screen, ~r/\e\[[0-9;]*m/, "")
end
