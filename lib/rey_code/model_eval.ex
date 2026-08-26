defmodule ReyCode.ModelEval do
  @moduledoc """
  Runs and reports one explicit-subset model audition.

  Candidate names resolve against task Participants in existing rooms. Their
  provider/model profiles are copied into a fresh room; the Eval workflow opens
  one independent Invocation per copied task Participant and ignores the room's
  automatically-created Primary Participant.
  """

  alias ReyCode.Orchestration.Engine

  @poll_interval_ms 50
  @summary_max_graphemes 200

  @type options :: %{
          required(:agents) => [String.t()],
          required(:task) => String.t(),
          required(:workspace) => String.t(),
          required(:timeout_ms) => pos_integer(),
          optional(:json?) => boolean()
        }

  @type row :: %{
          required(:name) => String.t(),
          required(:outcome) => String.t(),
          required(:summary) => String.t(),
          required(:prompt_tokens) => non_neg_integer() | nil,
          required(:completion_tokens) => non_neg_integer() | nil,
          required(:wall_time_ms) => non_neg_integer()
        }

  @type report :: %{
          required(:turn_id) => String.t() | nil,
          required(:outcome) => String.t(),
          required(:agents) => [row()]
        }

  @doc "Runs one model audition through the supplied Engine server."
  @spec run(options(), GenServer.server()) :: report()
  def run(options, engine \\ Engine) do
    profiles = resolve_profiles(Engine.snapshot(engine), options.agents)
    title = "Model audition #{System.system_time(:millisecond)}"
    {:ok, room_id} = Engine.create_room(title, options.workspace, engine)

    {participant_count, setup_errors} =
      Enum.reduce(options.agents, {0, %{}}, fn name, acc ->
        add_candidate(engine, room_id, name, Map.get(profiles, name), acc)
      end)

    if participant_count == 0 do
      synthetic_report(options.agents, setup_errors)
    else
      run_turn(engine, room_id, options, setup_errors)
    end
  end

  @doc "Renders a model audition report for humans or machines."
  @spec render(report(), :human | :json) :: String.t()
  def render(report, :json), do: Jason.encode!(report)

  def render(report, :human) do
    header = "Agent\tOutcome\tPrompt\tCompletion\tWall ms\tResponse"

    rows =
      Enum.map(report.agents, fn row ->
        [
          row.name,
          row.outcome,
          token_label(row.prompt_tokens),
          token_label(row.completion_tokens),
          Integer.to_string(row.wall_time_ms),
          row.summary
        ]
        |> Enum.join("\t")
      end)

    (["ReyCode model audition", "Outcome: #{report.outcome}", header] ++ rows)
    |> Enum.join("\n")
  end

  @doc "Whether every requested candidate completed successfully."
  @spec success?(report()) :: boolean()
  def success?(report), do: Enum.all?(report.agents, &(&1.outcome == "completed"))

  defp resolve_profiles(snapshot, names) do
    candidates =
      snapshot.room_order
      |> Enum.reverse()
      |> Enum.flat_map(fn room_id ->
        room = Map.fetch!(snapshot.rooms, room_id)
        Enum.filter(room.participants, &(&1.kind == :task))
      end)

    Map.new(names, fn name -> {name, Enum.find(candidates, &(&1.name == name))} end)
  end

  defp add_candidate(engine, room_id, name, profile, {count, errors}) do
    responsibility = if profile, do: profile.perspective, else: "model audition candidate"

    case Engine.add_task_participant(room_id, name, responsibility, engine) do
      {:ok, participant_id} ->
        configure_candidate(engine, room_id, participant_id, name, profile, {count + 1, errors})

      {:error, reason} ->
        {count, Map.put(errors, name, Atom.to_string(reason))}
    end
  end

  defp configure_candidate(_engine, _room_id, _participant_id, name, nil, {count, errors}) do
    {count, Map.put(errors, name, "agent_not_found")}
  end

  defp configure_candidate(engine, room_id, participant_id, name, profile, {count, errors}) do
    case Engine.configure_participants(
           room_id,
           [participant_id],
           profile.provider,
           profile.model,
           engine
         ) do
      :ok -> {count, errors}
      {:error, reason} -> {count, Map.put(errors, name, inspect(reason))}
    end
  end

  defp run_turn(engine, room_id, options, setup_errors) do
    started_ms = System.monotonic_time(:millisecond)
    {:ok, turn_id} = Engine.post_message(room_id, options.task, :eval, engine)

    {snapshot, terminal_ms, timed_out?} =
      await_turn(engine, turn_id, started_ms, options.timeout_ms)

    snapshot = cancel_if_timed_out(engine, turn_id, snapshot, timed_out?)

    rows =
      build_rows(
        snapshot,
        turn_id,
        options.agents,
        setup_errors,
        terminal_ms,
        timed_out?,
        options.timeout_ms
      )

    %{
      turn_id: turn_id,
      outcome: if(Enum.all?(rows, &(&1.outcome == "completed")), do: "completed", else: "failed"),
      agents: rows
    }
  end

  defp await_turn(engine, turn_id, started_ms, timeout_ms) do
    await_turn(engine, turn_id, started_ms, started_ms + timeout_ms, %{})
  end

  defp await_turn(engine, turn_id, started_ms, deadline_ms, terminal_ms) do
    now_ms = System.monotonic_time(:millisecond)
    snapshot = Engine.snapshot(engine)
    turn = Map.fetch!(snapshot.turns, turn_id)
    terminal_ms = record_terminal_times(snapshot, turn, terminal_ms, now_ms - started_ms)

    cond do
      turn.status == :terminal ->
        {snapshot, terminal_ms, false}

      now_ms >= deadline_ms ->
        {snapshot, terminal_ms, true}

      true ->
        wait_ms(min(@poll_interval_ms, deadline_ms - now_ms))
        await_turn(engine, turn_id, started_ms, deadline_ms, terminal_ms)
    end
  end

  defp record_terminal_times(snapshot, turn, terminal_ms, elapsed_ms) do
    Enum.reduce(turn.invocation_order, terminal_ms, fn invocation_id, acc ->
      invocation = Map.fetch!(snapshot.invocations, invocation_id)

      if terminal_status?(invocation.status),
        do: Map.put_new(acc, invocation.participant.name, elapsed_ms),
        else: acc
    end)
  end

  defp cancel_if_timed_out(_engine, _turn_id, snapshot, false), do: snapshot

  defp cancel_if_timed_out(engine, turn_id, _snapshot, true) do
    :ok = Engine.cancel_turn(turn_id, "Model audition timed out", engine)
    Engine.snapshot(engine)
  end

  defp build_rows(snapshot, turn_id, names, setup_errors, terminal_ms, timed_out?, timeout_ms) do
    turn = Map.fetch!(snapshot.turns, turn_id)

    invocations =
      Map.new(turn.invocation_order, fn invocation_id ->
        invocation = Map.fetch!(snapshot.invocations, invocation_id)
        message = Map.fetch!(snapshot.messages, invocation.message_id)
        {invocation.participant.name, {invocation, message.body}}
      end)

    Enum.map(names, fn name ->
      build_row(
        name,
        Map.get(invocations, name),
        Map.get(setup_errors, name),
        Map.get(terminal_ms, name, if(timed_out?, do: timeout_ms, else: 0)),
        timed_out?
      )
    end)
  end

  defp build_row(name, nil, setup_error, wall_time_ms, _timed_out?) do
    row(name, "unconfigured", setup_error || "participant_not_created", nil, wall_time_ms)
  end

  defp build_row(name, {invocation, body}, setup_error, wall_time_ms, timed_out?) do
    tokens = usage_tokens(invocation.usage)

    {outcome, summary} =
      cond do
        setup_error -> {"unconfigured", setup_error}
        timed_out? and not terminal_status?(invocation.status) -> {"timed_out", "Timed out"}
        invocation.status == :completed -> {"completed", body}
        invocation.error -> {Atom.to_string(invocation.status), invocation.error.message}
        true -> {Atom.to_string(invocation.status), "No response"}
      end

    row(name, outcome, summary, tokens, wall_time_ms)
  end

  defp row(name, outcome, summary, tokens, wall_time_ms) do
    {prompt_tokens, completion_tokens} = tokens || {nil, nil}

    %{
      name: name,
      outcome: outcome,
      summary: bounded_summary(summary),
      prompt_tokens: prompt_tokens,
      completion_tokens: completion_tokens,
      wall_time_ms: wall_time_ms
    }
  end

  defp usage_tokens(nil), do: {nil, nil}

  defp usage_tokens(usage) do
    tokens = Map.get(usage, "tokens", %{})

    {
      number(usage, "prompt_tokens") || number(usage, "input_tokens") || number(tokens, "input"),
      number(usage, "completion_tokens") || number(usage, "output_tokens") ||
        number(tokens, "output")
    }
  end

  defp number(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) and value >= 0 -> value
      _other -> nil
    end
  end

  defp bounded_summary(nil), do: ""

  defp bounded_summary(value) do
    value
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, @summary_max_graphemes)
  end

  defp terminal_status?(status), do: status in [:completed, :failed, :cancelled]
  defp token_label(nil), do: "-"
  defp token_label(value), do: Integer.to_string(value)

  defp wait_ms(delay_ms) do
    receive do
    after
      delay_ms -> :ok
    end
  end

  defp synthetic_report(names, errors) do
    rows = Enum.map(names, &row(&1, "unconfigured", Map.get(errors, &1), nil, 0))
    %{turn_id: nil, outcome: "failed", agents: rows}
  end
end
