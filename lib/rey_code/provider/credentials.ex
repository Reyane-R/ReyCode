defmodule ReyCode.Provider.Credentials do
  @moduledoc """
  Resolves provider API keys without durable storage.

  Resolution order: a key entered during this run, the process environment,
  then the platform keychain. Keychain values are cached in process memory
  after the first read. Secrets never enter events, projections, logs,
  diagnostics, or tool subprocess environments; only provider HTTP requests
  carry them. The server holds no durable state — a restart drops session
  keys and rebuilds the keychain cache on demand.
  """

  use GenServer

  alias ReyCode.Provider.Keychain

  @typedoc "Credential source, in resolution order."
  @type source :: :session | :environment | :keychain

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.fetch(opts, :name) do
      :error -> GenServer.start_link(__MODULE__, [], name: __MODULE__)
      {:ok, name} -> GenServer.start_link(__MODULE__, [], name: name)
    end
  end

  @doc """
  Returns the credential for one key environment name with its source, or
  `:error` when no source resolves. Blank environment values are missing.
  """
  @spec fetch(String.t() | nil, GenServer.server()) ::
          {:ok, String.t(), source()} | :error | {:error, term()}
  def fetch(key_env, server \\ __MODULE__)

  def fetch(nil, _server), do: :error

  def fetch(key_env, server) do
    call(server, {:fetch, key_env})
  end

  @doc "Whether any source can currently resolve a credential for key_env."
  @spec known?(String.t() | nil, GenServer.server()) :: boolean()
  def known?(key_env, server \\ __MODULE__),
    do: match?({:ok, _key, _source}, fetch(key_env, server))

  @doc "Returns the credential source, nil when missing, or :unavailable when the service cannot be reached."
  @spec source(String.t() | nil, GenServer.server()) :: source() | nil | :unavailable
  def source(key_env, server \\ __MODULE__) do
    case fetch(key_env, server) do
      {:ok, _key, source} -> source
      :error -> nil
      {:error, _reason} -> :unavailable
    end
  end

  @doc """
  Records a key entered this run (highest precedence) and, when `persist?`,
  stores it in the platform keychain. The session key takes effect even when
  persistence fails; the return reports the persistence outcome.
  """
  @spec remember(String.t(), String.t(), boolean(), GenServer.server()) ::
          :ok | {:error, Keychain.error() | atom()}
  def remember(key_env, key, persist? \\ true, server \\ __MODULE__)
      when is_binary(key_env) and key_env != "" and is_binary(key) do
    call(server, {:remember, key_env, key, persist?})
  end

  @doc """
  Removes the session and stored credential for key_env. Idempotent; callers
  should refresh discovery afterwards.
  """
  @spec remove(String.t(), GenServer.server()) :: :ok | {:error, term()}
  def remove(key_env, server \\ __MODULE__) when is_binary(key_env) and key_env != "",
    do: call(server, {:remove, key_env})

  @impl true
  def init([]), do: {:ok, %{session: %{}, keychain: %{}}}

  @impl true
  def handle_call({:fetch, key_env}, _from, state) do
    {result, state} = resolve(key_env, state)
    {:reply, result, state}
  end

  def handle_call({:remember, key_env, key, persist?}, _from, state) do
    outcome =
      if persist? do
        Keychain.store(key_env, key)
      else
        :ok
      end

    state =
      %{state | session: Map.put(state.session, key_env, key)}
      |> cache_keychain(key_env, outcome)

    {:reply, outcome, state}
  end

  def handle_call({:remove, key_env}, _from, state) do
    _outcome = Keychain.delete(key_env)

    state = %{
      state
      | session: Map.delete(state.session, key_env),
        keychain: Map.delete(state.keychain, key_env)
    }

    {:reply, :ok, state}
  end

  # Session keys win over the environment so a key entered in the wizard can
  # replace an exported value without a restart; an explicit export still wins
  # over the keychain so operator shells keep authority across restarts.
  defp resolve(key_env, state) do
    cond do
      key = Map.get(state.session, key_env) ->
        {{:ok, key, :session}, state}

      present?(System.get_env(key_env)) ->
        {{:ok, System.get_env(key_env), :environment}, state}

      true ->
        {key, state} = cached_keychain(key_env, state)
        if key, do: {{:ok, key, :keychain}, state}, else: {:error, state}
    end
  end

  defp cached_keychain(key_env, state) do
    case Map.fetch(state.keychain, key_env) do
      {:ok, key} ->
        {key, state}

      :error ->
        key =
          case Keychain.read(key_env) do
            {:ok, key} -> key
            :error -> nil
          end

        {key, %{state | keychain: Map.put(state.keychain, key_env, key)}}
    end
  end

  defp cache_keychain(state, _key_env, :ok), do: state

  defp cache_keychain(state, key_env, {:error, _reason}) do
    # A failed store leaves the previous keychain value authoritative; drop
    # any cached value so the next fetch re-reads real storage.
    %{state | keychain: Map.delete(state.keychain, key_env)}
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""

  # Test harnesses and degraded startups may run provider code without this
  # server; resolution then falls back to the environment exactly as before
  # session keys existed. This path is read-only and adds no authority.
  defp call(server, request) do
    GenServer.call(server, request)
  catch
    :exit, {:noproc, _} -> stateless(request)
  end

  defp stateless({:fetch, key_env}) do
    if present?(System.get_env(key_env)) do
      {:ok, System.get_env(key_env), :environment}
    else
      :error
    end
  end

  # Without the server there is no session layer; a remembered key can still
  # reach the platform keychain, and removal stays idempotent.
  defp stateless({:remember, key_env, key, persist?}) do
    if persist? do
      Keychain.store(key_env, key)
    else
      {:error, :keychain_unsupported}
    end
  end

  defp stateless({:remove, key_env}), do: Keychain.delete(key_env)
end
