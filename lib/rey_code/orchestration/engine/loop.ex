defmodule ReyCode.Orchestration.Engine.Loop do
  @moduledoc "Handles the durable AgentLoop process protocol for the Engine."

  alias ReyCode.Failure

  alias ReyCode.Orchestration.{
    Delegation,
    DelegationWorktree,
    EventEntries,
    InvocationRequest,
    OperatorQuestions,
    PeerMessaging,
    ToolRun,
    ToolRuns,
    Turn,
    Validation,
    WorkPlan
  }

  alias ReyCode.Orchestration.Engine.{
    Admission,
    Identity,
    Lifecycle,
    Persistence,
    ProviderFrames
  }

  alias ReyCode.Provider.Response
  alias ReyCode.Security.Workspace
  alias ReyCode.ToolRegistry

  @delegation_tool Delegation.tool_name()
  @batch_delegation_tool Delegation.batch_tool_name()
  @peer_message_tool PeerMessaging.tool_name()
  @operator_question_tool OperatorQuestions.tool_name()
  @plan_tool "update_plan"

  @type response :: {:reply, term(), map()}

  @doc "Records one validated single/multi/Other answer and resumes the waiting Invocation."
  @spec answer_question(map(), String.t(), String.t(), term()) :: response()
  def answer_question(state, invocation_id, question_id, selection) do
    invocation = state.projection.invocations[invocation_id]
    question = invocation && invocation.coordination.pending_question

    with %{} <- invocation,
         %{} <- question,
         true <- invocation.status == :waiting_operator,
         true <- question.id == question_id,
         {:ok, answer} <- OperatorQuestions.resolve(question, selection),
         %ToolRun{status: :running} = run <- Map.get(invocation.tool_runs, question.tool_run_id) do
      output = Jason.encode!(%{"selected" => answer.labels, "other" => answer.other})

      result = %{
        "output" => output,
        "truncated" => false,
        "metadata" => %{"option_ids" => answer.option_ids}
      }

      entries = [
        EventEntries.operator_question_answered(invocation, question, answer),
        EventEntries.tool_run_completed(invocation, run, result)
      ]

      next =
        state
        |> Persistence.append_and_apply!(entries)
        |> Admission.enqueue(invocation.id)
        |> Lifecycle.pump_admission()

      {:reply, :ok, next}
    else
      nil -> {:reply, {:error, :question_not_found}, state}
      false -> {:reply, {:error, :stale_question}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
      _other -> {:reply, {:error, :invalid_question_selection}, state}
    end
  end

  @doc "Builds the current durable request for one invocation."
  @spec request(map(), term()) :: response()
  def request(state, invocation_id) do
    invocation = state.projection.invocations[invocation_id]

    reply =
      cond do
        invocation == nil ->
          {:terminal, :missing}

        invocation.status in [:completed, :failed, :cancelled] ->
          {:terminal, invocation.status}

        invocation.status == :awaiting_delegation ->
          {:waiting, :delegation}

        invocation.status == :waiting_tool_approval ->
          {:waiting, :tool_approval}

        invocation.status == :waiting_operator ->
          {:waiting, :operator_question}

        true ->
          {:ok,
           InvocationRequest.build(invocation, state.projection, %{
             agent_delay_ms: state.agent_delay_ms,
             simulator_opts: state.simulator_opts
           })}
      end

    {:reply, reply, state}
  end

  @doc "Records that one queued invocation has started."
  @spec started(map(), term()) :: response()
  def started(state, invocation_id) do
    invocation = state.projection.invocations[invocation_id]

    if invocation && invocation.status == :queued do
      {:reply, :ok,
       Persistence.append_and_apply!(state, [EventEntries.invocation_started(invocation)])}
    else
      {:reply, :ok, state}
    end
  end

  @doc "Validates and records a batch of provider frames."
  @spec record_frames(map(), term(), term()) :: response()
  def record_frames(state, invocation_id, frames) do
    invocation = state.projection.invocations[invocation_id]

    cond do
      invocation == nil ->
        {:reply, {:error, :invocation_not_found}, state}

      not is_list(frames) ->
        {:reply, {:error, :invalid_frames}, state}

      true ->
        case ProviderFrames.collect(invocation, frames) do
          {:ok, []} ->
            {:reply, :ok, state}

          {:ok, pending_frames} ->
            append_pending_frames(state, invocation, pending_frames)

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @doc "Validates and records one provider frame."
  @spec record_frame(map(), term(), term()) :: response()
  def record_frame(state, invocation_id, frame), do: record_frames(state, invocation_id, [frame])

  @doc "Validates and records one normalized provider round."
  @spec record_round(map(), term(), term(), term()) :: response()
  def record_round(state, invocation_id, round_index, response_wire) do
    invocation = state.projection.invocations[invocation_id]

    cond do
      invocation == nil ->
        {:reply, {:error, :invocation_not_found}, state}

      invocation.status in [:completed, :failed, :cancelled] ->
        {:reply, {:error, :invocation_terminal}, state}

      true ->
        persist_round(state, invocation, round_index, response_wire)
    end
  end

  def take_tool_run(state, invocation_id) do
    invocation = state.projection.invocations[invocation_id]

    cond do
      invocation == nil ->
        {:reply, {:error, :invocation_not_found}, state}

      invocation.status in [:completed, :failed, :cancelled] ->
        {:reply, {:error, :invocation_terminal}, state}

      invocation.status == :awaiting_delegation ->
        {:reply, {:waiting, :delegation}, state}

      true ->
        next_tool_run(state, invocation)
    end
  end

  @doc "Records one owner decision for a durable tool run."
  @spec resolve_tool_run(map(), term(), term(), term()) :: response()
  def resolve_tool_run(state, invocation_id, run_id, raw_decision) do
    invocation = state.projection.invocations[invocation_id]

    with {:ok, review, decision} <-
           Validation.tool_run_resolution(invocation, run_id, raw_decision),
         {:ok, run} <- resumable_run(invocation, review) do
      {:reply, :ok, resolve_tool_decision(state, invocation, run, decision)}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @doc "Transitions one ready tool run to running."
  @spec tool_run_started(map(), term(), term()) :: response()
  def tool_run_started(state, invocation_id, run_id) do
    with {:ok, invocation} <- fetch_invocation(state, invocation_id),
         {:ok, run} <- ToolRuns.fetch_for_transition(invocation, run_id, :ready) do
      entry = EventEntries.tool_run_started(invocation, run)
      {:reply, :ok, Persistence.append_and_apply!(state, [entry])}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @doc "Records one successful tool-run result."
  @spec tool_run_completed(map(), term(), term(), term()) :: response()
  def tool_run_completed(state, invocation_id, run_id, result) do
    with {:ok, invocation} <- fetch_invocation(state, invocation_id),
         {:ok, run} <- ToolRuns.fetch_for_transition(invocation, run_id, :running),
         :ok <- ensure_wire_map(result) do
      entry = EventEntries.tool_run_completed(invocation, run, result)
      {:reply, :ok, Persistence.append_and_apply!(state, [entry])}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @doc "Records one failed tool-run result."
  @spec tool_run_failed(map(), term(), term(), term()) :: response()
  def tool_run_failed(state, invocation_id, run_id, error) do
    with {:ok, invocation} <- fetch_invocation(state, invocation_id),
         {:ok, run} <- ToolRuns.fetch_for_transition(invocation, run_id, :running),
         :ok <- ensure_wire_map(error) do
      entry = EventEntries.tool_run_failed(invocation, run, error)
      {:reply, :ok, Persistence.append_and_apply!(state, [entry])}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @doc "Finalizes one invocation as completed."
  @spec complete(map(), term(), term()) :: response()
  def complete(state, invocation_id, metadata) do
    {:reply, :ok, Lifecycle.finalize_invocation(state, invocation_id, {:completed, metadata})}
  end

  @doc "Finalizes one invocation as failed."
  @spec fail(map(), term(), term()) :: response()
  def fail(state, invocation_id, error) do
    {:reply, :ok, Lifecycle.finalize_invocation(state, invocation_id, {:failed, error})}
  end

  defp append_pending_frames(state, invocation, pending_frames) do
    if invocation.status in [:completed, :failed, :cancelled] do
      {:reply, {:error, :invocation_terminal}, state}
    else
      entries = Enum.map(pending_frames, &EventEntries.provider_frame(invocation, &1))
      {:reply, :ok, Persistence.append_and_apply!(state, entries)}
    end
  end

  defp persist_round(state, invocation, round_index, response_wire) do
    with {:ok, response} <- Response.from_wire(response_wire),
         :ok <- round_contiguous?(invocation, round_index) do
      entry = EventEntries.provider_round(invocation, round_index, response_wire)
      state = Persistence.append_and_apply!(state, [entry])
      next_invocation = state.projection.invocations[invocation.id]

      if response.tool_calls == [] and next_invocation.pending_steering == [] do
        {:reply, {:ok, :final}, state}
      else
        {:reply, {:ok, :continue}, state}
      end
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp round_contiguous?(invocation, round_index) do
    if round_index == length(invocation.rounds),
      do: :ok,
      else: {:error, :invalid_round_index}
  end

  defp next_tool_run(state, invocation) do
    case ToolRuns.next_action(invocation) do
      :none ->
        {:reply, {:ok, :none}, state}

      {:new, call} ->
        claim_new_run(state, invocation, call)

      {:existing, action, run} ->
        {:reply, {:ok, {action, run}}, state}
    end
  end

  defp claim_new_run(state, invocation, %{tool: tool} = call)
       when tool in [@delegation_tool, @batch_delegation_tool] do
    claim_delegation(state, invocation, call)
  end

  defp claim_new_run(state, invocation, %{tool: @peer_message_tool} = call) do
    claim_peer_message(state, invocation, call)
  end

  defp claim_new_run(state, invocation, %{tool: @operator_question_tool} = call) do
    claim_operator_question(state, invocation, call)
  end

  defp claim_new_run(state, invocation, %{tool: @plan_tool} = call) do
    claim_plan_update(state, invocation, call)
  end

  defp claim_new_run(state, invocation, call) do
    {workspace, workspace_roots} = invocation_workspace(state, invocation)

    run = %ToolRun{
      id: Identity.new_id("toolrun"),
      tool_call_id: call.id,
      round_index: length(invocation.rounds) - 1,
      tool: call.tool,
      arguments: call.arguments,
      workspace: Path.expand(workspace),
      workspace_roots: workspace_roots
    }

    authorization = tool_authorization(call)
    run = %{run | authorization: authorization}
    entries = tool_run_request_entries(invocation, run, authorization)
    next = Persistence.append_and_apply!(state, entries)
    run = next.projection.invocations[invocation.id].tool_runs[run.id]
    next = maybe_release_for_approval(next, invocation, authorization)
    {:reply, {:ok, {authorization_action(authorization), run}}, next}
  end

  defp claim_operator_question(state, invocation, call) do
    run = orchestration_run(state, invocation, call)
    question_id = Identity.new_id("question")

    case OperatorQuestions.build(call.arguments, question_id, run.id, "") do
      {:ok, question} ->
        entries = [
          EventEntries.tool_run_requested(invocation, run),
          EventEntries.tool_run_started(invocation, %{run | status: :ready}),
          EventEntries.operator_question_asked(invocation, question)
        ]

        next = Persistence.append_and_apply!(state, entries)
        pending = next.projection.invocations[invocation.id].tool_runs[run.id]
        {:reply, {:ok, {:question, pending}}, next}

      {:error, reason} ->
        reject_delegation(state, invocation, run, reason)
    end
  end

  defp claim_plan_update(state, invocation, call) do
    run = orchestration_run(state, invocation, call)

    case WorkPlan.transition(invocation.coordination.work_plan, call.arguments, timestamp()) do
      {:ok, plan} ->
        result = %{
          "output" => Jason.encode!(WorkPlan.to_wire(plan)),
          "truncated" => false,
          "metadata" => %{}
        }

        entries = [
          EventEntries.tool_run_requested(invocation, run),
          EventEntries.tool_run_started(invocation, %{run | status: :ready}),
          EventEntries.invocation_plan_updated(invocation, plan),
          EventEntries.tool_run_completed(invocation, run, result)
        ]

        next = Persistence.append_and_apply!(state, entries)
        completed = next.projection.invocations[invocation.id].tool_runs[run.id]
        {:reply, {:ok, {:continue, completed}}, next}

      {:error, reason} ->
        reject_delegation(state, invocation, run, reason)
    end
  end

  defp orchestration_run(state, invocation, call) do
    {workspace, workspace_roots} = invocation_workspace(state, invocation)

    %ToolRun{
      id: Identity.new_id("toolrun"),
      tool_call_id: call.id,
      round_index: length(invocation.rounds) - 1,
      tool: call.tool,
      arguments: call.arguments,
      workspace: Path.expand(workspace),
      workspace_roots: workspace_roots,
      authorization: :allow
    }
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp authorization_action(:allow), do: :execute
  defp authorization_action(:ask), do: :await
  defp authorization_action(:denied), do: :denied

  defp tool_authorization(call) do
    cond do
      ToolRegistry.requires_approval?(call) -> :ask
      call.tool in ToolRegistry.tool_names() -> :allow
      true -> :denied
    end
  end

  defp tool_run_request_entries(invocation, run, :denied) do
    [
      EventEntries.tool_run_requested(invocation, run),
      EventEntries.tool_run_failed(invocation, run, %{
        "ok" => false,
        "error" => "unknown_tool"
      })
    ]
  end

  defp tool_run_request_entries(invocation, run, _authorization),
    do: [EventEntries.tool_run_requested(invocation, run)]

  defp maybe_release_for_approval(state, invocation, :ask),
    do: Lifecycle.advance_turn(state, invocation.turn_id)

  defp maybe_release_for_approval(state, _invocation, _authorization), do: state

  # spawn_task is claimed here and never reaches ToolRegistry.execute: the run
  # stays :running while the child invocation executes, and the parent worker
  # stops with zero further provider rounds until the child terminates.
  defp claim_delegation(state, invocation, call) do
    {workspace, workspace_roots} = invocation_workspace(state, invocation)

    run = %ToolRun{
      id: Identity.new_id("toolrun"),
      tool_call_id: call.id,
      round_index: length(invocation.rounds) - 1,
      tool: call.tool,
      arguments: call.arguments,
      workspace: Path.expand(workspace),
      workspace_roots: workspace_roots,
      authorization: :allow
    }

    result =
      case call.tool do
        @delegation_tool ->
          Delegation.authorize(
            invocation,
            call.arguments,
            state.projection,
            delegation_bounds(state)
          )

        @batch_delegation_tool ->
          Delegation.authorize_batch(
            invocation,
            call.arguments,
            state.projection,
            delegation_bounds(state)
          )
      end

    case result do
      {:ok, %Delegation.Plan{detach?: true} = plan} ->
        open_detached_delegation(state, invocation, run, plan)

      {:ok, %Delegation.Plan{} = plan} ->
        open_child_delegation(state, invocation, run, plan)

      {:ok, %Delegation.BatchPlan{} = plan} ->
        open_delegation_wave(state, invocation, run, plan)

      {:error, reason} ->
        reject_delegation(state, invocation, run, reason)
    end
  end

  defp claim_peer_message(state, invocation, call) do
    {workspace, workspace_roots} = invocation_workspace(state, invocation)

    run = %ToolRun{
      id: Identity.new_id("toolrun"),
      tool_call_id: call.id,
      round_index: length(invocation.rounds) - 1,
      tool: call.tool,
      arguments: call.arguments,
      workspace: Path.expand(workspace),
      workspace_roots: workspace_roots,
      authorization: :allow
    }

    case PeerMessaging.authorize(invocation, call.arguments, state.projection) do
      {:ok, target, body} ->
        peer_message_id = Identity.new_id("peer")

        result = %{
          "output" => "delivered to #{target.participant.name}",
          "truncated" => false,
          "metadata" => %{
            "peer_message_id" => peer_message_id,
            "target_invocation_id" => target.id
          }
        }

        entries = [
          EventEntries.tool_run_requested(invocation, run),
          EventEntries.tool_run_started(invocation, %{run | status: :ready}),
          EventEntries.peer_message_sent(invocation, target, peer_message_id, body),
          EventEntries.tool_run_completed(invocation, run, result)
        ]

        next = Persistence.append_and_apply!(state, entries)
        completed = next.projection.invocations[invocation.id].tool_runs[run.id]
        {:reply, {:ok, {:continue, completed}}, next}

      {:error, reason} ->
        reject_delegation(state, invocation, run, reason)
    end
  end

  defp open_delegation_wave(state, invocation, run, plan) do
    session = state.projection.sessions[invocation.session_id]
    turn = state.projection.turns[invocation.turn_id]
    depth = invocation.delegation_depth + 1

    worker_refs =
      Enum.map(plan.workers, fn worker ->
        {worker, Identity.new_id("inv"), Identity.new_id("msg"), []}
      end)

    worker_ids = Enum.map(worker_refs, fn {_plan, child_id, _message_id, _deps} -> child_id end)

    child_refs =
      case plan.integrator do
        nil ->
          worker_refs

        integrator ->
          worker_refs ++
            [
              {
                integrator,
                Identity.new_id("inv"),
                Identity.new_id("msg"),
                worker_ids
              }
            ]
      end

    case prepare_wave_children(invocation, session, child_refs) do
      {:ok, prepared} ->
        specs = Enum.map(prepared, &wave_child_spec(&1, invocation, run, depth))
        ids = Enum.map(prepared, &{&1.child_id, &1.message_id})

        delegation_entries =
          Enum.map(prepared, fn child ->
            EventEntries.delegation_opened(
              invocation,
              run,
              child.child_id,
              child.message_id,
              depth
            )
          end)

        entries =
          [
            EventEntries.tool_run_requested(invocation, run),
            EventEntries.tool_run_started(invocation, %{run | status: :ready})
          ] ++
            EventEntries.open_invocations(session, turn, specs, ids) ++ delegation_entries

        next =
          prepared
          |> Enum.reduce(Persistence.append_and_apply!(state, entries), fn child, acc ->
            Admission.enqueue(acc, child.child_id)
          end)
          |> Lifecycle.pump_admission()

        pending = next.projection.invocations[invocation.id].tool_runs[run.id]
        {:reply, {:ok, {:delegate, pending}}, next}

      {:error, reason} ->
        reject_delegation(state, invocation, run, reason)
    end
  end

  defp prepare_wave_children(invocation, session, child_refs) do
    Enum.reduce_while(child_refs, {:ok, []}, fn {plan, child_id, message_id, dependencies},
                                                {:ok, prepared} ->
      case delegation_workspace(invocation, session, plan, child_id) do
        {:ok, workspace} ->
          child = %{
            plan: plan,
            child_id: child_id,
            message_id: message_id,
            dependencies: dependencies,
            workspace: workspace
          }

          {:cont, {:ok, prepared ++ [child]}}

        {:error, reason} ->
          cleanup_prepared_children(prepared)
          {:halt, {:error, reason}}
      end
    end)
  end

  defp cleanup_prepared_children(children) do
    Enum.each(children, fn child ->
      case child.workspace.isolation do
        nil ->
          :ok

        isolation ->
          _ =
            DelegationWorktree.cleanup(%{
              workspace: isolation["workspace"],
              source_workspace: isolation["source_workspace"]
            })
      end
    end)
  end

  defp wave_child_spec(child, invocation, run, depth) do
    %{
      participant_id: child.plan.participant.id,
      phase_index: if(child.dependencies == [], do: 0, else: 1),
      label: if(child.dependencies == [], do: "delegated task", else: "integration task"),
      system_prompt: Delegation.child_system_prompt(child.plan),
      dependencies: child.dependencies,
      output_schema: child.plan.output_schema,
      workspace: child.workspace.path,
      workspace_roots: child.workspace.roots,
      isolation: child.workspace.isolation,
      delegated_from_invocation_id: invocation.id,
      delegated_from_tool_run_id: run.id,
      delegation_depth: depth
    }
  end

  defp open_detached_delegation(state, invocation, run, plan) do
    session = state.projection.sessions[invocation.session_id]
    turn_id = Identity.new_id("turn")
    source_message_id = Identity.new_id("msg")
    child_id = Identity.new_id("inv")
    child_message_id = Identity.new_id("msg")
    depth = invocation.delegation_depth + 1

    turn = %Turn{
      id: turn_id,
      session_id: session.id,
      user_message_id: source_message_id,
      input_kind: :detached,
      mode: :delegate,
      participant_id: plan.participant.id,
      source_invocation_id: invocation.id,
      task: plan.brief,
      detached?: true,
      status: :queued,
      context_through_sequence: state.projection.sequence
    }

    case delegation_workspace(invocation, session, plan, child_id) do
      {:ok, workspace} ->
        child_spec = %{
          participant_id: plan.participant.id,
          phase_index: 0,
          label: "detached task",
          system_prompt: Delegation.child_system_prompt(plan),
          output_schema: plan.output_schema,
          workspace: workspace.path,
          workspace_roots: workspace.roots,
          isolation: workspace.isolation,
          delegated_from_invocation_id: invocation.id,
          delegated_from_tool_run_id: run.id,
          delegation_depth: depth
        }

        receipt = %{
          "output" => "detached task started",
          "truncated" => false,
          "metadata" => %{
            "turn_id" => turn_id,
            "invocation_id" => child_id
          }
        }

        entries =
          [
            EventEntries.tool_run_requested(invocation, run),
            EventEntries.tool_run_started(invocation, %{run | status: :ready})
          ] ++
            EventEntries.detached_turn(
              invocation,
              plan.participant,
              plan.brief,
              turn_id,
              source_message_id,
              state.projection.sequence
            ) ++
            [EventEntries.turn_started(turn)] ++
            EventEntries.open_invocations(
              session,
              %{turn | status: :running},
              [child_spec],
              [{child_id, child_message_id}]
            ) ++
            [
              EventEntries.delegation_opened(
                invocation,
                run,
                child_id,
                child_message_id,
                depth,
                false
              ),
              EventEntries.tool_run_completed(invocation, run, receipt)
            ]

        next =
          state
          |> Persistence.append_and_apply!(entries)
          |> Admission.enqueue(child_id)
          |> Lifecycle.pump_admission()

        completed = next.projection.invocations[invocation.id].tool_runs[run.id]
        {:reply, {:ok, {:continue, completed}}, next}

      {:error, reason} ->
        reject_delegation(state, invocation, run, reason)
    end
  end

  defp open_child_delegation(state, invocation, run, plan) do
    session = state.projection.sessions[invocation.session_id]
    turn = state.projection.turns[invocation.turn_id]
    child_id = Identity.new_id("inv")
    child_message_id = Identity.new_id("msg")
    depth = invocation.delegation_depth + 1

    case delegation_workspace(invocation, session, plan, child_id) do
      {:ok, workspace} ->
        child_spec = %{
          participant_id: plan.participant.id,
          phase_index: 0,
          label: "delegated task",
          system_prompt: Delegation.child_system_prompt(plan),
          output_schema: plan.output_schema,
          workspace: workspace.path,
          workspace_roots: workspace.roots,
          isolation: workspace.isolation,
          delegated_from_invocation_id: invocation.id,
          delegated_from_tool_run_id: run.id,
          delegation_depth: depth
        }

        entries =
          [
            EventEntries.tool_run_requested(invocation, run),
            EventEntries.tool_run_started(invocation, %{run | status: :ready})
          ] ++
            EventEntries.open_invocations(session, turn, [child_spec], [
              {child_id, child_message_id}
            ]) ++
            [EventEntries.delegation_opened(invocation, run, child_id, child_message_id, depth)]

        next =
          state
          |> Persistence.append_and_apply!(entries)
          |> Admission.enqueue(child_id)
          |> Lifecycle.pump_admission()

        pending = next.projection.invocations[invocation.id].tool_runs[run.id]
        {:reply, {:ok, {:delegate, pending}}, next}

      {:error, reason} ->
        reject_delegation(state, invocation, run, reason)
    end
  end

  defp delegation_workspace(invocation, session, %{isolate?: false}, _child_id) do
    context = invocation.execution_context
    path = context.workspace || session.workspace

    roots =
      if context.workspace_roots == [], do: [Path.expand(path)], else: context.workspace_roots

    {:ok,
     %{
       path: path,
       roots: roots,
       isolation: nil
     }}
  end

  defp delegation_workspace(invocation, session, %{isolate?: true}, child_id) do
    source = invocation.execution_context.workspace || session.workspace

    case DelegationWorktree.create(source, child_id) do
      {:ok, isolation} ->
        {:ok,
         %{
           path: isolation.workspace,
           roots: [isolation.workspace],
           isolation: %{
             "workspace" => isolation.workspace,
             "source_workspace" => isolation.source_workspace
           }
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reject_delegation(state, invocation, run, reason) do
    error = if is_atom(reason), do: Atom.to_string(reason), else: inspect(reason)

    entries = [
      EventEntries.tool_run_requested(invocation, %{run | authorization: :denied}),
      EventEntries.tool_run_failed(invocation, run, %{
        "ok" => false,
        "error" => error
      })
    ]

    next = Persistence.append_and_apply!(state, entries)
    denied = next.projection.invocations[invocation.id].tool_runs[run.id]
    {:reply, {:ok, {:denied, denied}}, next}
  end

  defp delegation_bounds(state) do
    orchestration = state.config.orchestration

    %{
      max_children: orchestration.delegation_max_children,
      brief_max_bytes: orchestration.delegation_brief_max_bytes
    }
  end

  defp invocation_workspace(state, invocation) do
    context = invocation.execution_context
    workspace = context.workspace || state.projection.sessions[invocation.session_id].workspace

    roots =
      if context.workspace_roots == [],
        do: Workspace.roots(state.config.workspace),
        else: context.workspace_roots

    {workspace, roots}
  end

  defp fetch_invocation(state, invocation_id) do
    case state.projection.invocations[invocation_id] do
      nil -> {:error, :invocation_not_found}
      invocation -> {:ok, invocation}
    end
  end

  defp ensure_wire_map(value) when is_map(value), do: :ok
  defp ensure_wire_map(_value), do: {:error, :invalid_tool_run_payload}

  defp resumable_run(invocation, review) do
    case Map.get(invocation.tool_runs, review.request_id) do
      %{status: :awaiting_approval} = run ->
        {:ok, run}

      _other ->
        {:error, :legacy_tool_approval_unresumable}
    end
  end

  defp resolve_tool_decision(state, invocation, run, :approve) do
    entry = EventEntries.tool_run_approval_resolved(invocation, run, :approve)

    state
    |> Persistence.append_and_apply!([entry])
    |> Admission.enqueue(invocation.id)
    |> Lifecycle.pump_admission()
  end

  # A denial and its terminal failure must share one durable transaction:
  # persisting them separately could crash between the writes and strand the
  # invocation in :waiting_tool_approval with no review left to resolve.
  defp resolve_tool_decision(state, invocation, run, :deny) do
    denial = EventEntries.tool_run_approval_resolved(invocation, run, :deny)

    Lifecycle.finalize_invocation(state, invocation.id, {:failed, tool_denied_error()}, [denial])
  end

  defp tool_denied_error, do: Failure.new(:tool_denied, "Tool request denied")
end
