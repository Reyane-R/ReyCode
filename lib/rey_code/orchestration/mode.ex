defmodule ReyCode.Orchestration.Mode do
  @moduledoc """
  The closed contract of supported orchestration modes.

  One source owns every mode ID, its stable wire value, display label,
  and workflow implementation. Engine admission, workflow dispatch,
  projection encoding/decoding, and public type specs consume this
  module rather than repeating the enumeration. Adding, renaming, or
  retiring a mode is a single-list edit; unknown values are rejected at
  every boundary instead of surviving to fail later in dispatch.
  """

  alias ReyCode.Orchestration.Workflow.{Compare, Debate, Direct, Squad}

  @enforce_keys [:id, :wire, :label, :workflow]
  defstruct [:id, :wire, :label, :workflow]

  @type id ::
          :direct | :delegate | :compare | :debate | :squad

  # IDs that remain decodable from durable events after leaving the registry.
  @type durable_id :: id() | :fan_out

  @type t :: %__MODULE__{
          id: id(),
          wire: String.t(),
          label: String.t(),
          workflow: module()
        }

  # Plain maps here; struct construction happens in all/0 because module-body
  # evaluation cannot access %__MODULE__{} before the module is compiled.
  @mode_data [
    %{id: :direct, wire: "direct", label: "Direct", workflow: Direct},
    %{id: :delegate, wire: "delegate", label: "Delegate", workflow: Direct},
    %{id: :compare, wire: "compare", label: "Compare", workflow: Compare},
    %{id: :debate, wire: "debate", label: "Debate", workflow: Debate},
    %{id: :squad, wire: "squad", label: "Squad", workflow: Squad}
  ]

  @by_id Map.new(@mode_data, &{&1.id, &1})
  @by_wire Map.new(@mode_data, &{&1.wire, &1})

  # Retired modes lost their workflow and their place in admission, dispatch,
  # and the registry above, but historical events written before retirement
  # still carry their wire value. The data below is the entire remaining
  # footprint: enough identity to replay and render old turns inertly.
  @retired_mode_data [
    %{id: :fan_out, wire: "fan_out", label: "Fan out"}
  ]

  @by_retired_id Map.new(@retired_mode_data, &{&1.id, &1})
  @by_retired_wire Map.new(@retired_mode_data, &{&1.wire, &1})

  @doc "Returns every registered mode in canonical order."
  @spec all() :: [t()]
  def all, do: Enum.map(@mode_data, &struct!(__MODULE__, &1))

  @doc "Returns every registered mode ID in canonical order."
  @spec ids() :: [id()]
  def ids, do: Enum.map(@mode_data, & &1.id)

  @spec known?(term()) :: boolean()
  def known?(value) when is_atom(value), do: Map.has_key?(@by_id, value)
  def known?(_other), do: false

  @doc "Whether an ID is a replay-only retired mode."
  @spec retired?(term()) :: boolean()
  def retired?(value) when is_atom(value), do: Map.has_key?(@by_retired_id, value)
  def retired?(_other), do: false

  @doc "Returns the stable wire value for a mode ID."
  @spec wire(id()) :: String.t()
  def wire(id), do: fetch!(id).wire

  @doc """
  Returns the display label for a mode ID.

  Retired IDs render with a legacy suffix so historical turns keep a
  readable label; live code must never admit them as new turns.
  """
  @spec label(durable_id()) :: String.t()
  def label(:fan_out), do: Map.fetch!(@by_retired_id, :fan_out).label <> " (legacy)"

  def label(id), do: fetch!(id).label

  @doc "Returns the workflow implementation responsible for a mode ID."
  @spec workflow(id()) :: module()
  def workflow(id), do: fetch!(id).workflow

  @doc """
  Decodes a durable or user-supplied value into a mode ID.

  Wire strings and already-decoded IDs are accepted; anything else —
  including unknown atoms that would later fail in dispatch — is
  rejected with a tagged error.
  """
  @spec decode(term()) :: {:ok, id()} | {:error, :invalid_mode}
  def decode(value)

  def decode(value) when is_binary(value) do
    case Map.fetch(@by_wire, value) do
      {:ok, mode} -> {:ok, mode.id}
      :error -> {:error, :invalid_mode}
    end
  end

  def decode(value) when is_atom(value) do
    if known?(value), do: {:ok, value}, else: {:error, :invalid_mode}
  end

  def decode(_other), do: {:error, :invalid_mode}

  @doc "Returns the wire values of retired modes that remain valid in durable events."
  @spec retired_wire_values() :: [String.t()]
  def retired_wire_values, do: Enum.map(@retired_mode_data, & &1.wire)

  @doc """
  Decodes a durable stored value into a mode ID with legacy tolerance.

  Behaves like decode/1 except that values written before a mode was
  retired still decode — to an inert marker ID. Admission (known?/1) and
  dispatch (workflow/1) never accept the marker; only event application
  and rendering may consume it. Anything else fails closed exactly like
  decode/1.
  """
  @spec decode_durable(term()) :: {:ok, durable_id()} | {:error, :invalid_mode}
  def decode_durable(value) when is_binary(value) do
    case decode(value) do
      {:ok, id} ->
        {:ok, id}

      {:error, :invalid_mode} ->
        case Map.fetch(@by_retired_wire, value) do
          {:ok, mode} -> {:ok, mode.id}
          :error -> {:error, :invalid_mode}
        end
    end
  end

  def decode_durable(:fan_out), do: {:ok, :fan_out}

  def decode_durable(value) when is_atom(value), do: decode(value)

  def decode_durable(_other), do: {:error, :invalid_mode}

  defp fetch!(id) do
    case Map.fetch(@by_id, id) do
      {:ok, mode} -> mode
      :error -> raise ArgumentError, "unknown orchestration mode #{inspect(id)}"
    end
  end
end
