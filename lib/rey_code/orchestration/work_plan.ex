defmodule ReyCode.Orchestration.WorkPlan do
  @moduledoc "Bounded deterministic phased progress policy for one Invocation."

  @phase_max_count 16
  @item_max_count 128
  @name_max_bytes 256
  @reason_max_bytes 1_024
  @statuses [:pending, :in_progress, :blocked, :completed, :dropped]

  defmodule Item do
    @moduledoc false
    @enforce_keys [:name, :status, :blocked_reason]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            name: String.t(),
            status: :pending | :in_progress | :blocked | :completed | :dropped,
            blocked_reason: String.t() | nil
          }
  end

  defmodule Phase do
    @moduledoc false
    @enforce_keys [:name, :items]
    defstruct @enforce_keys

    @type t :: %__MODULE__{name: String.t(), items: [Item.t()]}
  end

  @enforce_keys [:phases, :updated_at]
  defstruct @enforce_keys

  @type t :: %__MODULE__{phases: [Phase.t()], updated_at: String.t()}
  @type transition_error ::
          :invalid_plan_arguments
          | :plan_too_large
          | :duplicate_plan_item
          | :unknown_plan_item
          | :invalid_plan_transition

  @doc "Applies one provider-requested transition and deterministic auto-promotion."
  @spec transition(t() | nil, term(), String.t()) :: {:ok, t()} | {:error, transition_error()}
  def transition(_plan, %{"action" => "init", "phases" => phases}, now) do
    with {:ok, phases} <- parse_phases(phases) do
      {:ok, %__MODULE__{phases: promote(phases), updated_at: now}}
    end
  end

  def transition(plan, arguments, now) when is_map(arguments) and not is_nil(plan) do
    action = value(arguments, "action")
    item_name = value(arguments, "item")
    reason = value(arguments, "reason")

    with true <- action in ~w(start done block unblock drop),
         true <- is_binary(item_name) and item_name != "",
         :ok <- valid_reason(action, reason),
         {:ok, phases} <- change_item(plan.phases, item_name, action, reason) do
      {:ok, %__MODULE__{phases: promote(phases), updated_at: now}}
    else
      false -> {:error, :invalid_plan_arguments}
      {:error, _reason} = error -> error
    end
  end

  def transition(_plan, _arguments, _now), do: {:error, :invalid_plan_arguments}

  @doc "Encodes a WorkPlan for durable events and tool results."
  @spec to_wire(t()) :: map()
  def to_wire(plan) do
    %{
      "phases" =>
        Enum.map(plan.phases, fn phase ->
          %{
            "name" => phase.name,
            "items" =>
              Enum.map(phase.items, fn item ->
                %{
                  "name" => item.name,
                  "status" => Atom.to_string(item.status),
                  "blocked_reason" => item.blocked_reason
                }
              end)
          }
        end),
      "updated_at" => plan.updated_at
    }
  end

  @doc "Converts a decoded WorkPlan map into typed records."
  @spec from_map(t() | map() | nil) :: t() | nil
  def from_map(nil), do: nil
  def from_map(%__MODULE__{} = plan), do: plan

  def from_map(plan) when is_map(plan) do
    phases = value(plan, "phases", [])
    updated_at = value(plan, "updated_at", "")

    %__MODULE__{
      phases:
        Enum.map(phases, fn phase ->
          %Phase{
            name: value(phase, "name"),
            items:
              Enum.map(value(phase, "items", []), fn item ->
                %Item{
                  name: value(item, "name"),
                  status: status(value(item, "status")),
                  blocked_reason: value(item, "blocked_reason")
                }
              end)
          }
        end),
      updated_at: updated_at
    }
  end

  @doc "Returns flattened items in phase order."
  @spec items(t()) :: [Item.t()]
  def items(plan), do: Enum.flat_map(plan.phases, & &1.items)

  defp parse_phases(phases) when is_list(phases) and phases != [] do
    with true <- length(phases) <= @phase_max_count,
         {:ok, parsed} <- parse_phase_list(phases),
         items = Enum.flat_map(parsed, & &1.items),
         true <- items != [] and length(items) <= @item_max_count,
         true <- Enum.uniq_by(items, & &1.name) == items do
      {:ok, parsed}
    else
      false -> {:error, :plan_too_large}
      {:error, _reason} = error -> error
    end
  end

  defp parse_phases(_phases), do: {:error, :invalid_plan_arguments}

  defp parse_phase_list(phases) do
    Enum.reduce_while(phases, {:ok, []}, fn phase, {:ok, parsed} ->
      case parse_phase(phase) do
        {:ok, value} -> {:cont, {:ok, parsed ++ [value]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp parse_phase(phase) when is_map(phase) do
    name = value(phase, "name")
    items = value(phase, "items")

    if valid_name?(name) and is_list(items) and items != [] and Enum.all?(items, &valid_name?/1) do
      {:ok,
       %Phase{
         name: name,
         items: Enum.map(items, &%Item{name: &1, status: :pending, blocked_reason: nil})
       }}
    else
      {:error, :invalid_plan_arguments}
    end
  end

  defp parse_phase(_phase), do: {:error, :invalid_plan_arguments}

  defp valid_name?(name),
    do: is_binary(name) and name != "" and byte_size(name) <= @name_max_bytes

  defp valid_reason("block", reason),
    do:
      if(is_binary(reason) and reason != "" and byte_size(reason) <= @reason_max_bytes,
        do: :ok,
        else: {:error, :invalid_plan_arguments}
      )

  defp valid_reason(_action, nil), do: :ok
  defp valid_reason(_action, _reason), do: {:error, :invalid_plan_arguments}

  defp change_item(phases, item_name, action, reason) do
    if Enum.any?(phases, &Enum.any?(&1.items, fn item -> item.name == item_name end)) do
      apply_item_change(phases, item_name, action, reason)
    else
      {:error, :unknown_plan_item}
    end
  end

  defp apply_item_change(phases, item_name, "start", _reason) do
    phases =
      Enum.map(phases, fn phase ->
        items =
          Enum.map(phase.items, fn
            %Item{name: ^item_name, status: status} = item
            when status in [:pending, :in_progress] ->
              %{item | status: :in_progress, blocked_reason: nil}

            %Item{status: :in_progress} = item ->
              %{item | status: :pending}

            item ->
              item
          end)

        %{phase | items: items}
      end)

    if Enum.any?(
         items(%__MODULE__{phases: phases, updated_at: ""}),
         &(&1.name == item_name and &1.status == :in_progress)
       ),
       do: {:ok, phases},
       else: {:error, :invalid_plan_transition}
  end

  defp apply_item_change(phases, item_name, action, reason) do
    target_status =
      %{"done" => :completed, "block" => :blocked, "unblock" => :pending, "drop" => :dropped}[
        action
      ]

    {phases, changed?} =
      Enum.map_reduce(phases, false, fn phase, changed? ->
        {items, phase_changed?} =
          Enum.map_reduce(phase.items, false, fn item, item_changed? ->
            transition_item(item, item_name, action, reason, target_status, item_changed?)
          end)

        {%{phase | items: items}, changed? or phase_changed?}
      end)

    if changed?, do: {:ok, phases}, else: {:error, :invalid_plan_transition}
  end

  defp transition_item(item, item_name, action, reason, target_status, changed?) do
    if item.name == item_name and transition_allowed?(item.status, action) do
      updated = %{
        item
        | status: target_status,
          blocked_reason: if(action == "block", do: reason, else: nil)
      }

      {updated, true}
    else
      {item, changed?}
    end
  end

  defp transition_allowed?(status, "done"), do: status == :in_progress
  defp transition_allowed?(status, "block"), do: status in [:pending, :in_progress]
  defp transition_allowed?(status, "unblock"), do: status == :blocked
  defp transition_allowed?(status, "drop"), do: status in [:pending, :in_progress, :blocked]
  defp transition_allowed?(_status, _action), do: false

  defp promote(phases) do
    if Enum.any?(phases, &Enum.any?(&1.items, fn item -> item.status == :in_progress end)) do
      phases
    else
      promote_first_pending(phases, false)
    end
  end

  defp promote_first_pending([], _promoted?), do: []

  defp promote_first_pending([phase | rest], false) do
    {items, promoted?} = promote_items(phase.items, false)
    [%{phase | items: items} | promote_first_pending(rest, promoted?)]
  end

  defp promote_first_pending([phase | rest], true),
    do: [phase | promote_first_pending(rest, true)]

  defp promote_items([], promoted?), do: {[], promoted?}

  defp promote_items([%Item{status: :pending} = item | rest], false),
    do: {[%{item | status: :in_progress} | rest], true}

  defp promote_items([item | rest], promoted?) do
    {tail, promoted?} = promote_items(rest, promoted?)
    {[item | tail], promoted?}
  end

  defp status(value) when value in @statuses, do: value
  defp status(value) when is_binary(value), do: String.to_existing_atom(value)

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, String.to_existing_atom(key), default))
end
