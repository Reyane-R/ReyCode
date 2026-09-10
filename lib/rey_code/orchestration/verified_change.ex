defmodule ReyCode.Orchestration.VerifiedChange do
  @moduledoc """
  Bounded durable contract and evidence for one verified change.

  Phases are wire strings. Callers journal a phase before its external work.
  Reports are ordered prefixes of the command contract, at most eight each.
  Leaving baseline requires complete executed checks, including ordinary failures;
  ready additionally
  requires complete passing checks whose snapshot hashes equal patch_hash.
  Entering repairing increments repair_count exactly once. Same-phase evidence
  updates keep that count unchanged. Baseline evidence freezes on implementation.

  Omitted baseline/checks default to [], patch to "", and patch_hash/error to nil.
  Omitted workflow/analysis/metadata default to nil. Identity, paths, resolved
  commits, and hashes are nonempty UTF-8 strings up to 4096
  bytes. Preparing may have no commit until Git inspection finishes; it can be
  resolved exactly once before baseline execution. Check errors, like the record error, are nullable and capped at 4000
  bytes. The patch cap is 2 MiB; text is never truncated.

  The optional workflow freezes report-only stage runtimes (provider/model
  string pairs under "testing" and "release") before baseline execution. The
  optional analysis and metadata records store bounded report-only stage
  outcomes; a stage outcome never changes check evidence or readiness.

  A restored nonterminal record describes interrupted work, not permission to
  resume it: the coordinator must record blocked with an interruption error.
  Terminal records cannot be replaced, including by a different ID.
  """

  alias ReyCode.Hashing
  alias ReyCode.Orchestration.Validation

  @fields ~w(id phase source_workspace workspace base_commit prompt commands max_repair_count repair_count timeout_ms check_timeout_ms baseline checks patch patch_hash error workflow analysis metadata)a
  @immutable ~w(id source_workspace workspace prompt commands max_repair_count timeout_ms check_timeout_ms workflow)a
  @phases ~w(preparing baseline implementing verifying analyzing repairing releasing ready blocked)
  @defaults %{
    "baseline" => [],
    "checks" => [],
    "patch" => "",
    "patch_hash" => nil,
    "error" => nil,
    "workflow" => nil,
    "analysis" => nil,
    "metadata" => nil
  }
  @check_fields ~w(command exit_code output error snapshot_hash)
  @max_patch_bytes 2 * 1024 * 1024
  @workflow_stages ~w(testing release)
  @max_stage_response_bytes 16_384

  defstruct @fields

  @type check :: %{
          String.t() => String.t() | integer() | nil
        }
  @type t :: %__MODULE__{
          id: String.t(),
          phase: String.t(),
          source_workspace: String.t(),
          workspace: String.t(),
          base_commit: String.t() | nil,
          prompt: String.t(),
          commands: [String.t()],
          max_repair_count: 0..3,
          repair_count: 0..3,
          timeout_ms: pos_integer(),
          check_timeout_ms: pos_integer(),
          baseline: [check()],
          checks: [check()],
          patch: String.t(),
          patch_hash: String.t() | nil,
          error: String.t() | nil,
          workflow: map() | nil,
          analysis: map() | nil,
          metadata: map() | nil
        }

  @doc "Validates a closed string-keyed wire record without coercion or truncation."
  @spec from_wire(term()) :: {:ok, t()} | {:error, :invalid_verified_change}
  def from_wire(wire) when is_map(wire) and not is_struct(wire) do
    wire = Map.merge(@defaults, wire)

    if map_size(wire) == length(@fields) and
         Enum.all?(@fields, &valid_field?(&1, Map.get(wire, Atom.to_string(&1)))) do
      record = struct!(__MODULE__, Enum.map(@fields, &{&1, Map.fetch!(wire, Atom.to_string(&1))}))

      if valid_evidence?(record), do: {:ok, record}, else: {:error, :invalid_verified_change}
    else
      {:error, :invalid_verified_change}
    end
  end

  def from_wire(_wire), do: {:error, :invalid_verified_change}

  @doc "Encodes the record for the append-only event seam."
  @spec to_wire(t()) :: map()
  def to_wire(record), do: Map.new(@fields, &{Atom.to_string(&1), Map.fetch!(record, &1)})

  @doc """
  Builds the frozen workflow map from already-validated stage options.

  Providers are normalized to wire strings because event records are
  JSON-encoded. Options validated by validate_stage_options/1 always produce
  complete provider/model pairs; unconfigured stages are omitted.
  """
  @spec workflow_from_options(map()) :: map() | nil
  def workflow_from_options(options) do
    stages =
      for stage <- @workflow_stages,
          provider = Map.get(options, String.to_existing_atom("#{stage}_provider")),
          model = Map.get(options, String.to_existing_atom("#{stage}_model")),
          do: {stage, %{"provider" => provider_text(provider), "model" => model}}

    case stages do
      [] -> nil
      stages -> Map.new(stages)
    end
  end

  defp provider_text(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp provider_text(provider) when is_binary(provider), do: provider

  @stage_names %{"testing" => "Testing", "release" => "Release"}

  @doc "Returns the canonical task-participant name for one workflow stage."
  @spec stage_participant_name(String.t()) :: String.t()
  def stage_participant_name(stage), do: Map.fetch!(@stage_names, stage)

  @doc "Returns the workflow stage identifiers in canonical order."
  @spec workflow_stages() :: [String.t()]
  def workflow_stages, do: @workflow_stages

  @doc "Validates one optional stage runtime pair; both parts or neither must be present."
  @spec validate_stage_options(map()) :: :ok | {:error, String.t()}
  def validate_stage_options(options) do
    Enum.reduce_while(@workflow_stages, :ok, fn stage, :ok ->
      provider = Map.get(options, String.to_existing_atom("#{stage}_provider"))
      model = Map.get(options, String.to_existing_atom("#{stage}_model"))

      cond do
        is_nil(provider) and is_nil(model) ->
          {:cont, :ok}

        stage_option?(provider) and stage_option?(model) ->
          {:cont, :ok}

        true ->
          {:halt,
           {:error,
            "#{stage}_provider and #{stage}_model must both be nonempty strings of at most 4096 bytes"}}
      end
    end)
  end

  defp stage_option?(value),
    do:
      (is_binary(value) or is_atom(value)) and text?(to_string(value), 4096) and
        to_string(value) != ""

  @doc "Normalizes a checkpoint record, asserting its durable validity."
  @spec from_map(nil | map()) :: nil | t()
  def from_map(nil), do: nil

  def from_map(record) do
    {:ok, record} = record |> to_wire() |> from_wire()
    record
  end

  @doc "Validates ordering, frozen contract, and repair admission against the current record."
  @spec transition(nil | t(), t()) :: :ok | {:error, atom()}
  def transition(nil, %__MODULE__{
        phase: "preparing",
        repair_count: 0,
        baseline: [],
        checks: [],
        patch: "",
        patch_hash: nil,
        error: nil
      }),
      do: :ok

  def transition(nil, _record), do: {:error, :invalid_verified_change_transition}

  def transition(%__MODULE__{phase: phase}, _record) when phase in ~w(ready blocked),
    do: {:error, :verified_change_terminal}

  def transition(previous, record) do
    cond do
      Map.take(previous, @immutable) != Map.take(record, @immutable) or
          not commit_transition?(previous, record) ->
        {:error, :verified_change_contract_changed}

      not valid_step?(previous, record) ->
        {:error, :invalid_verified_change_transition}

      previous.phase not in ~w(preparing baseline) and previous.baseline != record.baseline ->
        {:error, :verified_change_baseline_changed}

      true ->
        :ok
    end
  end

  defp commit_transition?(%{phase: "preparing", base_commit: nil}, %{phase: "preparing"}),
    do: true

  defp commit_transition?(previous, record), do: previous.base_commit == record.base_commit

  defp valid_step?(previous, record) do
    entering_repair? = previous.phase in ~w(verifying analyzing) and record.phase == "repairing"
    expected_count = previous.repair_count + if(entering_repair?, do: 1, else: 0)

    next = %{
      "preparing" => "baseline",
      "baseline" => "implementing",
      "implementing" => "verifying",
      "analyzing" => "repairing",
      "repairing" => "verifying",
      "releasing" => "ready"
    }

    allowed? =
      record.phase == previous.phase or record.phase == "blocked" or
        record.phase == Map.get(next, previous.phase) or
        (previous.phase == "verifying" and record.phase in ~w(analyzing repairing releasing ready))

    allowed? and record.repair_count == expected_count
  end

  defp valid_field?(field, value) when field in ~w(id source_workspace workspace)a,
    do: text?(value, 4096) and value != ""

  defp valid_field?(:base_commit, value),
    do: is_nil(value) or (text?(value, 4096) and value != "")

  defp valid_field?(:phase, value), do: value in @phases

  defp valid_field?(:prompt, value),
    do: text?(value, Validation.message_max_bytes()) and value != ""

  defp valid_field?(:commands, value),
    do:
      is_list(value) and length(value) in 1..8 and
        Enum.all?(value, &(text?(&1, 4096) and &1 != ""))

  defp valid_field?(field, value) when field in [:max_repair_count, :repair_count],
    do: is_integer(value) and value in 0..3

  defp valid_field?(:timeout_ms, value), do: is_integer(value) and value in 1..3_600_000
  defp valid_field?(:check_timeout_ms, value), do: is_integer(value) and value in 1..600_000

  defp valid_field?(field, value) when field in [:baseline, :checks],
    do: is_list(value) and length(value) <= 8 and Enum.all?(value, &check?/1)

  defp valid_field?(:patch, value), do: text?(value, @max_patch_bytes)
  defp valid_field?(:patch_hash, value), do: is_nil(value) or (text?(value, 4096) and value != "")
  defp valid_field?(:error, value), do: nullable_text?(value, 4000)
  defp valid_field?(:workflow, value), do: is_nil(value) or workflow?(value)

  defp valid_field?(field, value) when field in [:analysis, :metadata],
    do: is_nil(value) or stage?(value)

  # The workflow freezes report-only stage runtimes as provider/model string
  # pairs. Exactly one of each stage's pair may be configured; atoms never
  # enter the wire map because event records are JSON-encoded.
  defp workflow?(workflow) when is_map(workflow),
    do: map_size(workflow) in 1..2 and Enum.all?(workflow, &workflow_stage?/1)

  defp workflow?(_workflow), do: false

  defp workflow_stage?({stage, runtime}) when stage in @workflow_stages,
    do: runtime?(runtime)

  defp workflow_stage?(_entry), do: false

  defp runtime?(runtime) when is_map(runtime) do
    map_size(runtime) == 2 and Map.keys(runtime) == ~w(model provider) and
      text?(runtime["provider"], 4096) and runtime["provider"] != "" and
      text?(runtime["model"], 4096) and runtime["model"] != ""
  end

  defp runtime?(_runtime), do: false

  # Bounded report-only stage outcome: an advisory response plus its durable
  # turn identity. Provider-reported verdicts never appear here because check
  # evidence alone decides readiness.
  defp stage?(stage) when is_map(stage) do
    map_size(stage) == 4 and Map.keys(stage) == ~w(error outcome response turn_id) and
      stage["outcome"] in ~w(completed unavailable) and
      text?(stage["response"], @max_stage_response_bytes) and
      nullable_text?(stage["turn_id"], 4096) and nullable_text?(stage["error"], 4000)
  end

  defp stage?(_stage), do: false

  defp check?(check) when is_map(check) do
    Enum.sort(Map.keys(check)) == Enum.sort(@check_fields) and
      text?(check["command"], 4096) and check["command"] != "" and
      (is_nil(check["exit_code"]) or is_integer(check["exit_code"])) and
      text?(check["output"], 16_384) and nullable_text?(check["error"], 4000) and
      text?(check["snapshot_hash"], 4096) and check["snapshot_hash"] != ""
  end

  defp check?(_check), do: false

  defp valid_evidence?(record) do
    (record.base_commit != nil or record.phase in ~w(preparing blocked)) and
      record.repair_count <= record.max_repair_count and
      report_prefix?(record.baseline, record.commands) and
      report_prefix?(record.checks, record.commands) and
      phase_evidence?(record)
  end

  defp report_prefix?(reports, commands),
    do: Enum.map(reports, & &1["command"]) == Enum.take(commands, length(reports))

  defp phase_evidence?(%{phase: "preparing"} = record),
    do: record.baseline == [] and record.checks == []

  defp phase_evidence?(%{phase: "blocked", error: error}), do: is_binary(error) and error != ""
  defp phase_evidence?(%{phase: "baseline"} = record), do: record.checks == []

  defp phase_evidence?(record) do
    executed?(record.baseline, record.commands) and ready_evidence?(record)
  end

  defp ready_evidence?(%{phase: "ready"} = record) do
    successful?(record.checks, record.commands) and record.error == nil and
      record.patch_hash == Hashing.sha256_hex(record.base_commit <> "\n" <> record.patch) and
      Enum.all?(record.checks, &(&1["snapshot_hash"] == record.patch_hash))
  end

  defp ready_evidence?(_record), do: true

  defp executed?(reports, commands),
    do:
      length(reports) == length(commands) and
        Enum.all?(reports, &(is_integer(&1["exit_code"]) and &1["error"] == nil))

  defp successful?(reports, commands),
    do:
      length(reports) == length(commands) and
        Enum.all?(reports, &(&1["exit_code"] == 0 and &1["error"] == nil))

  defp nullable_text?(value, max_bytes), do: is_nil(value) or text?(value, max_bytes)

  defp text?(value, max_bytes),
    do: is_binary(value) and byte_size(value) <= max_bytes and String.valid?(value)
end
