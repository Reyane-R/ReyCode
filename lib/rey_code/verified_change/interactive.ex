defmodule ReyCode.VerifiedChange.Interactive do
  @moduledoc """
  Interactive verification admission and durable ownership transitions.

  The public start prepares only an empty canonical directory outside the Engine.
  Admission atomically persists the Session and preparing journal before replying
  with its Session ID. Git and checks belong exclusively to a temporary supervised
  coordinator. Two changes may run globally, two per source workspace, and one
  per initiating Session. Slots remain occupied until the coordinator exits.
  """

  alias ReyCode.Orchestration.{Engine, EventEntries, Participant, VerifiedChange}
  alias ReyCode.Orchestration.Engine.{Identity, Lifecycle, Persistence, Sessions}
  alias ReyCode.Security.{CanonicalPath, Environment}
  alias ReyCode.VerifiedChange, as: Runner
  alias ReyCode.VerifiedChange.Coordinator

  @max_concurrent_count 2
  @max_workspace_count 2

  @spec start(term(), term(), GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def start(source_session_id, options, engine) when is_map(options) do
    prepare_and_start(source_session_id, options, engine, :plain)
  end

  def start(_source_session_id, _options, _engine), do: {:error, :invalid_verified_change_options}

  @doc "Returns the durable receipt and its atomic projection for a remote terminal."
  def start_receipt(source_session_id, options, engine) when is_map(options),
    do: prepare_and_start(source_session_id, options, engine, :receipt)

  def start_receipt(_source_session_id, _options, _engine),
    do: {:error, :invalid_verified_change_options}

  defp prepare_and_start(source_session_id, options, engine, mode) do
    started_ms = System.monotonic_time(:millisecond)
    source = Map.get(Engine.snapshot(engine).sessions, source_session_id)

    with %{} <- source,
         options = Map.put(options, :workspace, source_workspace(source)),
         :ok <- Runner.validate_options(options),
         {:ok, directory} <- prepare_directory() do
      request = {:start_verified_change, source_session_id, options, directory, started_ms}
      request = if mode == :receipt, do: {:client_request, request}, else: request
      result = GenServer.call(engine, request)

      response =
        case result do
          {:engine_result, response, _projection} -> response
          response -> response
        end

      if match?({:error, _}, response), do: File.rmdir(directory)
      result
    else
      nil -> {:error, :session_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_directory do
    directory = Path.join(System.tmp_dir!(), Identity.new_id("verified"))

    with :ok <- File.mkdir(directory) do
      CanonicalPath.resolve(directory)
    end
  end

  @doc false
  def admit(state, source_id, options, directory, started_ms) do
    source = Map.get(state.projection.sessions, source_id)

    with :ok <- admission(state, source, source_id),
         :ok <- Runner.validate_options(options),
         true <- source_workspace(source) == options.workspace do
      open(state, source, options, directory, started_ms)
    else
      false -> {:reply, {:error, :source_workspace_changed}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp admission(_state, nil, _source_id), do: {:error, :session_not_found}

  defp admission(state, source, source_id) do
    owners = Map.values(state.verified_changes)

    cond do
      source.verified_change != nil and source.verified_change.phase not in ~w(ready blocked) ->
        {:error, :verified_change_source_owned}

      Enum.any?(owners, &(&1.source_id == source_id)) ->
        {:error, :verified_change_already_active}

      length(owners) >= @max_concurrent_count ->
        {:error, :verified_change_capacity}

      Enum.count(owners, &(&1.workspace == source_workspace(source))) >= @max_workspace_count ->
        {:error, :verified_change_workspace_capacity}

      true ->
        :ok
    end
  end

  defp open(state, source, options, directory, started_ms) do
    session_id = Identity.new_id("session")
    title = options.prompt |> String.replace(~r/\s+/, " ") |> String.slice(0, 120)
    slug = Identity.unique_slug(Identity.slugify(title), state.projection)
    participants = Enum.filter(source.participants, &(&1.kind == :primary))
    workflow = VerifiedChange.workflow_from_options(options)
    participants = participants ++ stage_participants(workflow)

    record =
      struct!(
        VerifiedChange,
        Map.merge(
          Map.take(options, [
            :prompt,
            :commands,
            :timeout_ms,
            :max_repair_count,
            :check_timeout_ms
          ]),
          %{
            id: Identity.new_id("verified"),
            source_workspace: source_workspace(source),
            workspace: directory,
            base_commit: nil,
            phase: "preparing",
            repair_count: 0,
            baseline: [],
            checks: [],
            patch: "",
            workflow: workflow
          }
        )
      )

    case VerifiedChange.from_wire(VerifiedChange.to_wire(record)) do
      {:ok, _record} ->
        entries = [
          EventEntries.session_created(session_id, slug, title, directory, participants),
          {:verified_change_recorded,
           %{"room_id" => session_id, "record" => VerifiedChange.to_wire(record)},
           [aggregate_type: :room, aggregate_id: session_id, room_id: session_id]}
        ]

        state = Persistence.append_and_apply!(state, entries)
        launch(state, source, session_id, record, started_ms)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Stage workers are frozen at admission: report-only task participants whose
  # tools the verified-change boundary withholds for the entire workflow.
  defp stage_participants(nil), do: []

  defp stage_participants(workflow) do
    Enum.map(workflow, fn {stage, runtime} ->
      %Participant{
        id: Identity.new_id("participant"),
        name: VerifiedChange.stage_participant_name(stage),
        perspective: "Report-only stage worker; no tools are available",
        provider: runtime["provider"],
        model: runtime["model"],
        model_tier: :smol,
        kind: :task
      }
    end)
  end

  defp launch(state, source, session_id, record, started_ms) do
    policy = state.config.tools.bash

    run = %Runner{
      engine: self(),
      session_id: session_id,
      record: record,
      deadline_ms: started_ms + record.timeout_ms,
      bash_policy: policy,
      environment: Environment.allowlisted(additional_names: policy.env_allowlist),
      interaction: :interactive
    }

    case DynamicSupervisor.start_child(state.agent_supervisor, {Coordinator, run}) do
      {:ok, pid} ->
        owner = %{
          pid: pid,
          ref: Process.monitor(pid),
          worker: nil,
          source_id: source.id,
          workspace: source_workspace(source)
        }

        state = put_in(state.verified_changes[session_id], owner)
        GenServer.cast(pid, :start)
        {:reply, {:ok, session_id}, state}

      {:error, _reason} ->
        {:reply, :ok, state} = block(state, session_id, "Coordinator could not start")
        {:reply, {:ok, session_id}, state}
    end
  end

  defp source_workspace(%{verified_change: %{source_workspace: workspace}}), do: workspace
  defp source_workspace(source), do: source.workspace

  @doc false
  def register_worker(state, session_id, pid, caller) do
    case Map.get(state.verified_changes, session_id) do
      %{pid: ^caller, worker: nil} ->
        {:reply, :ok, put_in(state.verified_changes[session_id].worker, pid)}

      _ ->
        {:reply, {:error, :verified_change_not_owner}, state}
    end
  end

  @doc false
  def authorized?(state, session_id, caller) do
    case Map.get(state.verified_changes, session_id) do
      nil -> true
      %{worker: ^caller} -> true
      _ -> false
    end
  end

  @doc false
  def cancel(state, session_id) do
    case Map.get(state.projection.sessions, session_id) do
      %{verified_change: %{phase: phase}} when phase not in ~w(ready blocked) ->
        {:reply, :ok, next} = block(state, session_id, "Cancelled by operator or total deadline")
        next = cancel_turns(next, session_id)

        if owner = Map.get(next.verified_changes, session_id),
          do: GenServer.cast(owner.pid, :cancel)

        {:reply, :ok, next}

      %{verified_change: %{phase: "blocked"}} ->
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :verified_change_not_active}, state}
    end
  end

  @doc false
  def down(state, ref) do
    case Enum.find(state.verified_changes, fn {_id, owner} -> owner.ref == ref end) do
      nil ->
        :unowned

      {session_id, _owner} ->
        {:reply, :ok, state} = block(state, session_id, "Coordinator exited; not resumed")
        state = cancel_turns(state, session_id)
        {:ok, %{state | verified_changes: Map.delete(state.verified_changes, session_id)}}
    end
  end

  defp block(state, session_id, reason) do
    record = state.projection.sessions[session_id].verified_change

    if record.phase in ~w(ready blocked) do
      {:reply, :ok, state}
    else
      Sessions.record_verified_change(
        state,
        session_id,
        VerifiedChange.to_wire(%{record | phase: "blocked", error: reason})
      )
    end
  end

  defp cancel_turns(state, session_id) do
    state.projection.turns
    |> Map.values()
    |> Enum.filter(&(&1.session_id == session_id and &1.status != :terminal))
    |> Enum.reduce(state, fn turn, acc ->
      {:ok, next} = Lifecycle.cancel_turn(acc, turn.id, "Verified change stopped")
      next
    end)
  end
end
