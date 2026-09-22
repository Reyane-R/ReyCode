defmodule ReyCode.Provider.OpenAICompatible.RequestShape do
  @moduledoc """
  Sticky record of the strictest request shape an API endpoint requires.

  Strict OpenAI-compatible servers may reject `stream_options` with HTTP 400.
  After such a rejection the stricter shape is remembered per profile id and a
  durable failure marker tells the ProviderRound retry lifecycle to skip the
  rejected field, including after VM restart. Tool calls are never silently
  dropped — rejecting them fails the invocation loudly — so a remembered shape
  only ever omits `stream_options`.

  Bounded by construction: one small map per profile that actually needed a
  downgrade, held under a single `:persistent_term` key until the VM stops.
  Tests reset the table with `clear/0`.
  """

  alias ReyCode.Provider.OpenAICompatible.Profile

  @type t :: %{tools?: boolean(), stream_options?: boolean()}

  @table_key {__MODULE__, :shapes}

  @spec get(Profile.t()) :: t() | nil
  def get(%Profile{} = profile),
    do: @table_key |> :persistent_term.get(%{}) |> Map.get(profile.id)

  @doc "Remembers the stricter shape established by one capability rejection."
  @spec put(atom(), t()) :: :ok
  def put(profile_id, %{} = shape) when is_atom(profile_id) do
    shapes = Map.put(:persistent_term.get(@table_key, %{}), profile_id, shape)
    :persistent_term.put(@table_key, shapes)
    :ok
  end

  @doc "Drops every remembered shape; capability negotiation rediscovers on demand."
  @spec clear() :: :ok
  def clear do
    :persistent_term.erase(@table_key)
    :ok
  end
end
