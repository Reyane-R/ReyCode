defmodule ReyCode.Orchestration.Delegation do
  @moduledoc """
  Pure policy for agent-initiated Delegation and DelegationWaves.

  The high-tier caller decides when to delegate; this module decides whether a
  `spawn_task` or `spawn_tasks` call is admissible: strict shapes, exact-name
  task-Participant addressing, frozen shared/output contracts, persisted depth,
  and explicit per-caller caps. Every rejection is deterministic and recorded;
  uncertainty never opens a child Invocation.
  """

  alias ReyCode.Orchestration.{Invocation, Participant, Projection}
  alias ReyCode.Provider.TextBuffer

  @tool_name "spawn_task"
  @batch_tool_name "spawn_tasks"

  @max_children_per_invocation 8
  @brief_max_bytes 16_384
  @report_max_bytes 16_384
  @schema_max_bytes 16_384
  @schema_max_depth 8

  defmodule Plan do
    @moduledoc false
    @enforce_keys [
      :participant,
      :brief,
      :output_schema,
      :isolate?,
      :shared_context,
      :peer_names,
      :detach?
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            participant: ReyCode.Orchestration.Participant.t(),
            brief: String.t(),
            output_schema: map() | nil,
            isolate?: boolean(),
            shared_context: String.t(),
            peer_names: [String.t()],
            detach?: boolean()
          }
  end

  defmodule BatchPlan do
    @moduledoc false
    @enforce_keys [:workers, :integrator, :shared_context]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            workers: [Plan.t()],
            integrator: Plan.t() | nil,
            shared_context: String.t()
          }
  end

  @type bounds :: %{max_children: pos_integer(), brief_max_bytes: pos_integer()}

  @type rejection ::
          :invalid_arguments
          | :brief_too_large
          | :delegation_depth_exceeded
          | :child_cap_exceeded
          | :unknown_agent
          | :ambiguous_agent
          | :duplicate_agent
          | :primary_target
          | :delegation_unsupported_in_squad
  @spec tool_name() :: String.t()
  def tool_name, do: @tool_name
  @spec batch_tool_name() :: String.t()
  def batch_tool_name, do: @batch_tool_name

  @doc "Built-in delegation bounds; configuration may only lower or raise them explicitly."
  @spec default_bounds() :: bounds()
  def default_bounds,
    do: %{max_children: @max_children_per_invocation, brief_max_bytes: @brief_max_bytes}

  @doc """
  Validates one `spawn_task` call against addressing rules and bounds.

  Arguments must be `%{"agent" => binary, "brief" => binary}`; the agent name
  matches exactly one room participant of kind `:task`. Primary participants
  and unknown names reject without spawning.
  """
  @spec authorize(Invocation.t(), term(), Projection.t(), bounds()) ::
          {:ok, Plan.t()} | {:error, rejection()}
  def authorize(invocation, arguments, projection, bounds) do
    with {:ok, agent, brief, output_schema, isolate?, detach?} <- parse_arguments(arguments),
         :ok <- check_mode(invocation, projection),
         :ok <- check_brief(brief, bounds.brief_max_bytes),
         :ok <- check_schema(output_schema),
         :ok <- check_depth(invocation),
         :ok <- check_child_cap(invocation, 1, bounds.max_children),
         {:ok, participant} <-
           resolve_participant(projection.rooms[invocation.room_id], agent) do
      {:ok,
       %Plan{
         participant: participant,
         brief: brief,
         output_schema: output_schema,
         isolate?: isolate?,
         shared_context: "",
         peer_names: [],
         detach?: detach?
       }}
    end
  end

  @doc "Validates one bounded `spawn_tasks` DelegationWave."
  @spec authorize_batch(Invocation.t(), term(), Projection.t(), bounds()) ::
          {:ok, BatchPlan.t()} | {:error, rejection()}
  def authorize_batch(invocation, arguments, projection, bounds) do
    with {:ok, shared_context, task_arguments, integrator_arguments} <-
           parse_batch_arguments(arguments),
         :ok <- check_mode(invocation, projection),
         :ok <- check_depth(invocation),
         :ok <- check_brief(shared_context, bounds.brief_max_bytes),
         :ok <-
           check_child_cap(
             invocation,
             length(task_arguments) + if(integrator_arguments, do: 1, else: 0),
             bounds.max_children
           ),
         {:ok, workers} <-
           authorize_batch_tasks(task_arguments, invocation, projection, bounds, shared_context),
         {:ok, integrator} <-
           authorize_integrator(
             integrator_arguments,
             invocation,
             projection,
             bounds,
             shared_context
           ),
         :ok <- unique_participants(workers, integrator) do
      peer_names = Enum.map(workers, & &1.participant.name)
      workers = Enum.map(workers, &%{&1 | peer_names: peer_names})
      integrator = if integrator, do: %{integrator | peer_names: peer_names}, else: nil
      {:ok, %BatchPlan{workers: workers, integrator: integrator, shared_context: shared_context}}
    end
  end

  @doc "Builds the child task-agent system prompt carrying its delegated contract."
  @spec child_system_prompt(Plan.t()) :: String.t()
  def child_system_prompt(%Plan{} = plan) do
    schema_instruction =
      if plan.output_schema,
        do:
          "\n\nReturn only JSON matching this output schema:\n" <>
            Jason.encode!(plan.output_schema),
        else: ""

    shared_context =
      if plan.shared_context == "",
        do: "",
        else: "\n\nShared Wave context:\n#{plan.shared_context}"

    peer_context =
      case Enum.reject(plan.peer_names, &(&1 == plan.participant.name)) do
        [] ->
          ""

        peers ->
          "\n\nActive Wave peers: #{Enum.join(peers, ", ")}. " <>
            "Use send_peer with an exact peer name for bounded coordination."
      end

    "You are the #{plan.participant.name} task agent. " <>
      "Standing responsibility: #{plan.participant.perspective}. " <>
      "Complete only the delegated task and report the result.\n\n" <>
      "Delegated task:\n#{plan.brief}" <>
      shared_context <> peer_context <> schema_instruction
  end

  @doc """
  Builds the structured tool-run report delivered to the parent conversation.

  The map follows the durable tool-result envelope (`output`/`error`,
  `truncated`, `metadata`) so the recorded round re-encodes it verbatim; the
  child's usage rides in `metadata`.
  """
  @spec report(boolean(), String.t() | nil, map() | nil) :: map()
  def report(ok?, output, usage) do
    truncated? = is_binary(output) and byte_size(output) > @report_max_bytes
    text = bounded(output)

    if ok? do
      %{
        "output" => text || "",
        "truncated" => truncated?,
        "metadata" => %{"usage" => usage || %{}}
      }
    else
      %{
        "error" => text || "delegation failed",
        "truncated" => truncated?,
        "metadata" => %{"usage" => usage || %{}}
      }
    end
  end

  defp parse_arguments(arguments) when is_map(arguments) do
    allowed = ~w(agent brief output_schema isolate detach)
    keys = arguments |> Map.keys() |> Enum.map(&to_string/1)
    agent = argument(arguments, "agent")
    brief = argument(arguments, "brief")
    output_schema = argument(arguments, "output_schema")
    isolate? = argument(arguments, "isolate", false)
    detach? = argument(arguments, "detach", false)

    if Enum.all?(keys, &(&1 in allowed)) and is_binary(agent) and
         is_binary(brief) and (is_nil(output_schema) or is_map(output_schema)) and
         is_boolean(isolate?) and is_boolean(detach?) do
      {:ok, agent, brief, output_schema, isolate?, detach?}
    else
      {:error, :invalid_arguments}
    end
  end

  defp parse_arguments(_arguments), do: {:error, :invalid_arguments}

  defp argument(arguments, key, default \\ nil),
    do: Map.get(arguments, key, Map.get(arguments, argument_key(key), default))

  defp argument_key("agent"), do: :agent
  defp argument_key("brief"), do: :brief
  defp argument_key("output_schema"), do: :output_schema
  defp argument_key("isolate"), do: :isolate
  defp argument_key("detach"), do: :detach
  defp argument_key("shared_context"), do: :shared_context
  defp argument_key("tasks"), do: :tasks
  defp argument_key("integrator"), do: :integrator

  defp parse_batch_arguments(arguments) when is_map(arguments) do
    allowed = ~w(shared_context tasks integrator)
    keys = arguments |> Map.keys() |> Enum.map(&to_string/1)
    shared_context = argument(arguments, "shared_context", "")
    tasks = argument(arguments, "tasks")
    integrator = argument(arguments, "integrator")

    if Enum.all?(keys, &(&1 in allowed)) and is_binary(shared_context) and
         is_list(tasks) and tasks != [] and Enum.all?(tasks, &is_map/1) and
         (is_nil(integrator) or is_map(integrator)) do
      {:ok, shared_context, tasks, integrator}
    else
      {:error, :invalid_arguments}
    end
  end

  defp parse_batch_arguments(_arguments), do: {:error, :invalid_arguments}

  defp authorize_batch_tasks(arguments, invocation, projection, bounds, shared_context) do
    Enum.reduce_while(arguments, {:ok, []}, fn task, {:ok, plans} ->
      case authorize_batch_task(task, invocation, projection, bounds, shared_context) do
        {:ok, plan} -> {:cont, {:ok, plans ++ [plan]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp authorize_integrator(nil, _invocation, _projection, _bounds, _shared_context),
    do: {:ok, nil}

  defp authorize_integrator(arguments, invocation, projection, bounds, shared_context),
    do: authorize_batch_task(arguments, invocation, projection, bounds, shared_context)

  defp authorize_batch_task(arguments, invocation, projection, bounds, shared_context) do
    with {:ok, agent, brief, output_schema, isolate?, false} <- parse_arguments(arguments),
         :ok <- check_brief(brief, bounds.brief_max_bytes),
         :ok <- check_schema(output_schema),
         {:ok, participant} <-
           resolve_participant(projection.rooms[invocation.room_id], agent) do
      {:ok,
       %Plan{
         participant: participant,
         brief: brief,
         output_schema: output_schema,
         isolate?: isolate?,
         shared_context: shared_context,
         peer_names: [],
         detach?: false
       }}
    else
      {:ok, _agent, _brief, _schema, _isolate, true} -> {:error, :invalid_arguments}
      {:error, _reason} = error -> error
    end
  end

  defp unique_participants(workers, integrator) do
    names = Enum.map(workers ++ List.wrap(integrator), & &1.participant.name)
    if Enum.uniq(names) == names, do: :ok, else: {:error, :duplicate_agent}
  end

  defp check_schema(nil), do: :ok

  defp check_schema(schema) do
    if byte_size(Jason.encode!(schema)) <= @schema_max_bytes,
      do: validate_schema_shape(schema, 0),
      else: {:error, :output_schema_too_large}
  end

  defp validate_schema_shape(_schema, depth) when depth > @schema_max_depth,
    do: {:error, :output_schema_too_deep}

  defp validate_schema_shape(schema, depth) when is_map(schema) do
    type = Map.get(schema, "type", Map.get(schema, :type))
    properties = Map.get(schema, "properties", Map.get(schema, :properties, %{}))
    items = Map.get(schema, "items", Map.get(schema, :items))

    cond do
      type not in [nil, "object", "array", "string", "number", "integer", "boolean", "null"] ->
        {:error, :unsupported_output_schema}

      not is_map(properties) ->
        {:error, :invalid_output_schema}

      true ->
        nested = Map.values(properties) ++ if(is_map(items), do: [items], else: [])
        validate_schema_children(nested, depth + 1)
    end
  end

  defp validate_schema_shape(_schema, _depth), do: {:error, :invalid_output_schema}

  defp validate_schema_children(children, depth) do
    Enum.reduce_while(children, :ok, fn child, :ok ->
      validation_step(validate_schema_shape(child, depth))
    end)
  end

  @doc "Decodes and validates one delegated output against its frozen schema."
  @spec validate_output(String.t() | nil, map() | nil) ::
          {:ok, term()} | {:error, atom()}
  def validate_output(output, nil), do: {:ok, output || ""}

  def validate_output(output, schema) when is_binary(output) do
    with {:ok, value} <- Jason.decode(output),
         :ok <- validate_value(value, schema, 0) do
      {:ok, value}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :delegation_output_not_json}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_output(_output, _schema), do: {:error, :delegation_output_missing}

  defp validate_value(_value, _schema, depth) when depth > @schema_max_depth,
    do: {:error, :delegation_output_too_deep}

  defp validate_value(value, schema, depth) do
    type = Map.get(schema, "type", Map.get(schema, :type))

    with :ok <- validate_type(value, type),
         :ok <- validate_required(value, schema),
         :ok <- validate_properties(value, schema, depth) do
      validate_items(value, schema, depth)
    end
  end

  defp validate_type(_value, nil), do: :ok
  defp validate_type(value, "object") when is_map(value), do: :ok
  defp validate_type(value, "array") when is_list(value), do: :ok
  defp validate_type(value, "string") when is_binary(value), do: :ok
  defp validate_type(value, "number") when is_number(value), do: :ok
  defp validate_type(value, "integer") when is_integer(value), do: :ok
  defp validate_type(value, "boolean") when is_boolean(value), do: :ok
  defp validate_type(nil, "null"), do: :ok
  defp validate_type(_value, _type), do: {:error, :delegation_output_type_mismatch}

  defp validate_required(value, schema) when is_map(value) do
    required = Map.get(schema, "required", Map.get(schema, :required, []))

    if is_list(required) and Enum.all?(required, &Map.has_key?(value, &1)),
      do: :ok,
      else: {:error, :delegation_output_missing_required}
  end

  defp validate_required(_value, _schema), do: :ok

  defp validate_properties(value, schema, depth) when is_map(value) do
    properties = Map.get(schema, "properties", Map.get(schema, :properties, %{}))

    Enum.reduce_while(properties, :ok, fn property, :ok ->
      validate_property(property, value, depth)
    end)
  end

  defp validate_properties(_value, _schema, _depth), do: :ok

  defp validate_property({key, child_schema}, value, depth) do
    case Map.fetch(value, to_string(key)) do
      :error -> {:cont, :ok}
      {:ok, child} -> validation_step(validate_value(child, child_schema, depth + 1))
    end
  end

  defp validate_items(value, schema, depth) when is_list(value) do
    case Map.get(schema, "items", Map.get(schema, :items)) do
      nil ->
        :ok

      item_schema ->
        Enum.reduce_while(value, :ok, fn item, :ok ->
          validation_step(validate_value(item, item_schema, depth + 1))
        end)
    end
  end

  defp validate_items(_value, _schema, _depth), do: :ok

  defp validation_step(:ok), do: {:cont, :ok}
  defp validation_step({:error, _reason} = error), do: {:halt, error}

  defp check_mode(invocation, projection) do
    if projection.turns[invocation.turn_id].mode == :squad,
      do: {:error, :delegation_unsupported_in_squad},
      else: :ok
  end

  defp check_brief(brief, brief_max_bytes) do
    if byte_size(brief) > brief_max_bytes,
      do: {:error, :brief_too_large},
      else: :ok
  end

  # Depth is persisted per invocation, so a child calling spawn_task is denied
  # deterministically across restarts, not per process.
  defp check_depth(invocation) do
    if invocation.delegation_depth >= 1,
      do: {:error, :delegation_depth_exceeded},
      else: :ok
  end

  defp check_child_cap(invocation, requested_count, max_children) do
    existing_count =
      invocation.tool_run_order
      |> List.wrap()
      |> Enum.reduce(0, fn run_id, count ->
        count + delegated_child_count(Map.get(invocation.tool_runs, run_id))
      end)

    if existing_count + requested_count > max_children,
      do: {:error, :child_cap_exceeded},
      else: :ok
  end

  defp delegated_child_count(%{tool: tool} = run)
       when tool in [@tool_name, @batch_tool_name] do
    length(run_child_ids(run))
  end

  defp delegated_child_count(_run), do: 0

  defp run_child_ids(%{child_invocation_ids: [], child_invocation_id: child_id}),
    do: List.wrap(child_id)

  defp run_child_ids(run), do: run.child_invocation_ids

  defp resolve_participant(nil, _agent), do: {:error, :unknown_agent}

  defp resolve_participant(room, agent) do
    case Enum.filter(room.participants, &(&1.name == agent)) do
      [] -> {:error, :unknown_agent}
      [%Participant{kind: :task} = participant] -> {:ok, participant}
      [%Participant{}] -> {:error, :primary_target}
      [_single] -> {:error, :unknown_agent}
      _multiple -> {:error, :ambiguous_agent}
    end
  end

  defp bounded(nil), do: nil

  defp bounded(text) when is_binary(text),
    do: TextBuffer.truncate_utf8(text, @report_max_bytes)

  defp bounded(other), do: other
end
