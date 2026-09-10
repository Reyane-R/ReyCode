defmodule ReyCode.VerifiedChange do
  @moduledoc """
  Opt-in, headless verified changes with a frozen owner check contract.

  Journals phases before execution and retains the complete bounded patch before
  reporting ready. Never applies changes to the source. Every return transfers
  cleanup ownership of the single retained directory to the caller; cancellation
  is requested but cleanup must wait until execution is known to have stopped.
  There is no resume API. An interrupted record is not permission to rerun work.
  Worktrees isolate edits, not host execution of owner-supplied commands.
  """

  alias ReyCode.OneShot
  alias ReyCode.Orchestration.{Engine, VerifiedChangeContext}
  alias ReyCode.Orchestration.Engine.SourceTask
  alias ReyCode.Orchestration.VerifiedChange, as: Journal
  alias ReyCode.Provider.Registry
  alias ReyCode.Provider.TextBuffer
  alias ReyCode.RuntimeConfig.Tools.Bash, as: BashPolicy
  alias ReyCode.Security.{CanonicalPath, Environment}
  alias ReyCode.Tool.{Bash, Request, Result}
  alias ReyCode.VerifiedChange.Worktree

  # Compilation checks need more capture than interactive tools. Overflow blocks;
  # the separate journal preview budget never changes an authoritative exit status.
  @max_check_capture_bytes 1_048_576
  @max_check_preview_bytes 16_384
  @preview_suffix "\n[check output preview truncated]"
  @max_stage_response_bytes 16_384
  @max_stage_error_bytes 4_000
  @stage_truncated_suffix "\n[stage response truncated]"

  defstruct [
    :record,
    :engine,
    :session_id,
    :deadline_ms,
    :bash_policy,
    :environment,
    interaction: :headless,
    turn_id: nil,
    response: ""
  ]

  @doc "Validates bounded options without executing commands or opening a Session."
  @spec validate_options(term()) :: :ok | {:error, String.t()}
  def validate_options(options) when is_map(options) do
    stage_result = Journal.validate_stage_options(options)

    cond do
      not text?(Map.get(options, :prompt), 40_000) ->
        {:error, "prompt must be nonempty UTF-8 text of at most 40000 bytes"}

      not text?(Map.get(options, :workspace), 4096) ->
        {:error, "workspace must be a nonempty path"}

      not commands?(Map.get(options, :commands)) ->
        {:error, "commands must contain 1..8 nonempty strings of at most 4096 bytes"}

      Map.get(options, :max_repair_count) not in 0..3 ->
        {:error, "max_repair_count must be an integer in 0..3"}

      not bounded_integer?(Map.get(options, :timeout_ms), 3_600_000) ->
        {:error, "timeout_ms must be an integer in 1..3600000"}

      not bounded_integer?(Map.get(options, :check_timeout_ms), 600_000) ->
        {:error, "check_timeout_ms must be an integer in 1..600000"}

      stage_result != :ok ->
        stage_result

      true ->
        contract_budget(options)
    end
  end

  def validate_options(_options), do: {:error, "verified-change options must be a map"}

  defp contract_budget(options) do
    encoded =
      Jason.encode!(
        Map.take(options, [
          :prompt,
          :commands,
          :testing_provider,
          :testing_model,
          :release_provider,
          :release_model
        ])
      )

    if byte_size(encoded) > 70_000 do
      {:error, "encoded prompt and commands exceed the 70000-byte frozen contract budget"}
    else
      :ok
    end
  end

  @doc "Runs one isolated change and at most three repairs; all checks are harness-owned."
  @spec run(map(), GenServer.server()) :: {:ok | :error, map()}
  def run(options, engine \\ Engine) do
    case validate_options(options) do
      :ok -> start(options, engine)
      {:error, reason} -> early_error(reason)
    end
  end

  @doc "Executes an already-journaled interactive receipt under its coordinator's original deadline."
  @spec run_prepared(%__MODULE__{}) :: {:ok | :error, map()}
  def run_prepared(state) do
    case external(state, fn ->
           Worktree.source(state.record.source_workspace, state.deadline_ms)
         end) do
      {:ok, source, commit} when source == state.record.source_workspace ->
        case journal(state, %{base_commit: commit}) do
          {:ok, next} -> execute(next)
          {:error, failed, reason} -> blocked(failed, reason)
        end

      {:error, reason} ->
        blocked(state, reason)
    end
  end

  defp start(options, engine) do
    deadline_ms = System.monotonic_time(:millisecond) + options.timeout_ms
    %BashPolicy{} = policy = Engine.check_policy(engine)
    environment = Environment.allowlisted(additional_names: policy.env_allowlist)

    case prepare(options, engine, deadline_ms) do
      {:ok, state} -> execute(%{state | bash_policy: policy, environment: environment})
      {:error, reason} -> early_error(reason)
    end
  end

  defp prepare(options, engine, deadline_ms) do
    with {:ok, source, commit} <- Worktree.source(options.workspace, deadline_ms) do
      id = "verified-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      workspace = Path.join(System.tmp_dir!(), id)

      record =
        struct!(
          Journal,
          Map.merge(
            Map.take(
              options,
              [:prompt, :commands, :max_repair_count, :timeout_ms, :check_timeout_ms]
            ),
            %{
              id: id,
              source_workspace: source,
              workspace: workspace,
              base_commit: commit,
              phase: "preparing",
              repair_count: 0,
              baseline: [],
              checks: [],
              patch: "",
              workflow: Journal.workflow_from_options(options)
            }
          )
        )

      with :ok <- File.mkdir(workspace),
           {:ok, workspace} <- CanonicalPath.resolve(workspace) do
        open_prepared(%{record | workspace: workspace}, engine, deadline_ms)
      end
    end
  end

  defp open_prepared(record, engine, deadline_ms) do
    case OneShot.open(Map.from_struct(record), engine) do
      {:ok, session_id} ->
        case add_stage_participants(session_id, record, engine) do
          :ok ->
            {:ok,
             %__MODULE__{
               record: record,
               engine: engine,
               session_id: session_id,
               deadline_ms: deadline_ms
             }}

          {:error, reason} ->
            File.rmdir(record.workspace)
            {:error, reason}
        end

      {:error, reason} ->
        File.rmdir(record.workspace)
        {:error, reason}
    end
  end

  # Stage runtimes resolve here, before any journal or check executes: an
  # unresolvable cheap model fails the change closed instead of silently
  # substituting the Main runtime.
  defp add_stage_participants(_session_id, %{workflow: nil}, _engine), do: :ok

  defp add_stage_participants(session_id, record, engine) do
    record.workflow
    |> Map.to_list()
    |> Enum.reduce_while(:ok, fn {stage, runtime}, :ok ->
      case add_stage_participant(session_id, stage, runtime, engine) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp add_stage_participant(session_id, stage, runtime, engine) do
    with {:ok, participant_id} <-
           Engine.add_task_participant(
             session_id,
             Journal.stage_participant_name(stage),
             "Report-only stage worker; no tools are available",
             engine
           ) do
      Engine.configure_participants(
        session_id,
        [participant_id],
        Registry.normalize_provider_id(runtime["provider"]),
        runtime["model"],
        engine
      )
    end
  end

  defp execute(state) do
    with {:ok, state} <- journal(state, %{}),
         {:ok, _} <- external(state, fn -> Worktree.create(state.record, state.deadline_ms) end),
         {:ok, state} <- journal(state, %{phase: "baseline"}),
         {:ok, state} <- checks(state, :baseline),
         {:ok, state} <- journal(state, %{phase: "implementing"}) do
      implement(state)
    else
      {:error, failed, reason} -> blocked(failed, reason)
      {:error, reason} -> blocked(state, reason)
    end
  end

  defp implement(state) do
    prompt = VerifiedChangeContext.prompt(state.record)

    case OneShot.run_turn(
           state.session_id,
           prompt,
           remaining(state),
           state.engine,
           state.interaction
         ) do
      {:ok, report} ->
        state = %{state | turn_id: report.turn_id, response: report.response}
        verify(state)

      {:error, report} ->
        blocked(%{state | turn_id: report.turn_id, response: report.response}, report.error)
    end
  end

  defp verify(state) do
    with {:ok, state} <- journal(state, %{phase: "verifying", checks: []}),
         {:ok, state} <- checks(state, :checks) do
      if Enum.all?(state.record.checks, &(&1["exit_code"] == 0)) do
        ready(state)
      else
        repair(state)
      end
    else
      {:error, failed, reason} -> blocked(failed, reason)
    end
  end

  defp repair(state) do
    cond do
      state.record.repair_count >= state.record.max_repair_count ->
        blocked(state, :repair_exhausted)

      workflow_stage?(state.record, "testing") ->
        analyze_and_repair(state)

      true ->
        begin_repair(state, nil)
    end
  end

  # Report-only analysis: the Testing stage sees the immutable failed-check
  # evidence while the analyzing phase withholds every tool, then the whole
  # bounded outcome travels with the repairing journal. An unavailable report
  # never blocks repair; Main still receives the raw check evidence.
  defp analyze_and_repair(state) do
    case journal(state, %{phase: "analyzing", analysis: nil}) do
      {:ok, state} ->
        prompt = VerifiedChangeContext.analysis_prompt(state.record)
        {outcome, report} = stage_turn(state, "testing", prompt)
        begin_repair(state, stage_result(outcome, report))

      {:error, failed, reason} ->
        blocked(failed, reason)
    end
  end

  defp begin_repair(state, analysis) do
    case journal(state, %{
           phase: "repairing",
           repair_count: state.record.repair_count + 1,
           analysis: analysis
         }) do
      {:ok, next} -> implement(next)
      {:error, failed, reason} -> blocked(failed, reason)
    end
  end

  defp ready(state) do
    record = state.record

    with :ok <-
           external(state, fn ->
             Worktree.unchanged(record.source_workspace, record.base_commit, state.deadline_ms)
           end),
         {:ok, patch, hash} <-
           external(state, fn ->
             Worktree.snapshot(record.workspace, record.base_commit, state.deadline_ms)
           end),
         true <- Enum.all?(record.checks, &(&1["snapshot_hash"] == hash)),
         {:ok, state} <- prepare_release(state, patch, hash) do
      {:ok, report(state, :ready)}
    else
      false -> blocked(state, :candidate_changed_after_checks)
      {:error, failed, reason} -> blocked(failed, reason)
      {:error, reason} -> blocked(state, reason)
    end
  end

  # Release metadata is advisory and cannot affect readiness: a failed or
  # timed-out Release stage still completes the verified change as ready.
  defp prepare_release(state, patch, hash) do
    if workflow_stage?(state.record, "release") do
      with {:ok, state} <- journal(state, %{phase: "releasing", patch: patch, patch_hash: hash}) do
        prompt = VerifiedChangeContext.release_prompt(state.record)
        {outcome, report} = stage_turn(state, "release", prompt)
        complete_ready(state, patch, hash, stage_result(outcome, report))
      end
    else
      complete_ready(state, patch, hash, nil)
    end
  end

  defp complete_ready(state, patch, hash, metadata) do
    case journal(state, %{phase: "ready", patch: patch, patch_hash: hash, metadata: metadata}) do
      {:ok, state} -> {:ok, state}
      {:error, failed, reason} -> {:error, failed, reason}
    end
  end

  defp workflow_stage?(record, stage),
    do: is_map(record.workflow) and is_map_key(record.workflow, stage)

  defp stage_turn(state, stage, prompt) do
    if remaining(state) == 0 do
      {:unavailable, %{turn_id: nil, response: "", error: "total timeout before stage start"}}
    else
      run_stage_turn(state, stage, prompt)
    end
  end

  defp run_stage_turn(state, stage, prompt) do
    case stage_participant(state, stage) do
      nil ->
        {:unavailable,
         %{turn_id: nil, response: "", error: "stage participant is not configured"}}

      participant ->
        stage_outcome(
          OneShot.run_stage(
            state.session_id,
            participant.id,
            prompt,
            remaining(state),
            state.engine,
            state.interaction
          )
        )
    end
  end

  defp stage_outcome({:ok, report}), do: {:completed, report}
  defp stage_outcome({:error, report}), do: {:unavailable, report}

  defp stage_participant(state, stage) do
    name = Journal.stage_participant_name(stage)

    case Engine.snapshot(state.engine).sessions[state.session_id] do
      nil -> nil
      session -> Enum.find(session.participants, &(&1.kind == :task and &1.name == name))
    end
  end

  # Stage outcomes are advisory, bounded, and explicitly labeled; they never
  # carry authority over check evidence.
  defp stage_result(outcome, report) do
    %{
      "outcome" => Atom.to_string(outcome),
      "response" => bounded_stage_text(Map.get(report, :response, ""), @max_stage_response_bytes),
      "turn_id" => Map.get(report, :turn_id),
      "error" => stage_error_text(outcome, report)
    }
  end

  defp stage_error_text(:completed, _report), do: nil

  defp stage_error_text(:unavailable, report) do
    case Map.get(report, :error) do
      nil -> "stage turn did not complete"
      error -> bounded_stage_text(reason_text(error), @max_stage_error_bytes)
    end
  end

  defp bounded_stage_text(text, max_bytes) do
    if byte_size(text) <= max_bytes do
      text
    else
      TextBuffer.truncate_utf8(text, max_bytes - byte_size(@stage_truncated_suffix)) <>
        @stage_truncated_suffix
    end
  end

  defp checks(state, field) do
    Enum.reduce_while(state.record.commands, {:ok, state}, fn command, {:ok, current} ->
      case check(current, command, field) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp check(state, command, field) do
    record = state.record

    case external(state, fn ->
           Worktree.snapshot(record.workspace, record.base_commit, state.deadline_ms)
         end) do
      {:ok, patch, hash} -> check_snapshot(state, command, field, {patch, hash})
      {:error, reason} -> {:error, state, reason}
    end
  end

  defp check_snapshot(state, command, field, {patch, hash}) do
    record = state.record
    evidence = run_check(state, command, hash)

    evidence =
      case external(state, fn ->
             Worktree.snapshot(record.workspace, record.base_commit, state.deadline_ms)
           end) do
        {:ok, ^patch, ^hash} -> evidence
        {:ok, _, _} -> Map.put(evidence, "error", "check mutated candidate")
        {:error, reason} -> Map.put(evidence, "error", reason_text(reason))
      end

    updates = %{field => Map.fetch!(record, field) ++ [evidence], patch: patch, patch_hash: hash}

    with {:ok, next} <- journal(state, updates) do
      if evidence["error"] == nil, do: {:ok, next}, else: {:error, next, evidence["error"]}
    end
  end

  defp run_check(state, command, hash) do
    if remaining(state) == 0 do
      %{
        "command" => command,
        "exit_code" => nil,
        "output" => "",
        "error" => "total timeout",
        "snapshot_hash" => hash
      }
    else
      execute_check(state, command, hash)
    end
  end

  defp execute_check(state, command, hash) do
    policy = %{
      state.bash_policy
      | timeout_ms:
          max(
            1,
            min(
              remaining(state),
              min(state.record.check_timeout_ms, state.bash_policy.timeout_ms)
            )
          ),
        max_output_bytes: @max_check_capture_bytes,
        max_error_bytes: @max_check_capture_bytes
    }

    request =
      Request.new(
        tool: "bash",
        arguments: %{"command" => command},
        workspace: state.record.workspace,
        roots: [state.record.workspace]
      )

    environment = state.environment

    result =
      case external(state, fn -> Bash.run(request, policy: policy, environment: environment) end) do
        {:error, reason} -> Result.error(reason)
        result -> result
      end

    exit_code = result.metadata["exit_code"]
    {stdout, stderr} = check_output(result)

    error =
      cond do
        result.metadata["invalid_utf8"] -> "check output is not UTF-8"
        result.metadata["timed_out"] -> "check timed out"
        result.truncated -> "check output limit exceeded"
        result.metadata["broken_pipe"] -> "check capture failed"
        not is_integer(exit_code) -> reason_text(result.error)
        true -> nil
      end

    %{
      "command" => command,
      "exit_code" => exit_code,
      "output" => check_preview(stdout, stderr),
      "error" => error,
      "snapshot_hash" => hash
    }
  end

  defp check_output(%{ok: true, output: output, metadata: metadata}),
    do: {output, Map.get(metadata, "stderr", "")}

  defp check_output(%{error: %{"output" => output, "stderr" => stderr}}),
    do: {output, stderr}

  defp check_output(_result), do: {"", ""}

  defp external(state, operation) do
    case SourceTask.run(
           state.engine,
           {:verification, state.session_id},
           operation,
           remaining(state) + 10_000
         ) do
      {:ok, result} -> result
      {:error, _} = error -> error
    end
  end

  defp check_preview(stdout, stderr) do
    if byte_size(stdout) + byte_size(stderr) <= @max_check_preview_bytes do
      stdout <> stderr
    else
      budget_bytes = @max_check_preview_bytes - byte_size(@preview_suffix)
      stderr_bytes = min(byte_size(stderr), div(budget_bytes, 2))

      TextBuffer.truncate_utf8(stdout, budget_bytes - stderr_bytes) <>
        TextBuffer.truncate_utf8(stderr, stderr_bytes) <> @preview_suffix
    end
  end

  defp journal(state, updates) do
    record = struct!(state.record, updates)

    case Engine.record_verified_change(state.session_id, Journal.to_wire(record), state.engine) do
      :ok -> {:ok, %{state | record: record}}
      {:error, reason} -> {:error, state, {:journal_failed, reason}}
    end
  end

  defp blocked(state, reason) do
    error = reason_text(reason)

    case journal(state, %{phase: "blocked", error: error}) do
      {:ok, state} ->
        {:error, Map.put(report(state, :blocked), :error, error)}

      {:error, _, journal_error} ->
        {:error,
         Map.put(report(state, :blocked), :error, error <> "; " <> reason_text(journal_error))}
    end
  end

  defp report(state, outcome) do
    %{
      outcome: outcome,
      response: state.response,
      session_id: state.session_id,
      turn_id: state.turn_id,
      verification:
        Map.merge(Journal.to_wire(state.record), %{
          "cleanup_owner" => "caller",
          "worktree_retained" => true,
          "cleanup" =>
            "After execution has stopped: git -C SOURCE worktree remove --force WORKSPACE; use source_workspace and workspace above",
          "scope" =>
            "Git snapshot, excluding ignored files and empty directories; not an OS sandbox"
        })
    }
  end

  defp remaining(state), do: max(0, state.deadline_ms - System.monotonic_time(:millisecond))

  defp early_error(reason),
    do:
      {:error,
       %{
         outcome: :blocked,
         response: "",
         error: reason_text(reason),
         session_id: nil,
         turn_id: nil,
         verification: %{}
       }}

  defp reason_text(reason) when is_binary(reason), do: String.slice(reason, 0, 1000)
  defp reason_text(reason), do: inspect(reason, limit: 10, printable_limit: 1000)
  defp bounded_integer?(value, maximum), do: is_integer(value) and value in 1..maximum

  defp commands?(commands),
    do: is_list(commands) and length(commands) in 1..8 and Enum.all?(commands, &text?(&1, 4096))

  defp text?(value, maximum),
    do:
      is_binary(value) and byte_size(value) <= maximum and
        String.valid?(value) and String.trim(value) != "" and not String.contains?(value, <<0>>)
end
