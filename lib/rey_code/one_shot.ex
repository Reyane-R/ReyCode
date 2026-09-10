defmodule ReyCode.OneShot do
  @moduledoc """
  Runs one bounded Primary Assistant Turn without a terminal UI.

  The run opens a fresh durable Session in the requested Workspace, copies the
  latest Primary Participant runtime when the Workspace changes, and waits on
  projection broadcasts. Operator approval or question states fail immediately
  because this surface has no interactive authorization channel.
  """

  alias ReyCode.Orchestration.{Engine, Projection, Validation}

  @projection_wait_ms 250
  @interaction_statuses [:waiting_tool_approval, :waiting_operator]

  @type options :: %{
          required(:prompt) => String.t(),
          required(:workspace) => String.t(),
          required(:timeout_ms) => pos_integer()
        }

  @type report :: %{
          required(:outcome) => atom(),
          required(:response) => String.t(),
          required(:session_id) => String.t(),
          required(:turn_id) => String.t(),
          optional(:error) => String.t(),
          optional(:usage) => map() | nil
        }

  @doc "Runs one prompt through the latest Primary Participant profile."
  @spec run(options(), GenServer.server()) :: {:ok, report()} | {:error, report()}
  def run(options, engine \\ Engine) do
    prompt = Map.fetch!(options, :prompt)
    workspace = options |> Map.fetch!(:workspace) |> Path.expand()
    timeout_ms = Map.fetch!(options, :timeout_ms)
    baseline = Engine.subscribe(engine)
    source = latest_session(baseline)

    with {:ok, prompt} <- Validation.message(prompt),
         true <- is_integer(timeout_ms) and timeout_ms > 0,
         {:ok, session_id} <- open_session(source, prompt, workspace, engine),
         {:ok, turn_id} <- Engine.post_message(session_id, prompt, :direct, engine) do
      await_turn(engine, session_id, turn_id, timeout_ms)
    else
      false -> error_report(:invalid_timeout, nil, nil)
      {:error, reason} -> error_report(reason, nil, nil)
    end
  end

  @doc "Creates a primary-only Session, copying only the newest source Workspace runtime."
  @spec open(map(), GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def open(options, engine \\ Engine) do
    projection = Engine.snapshot(engine)
    source_workspace = Map.fetch!(options, :source_workspace)
    source_id = Projection.newest_session_id_for_workspace(projection, source_workspace)

    with {:ok, session_id} <-
           Engine.create_blank_session(session_title(options.prompt), options.workspace, engine),
         :ok <- copy_source_runtime(projection, source_id, session_id, engine) do
      {:ok, session_id}
    end
  end

  @doc "Posts one bounded turn in an existing Session; interaction or timeout cancels the turn."
  @spec run_turn(String.t(), String.t(), pos_integer(), GenServer.server()) ::
          {:ok, report()} | {:error, report()}
  def run_turn(session_id, prompt, timeout_ms, engine \\ Engine) do
    run_turn(session_id, prompt, timeout_ms, engine, :headless)
  end

  @doc "Runs a bounded Turn with an explicit interaction policy; interactive waits retain the deadline."
  @spec run_turn(
          String.t(),
          String.t(),
          non_neg_integer(),
          GenServer.server(),
          :headless | :interactive
        ) ::
          {:ok, report()} | {:error, report()}
  def run_turn(session_id, prompt, timeout_ms, engine, interaction) do
    _projection = Engine.subscribe(engine)

    with {:ok, prompt} <- Validation.message(prompt),
         true <- is_integer(timeout_ms) and timeout_ms > 0,
         {:ok, turn_id} <- Engine.post_message(session_id, prompt, :direct, engine) do
      await_turn(engine, session_id, turn_id, timeout_ms, interaction)
    else
      false -> error_report(:invalid_timeout, session_id, nil)
      {:error, reason} -> error_report(reason, session_id, nil)
    end
  end

  @doc """
  Runs one bounded report-only verified-change stage Turn addressed to a task
  participant.

  Mirrors run_turn/5 plus the task addressing required by the coordinator-owned
  stage seam; the verified-change boundary removes every tool from the
  resulting Invocation regardless of this module.
  """
  @spec run_stage(
          String.t(),
          String.t(),
          String.t(),
          pos_integer(),
          GenServer.server(),
          :headless | :interactive
        ) ::
          {:ok, report()} | {:error, report()}
  def run_stage(session_id, participant_id, prompt, timeout_ms, engine, interaction) do
    _projection = Engine.subscribe(engine)

    with {:ok, prompt} <- Validation.message(prompt),
         true <- is_integer(timeout_ms) and timeout_ms > 0,
         {:ok, turn_id} <-
           Engine.post_verified_stage_turn(session_id, participant_id, prompt, engine) do
      await_turn(engine, session_id, turn_id, timeout_ms, interaction)
    else
      false -> error_report(:invalid_timeout, session_id, nil)
      {:error, reason} -> error_report(reason, session_id, nil)
    end
  end

  defp copy_source_runtime(_projection, nil, _session_id, _engine), do: :ok

  defp copy_source_runtime(projection, source_id, session_id, engine),
    do: copy_primary_runtime(Map.fetch!(projection.sessions, source_id), session_id, engine)

  defp latest_session(%{session_order: order, sessions: sessions}) do
    order |> List.last() |> then(&Map.fetch!(sessions, &1))
  end

  defp open_session(source, prompt, workspace, engine) do
    title = session_title(prompt)

    if source.workspace == workspace do
      Engine.create_session(source.id, title, engine)
    else
      with {:ok, session_id} <- Engine.create_blank_session(title, workspace, engine),
           :ok <- copy_primary_runtime(source, session_id, engine) do
        {:ok, session_id}
      end
    end
  end

  defp copy_primary_runtime(source, session_id, engine) do
    source_primary = Enum.find(source.participants, &(&1.kind == :primary))
    target = Engine.snapshot(engine).sessions[session_id]
    target_primary = Enum.find(target.participants, &(&1.kind == :primary))

    with :ok <- maybe_configure_runtime(session_id, source_primary, target_primary, engine) do
      Engine.configure_participant_tier(
        session_id,
        target_primary.id,
        source_primary.model_tier,
        engine
      )
    end
  end

  defp maybe_configure_runtime(_session_id, %{provider: nil}, _target, _engine), do: :ok

  defp maybe_configure_runtime(
         _session_id,
         %{provider: provider, model: model},
         %{provider: provider, model: model},
         _engine
       ),
       do: :ok

  defp maybe_configure_runtime(session_id, source, target, engine) do
    Engine.configure_participants(session_id, target.id, source.provider, source.model, engine)
  end

  defp await_turn(engine, session_id, turn_id, timeout_ms, interaction \\ :headless) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms

    await_projection(
      engine,
      Engine.snapshot(engine),
      session_id,
      turn_id,
      deadline_ms,
      interaction
    )
  end

  defp await_projection(engine, projection, session_id, turn_id, deadline_ms, interaction) do
    turn = projection.turns[turn_id]

    cond do
      turn.status == :terminal ->
        terminal_report(projection, session_id, turn)

      interaction == :headless and interaction_required?(projection, turn) ->
        _result =
          Engine.cancel_turn(turn_id, "Headless run requires operator interaction", engine)

        error_report(:operator_interaction_required, session_id, turn_id)

      System.monotonic_time(:millisecond) >= deadline_ms ->
        _result = Engine.cancel_turn(turn_id, "One-shot run timed out", engine)
        error_report(:timeout, session_id, turn_id)

      true ->
        remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 1)

        receive do
          {:projection_snapshot, next} when next.sequence > projection.sequence ->
            await_projection(engine, next, session_id, turn_id, deadline_ms, interaction)
        after
          min(@projection_wait_ms, remaining_ms) ->
            await_projection(
              engine,
              Engine.snapshot(engine),
              session_id,
              turn_id,
              deadline_ms,
              interaction
            )
        end
    end
  end

  defp interaction_required?(projection, turn) do
    Enum.any?(turn.invocation_order, fn invocation_id ->
      projection.invocations[invocation_id].status in @interaction_statuses
    end)
  end

  defp terminal_report(projection, session_id, turn) do
    invocation = root_invocation(projection, turn)
    message = invocation && projection.messages[invocation.message_id]

    report = %{
      outcome: turn.outcome,
      response: if(message, do: message.body, else: ""),
      session_id: session_id,
      turn_id: turn.id,
      usage: invocation && invocation.usage
    }

    if turn.outcome == :completed do
      {:ok, report}
    else
      {:error,
       Map.put(report, :error, failure_text(invocation && invocation.error, turn.outcome))}
    end
  end

  defp root_invocation(projection, turn) do
    turn.invocation_order
    |> Enum.map(&projection.invocations[&1])
    |> Enum.find(&is_nil(&1.delegated_from_invocation_id))
  end

  defp failure_text(nil, outcome), do: to_string(outcome)
  defp failure_text(error, _outcome), do: reason_text(error)

  defp error_report(reason, session_id, turn_id) do
    {:error,
     %{
       outcome: :failed,
       response: "",
       session_id: session_id,
       turn_id: turn_id,
       error: reason_text(reason)
     }}
  end

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp reason_text({:participants_unconfigured, _participant_ids}),
    do: "Primary Assistant is not configured; open reycode and select a provider and model"

  defp reason_text(reason), do: inspect(reason, limit: 20, printable_limit: 2_000)

  defp session_title(prompt) do
    prompt
    |> String.split(~r/\s+/, trim: true)
    |> Enum.join(" ")
    |> String.slice(0, 120)
  end
end
