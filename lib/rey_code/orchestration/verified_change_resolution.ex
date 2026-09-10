defmodule ReyCode.Orchestration.VerifiedChangeResolution do
  @moduledoc """
  One Owner decision bound to immutable retained verification evidence.

  Requested is durable intent, not proof of mutation. Interrupted requests become
  indeterminate and only explicit read-only reconciliation may settle them.
  Terminal decisions cannot be replaced or retried. Discard retains both evidence
  and workspace; filesystem cleanup is a separate stopped-owner operation.
  """

  alias ReyCode.Orchestration.VerifiedChange

  @fields ~w(id change_id patch_hash decision status error)a
  @statuses [:requested, :applied, :discarded, :failed, :indeterminate]
  @decisions [:apply, :discard]
  defstruct @fields

  @type t :: %__MODULE__{
          id: String.t(),
          change_id: String.t(),
          patch_hash: String.t() | nil,
          decision: :apply | :discard,
          status: :requested | :applied | :discarded | :failed | :indeterminate,
          error: String.t() | nil
        }

  @spec from_wire(term()) :: {:ok, t()} | {:error, atom()}
  def from_wire(wire) when is_map(wire) and not is_struct(wire) do
    with true <- Enum.sort(Map.keys(wire)) == Enum.sort(Enum.map(@fields, &Atom.to_string/1)),
         true <- text?(wire["id"]) and text?(wire["change_id"]),
         true <- is_nil(wire["patch_hash"]) or text?(wire["patch_hash"]),
         decision when not is_nil(decision) <-
           Enum.find(@decisions, &(Atom.to_string(&1) == wire["decision"])),
         status when not is_nil(status) <-
           Enum.find(@statuses, &(Atom.to_string(&1) == wire["status"])),
         true <- valid_result?(decision, status, wire["error"]) do
      {:ok,
       %__MODULE__{
         id: wire["id"],
         change_id: wire["change_id"],
         patch_hash: wire["patch_hash"],
         decision: decision,
         status: status,
         error: wire["error"]
       }}
    else
      _ -> {:error, :invalid_verified_change_resolution}
    end
  end

  def from_wire(_), do: {:error, :invalid_verified_change_resolution}

  @spec to_wire(t()) :: map()
  def to_wire(record) do
    Map.new(@fields, fn field ->
      value = Map.fetch!(record, field)

      {Atom.to_string(field),
       if(field in [:decision, :status], do: Atom.to_string(value), else: value)}
    end)
  end

  @spec from_map(nil | map()) :: nil | t()
  def from_map(nil), do: nil

  def from_map(record) do
    {:ok, record} = record |> to_wire() |> from_wire()
    record
  end

  @doc "Validates evidence identity and terminal eligibility, including blocked Discard."
  @spec bound?(t(), VerifiedChange.t() | nil) :: boolean()
  def bound?(record, %VerifiedChange{} = change) do
    record.change_id == change.id and record.patch_hash == change.patch_hash and
      (change.phase == "ready" or (change.phase == "blocked" and record.decision == :discard))
  end

  def bound?(_, _), do: false

  @spec transition(nil | t(), t()) :: :ok | {:error, atom()}
  def transition(nil, %__MODULE__{status: :requested}), do: :ok

  def transition(%__MODULE__{} = previous, %__MODULE__{} = record) do
    immutable = [:id, :change_id, :patch_hash, :decision]

    allowed =
      previous.status in [:requested, :indeterminate] and
        record.status in [:applied, :discarded, :failed, :indeterminate]

    if allowed and Map.take(previous, immutable) == Map.take(record, immutable),
      do: :ok,
      else: {:error, :invalid_verified_change_resolution_transition}
  end

  def transition(_, _), do: {:error, :invalid_verified_change_resolution_transition}

  defp valid_result?(_, status, error) when status in [:failed, :indeterminate],
    do: text?(error, 4000)

  defp valid_result?(:apply, :applied, nil), do: true
  defp valid_result?(:discard, :discarded, nil), do: true
  defp valid_result?(_, :requested, nil), do: true
  defp valid_result?(_, _, _), do: false

  defp text?(value, max_bytes \\ 4096),
    do: is_binary(value) and byte_size(value) in 1..max_bytes and String.valid?(value)
end
