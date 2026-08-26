defmodule ReyCode.Provider.OpenAICompatible.RequestShape do
  @moduledoc """
  Sticky record of the strictest request shape an API endpoint accepted.

  Strict OpenAI-compatible servers may reject `stream_options` with HTTP 400.
  After such a rejection the provider retries once without the flagged
  feature, and the working shape is remembered per profile id so later rounds
  skip the rejected field instead of paying a failed round trip every time.
  Tool calls are never silently dropped — rejecting them fails the invocation
  loudly — so a remembered shape only ever omits `stream_options`.

  Bounded by construction: one small map per profile that actually needed a
  downgrade, held in `:persistent_term` until the VM stops. Tests reset the
  table with `clear/0`.
  """

  alias ReyCode.Provider.OpenAICompatible.Profile

  @type t :: %{tools?: boolean(), stream_options?: boolean()}

  @index_key {__MODULE__, :index}

  @spec get(Profile.t()) :: t() | nil
  def get(%Profile{} = profile), do: :persistent_term.get(key(profile.id), nil)

  @doc "Remembers the working shape for one profile after a successful downgrade."
  @spec put(atom(), t()) :: :ok
  def put(profile_id, %{} = shape) when is_atom(profile_id) do
    :persistent_term.put(key(profile_id), shape)
    :persistent_term.put(@index_key, Enum.uniq([profile_id | registered()]))
    :ok
  end

  @doc "Drops every remembered shape; the downgrade ladder rediscovers on demand."
  @spec clear() :: :ok
  def clear do
    Enum.each(registered(), &:persistent_term.erase(key(&1)))
    :persistent_term.erase(@index_key)
    :ok
  end

  defp registered, do: :persistent_term.get(@index_key, [])
  defp key(profile_id), do: {__MODULE__, profile_id}
end
