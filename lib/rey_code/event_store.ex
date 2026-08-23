defmodule ReyCode.EventStore do
  @moduledoc """
  A single-writer transactional event store backed by SQLite.

  Legacy schema-v2 NDJSON logs are no longer written; point `:legacy_path`
  at one to import its events once, before the SQLite store has any of its
  own. A focused reader for that format lives in
  `ReyCode.EventStore.LegacyNDJSON`.
  """

  use GenServer

  alias ReyCode.Event
  alias ReyCode.EventStore.{LegacyNDJSON, SQLite}
  alias ReyCode.Security.CanonicalPath

  @type option ::
          {:name, GenServer.name() | nil}
          | {:path, Path.t()}
          | {:legacy_path, Path.t()}
  @type entry :: {Event.type(), map(), keyword()}

  @retired_extensions [".ndjson", ".jsonl"]

  @doc "Starts the single-writer event store for the configured path."
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Loads all durable events in global sequence order."
  @spec load(GenServer.server()) :: [Event.t()]
  def load(server \\ __MODULE__), do: GenServer.call(server, :load, :infinity)

  @doc "Loads the latest projection checkpoint and the events needed to resume replay."
  @spec load_projection(GenServer.server()) :: {:ok, map() | nil, [Event.t()]} | {:error, term()}
  def load_projection(server \\ __MODULE__) do
    GenServer.call(server, :load_projection, :infinity)
  end

  @doc "Persists a projection checkpoint."
  @spec checkpoint(map(), GenServer.server()) :: :ok | {:error, term()}
  def checkpoint(projection, server \\ __MODULE__) do
    GenServer.call(server, {:checkpoint, projection}, :infinity)
  end

  @doc "Appends one durable event and returns its assigned event record."
  @spec append(Event.type(), map(), GenServer.server(), keyword()) ::
          {:ok, Event.t()} | {:error, term()}
  def append(type, data, server \\ __MODULE__, metadata \\ []) do
    case append_many([{type, data, metadata}], server) do
      {:ok, [event]} -> {:ok, event}
      {:error, _reason} = error -> error
    end
  end

  @doc "Atomically appends a batch, optionally enforcing an expected global sequence."
  @spec append_many([entry()], GenServer.server(), keyword()) ::
          {:ok, [Event.t()]} | {:error, term()}
  def append_many(entries, server \\ __MODULE__, opts \\ []) do
    GenServer.call(server, {:append_many, entries, opts}, :infinity)
  end

  @doc "Checks the store's integrity and returns verification details."
  @spec verify(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def verify(server \\ __MODULE__), do: GenServer.call(server, :verify, :infinity)

  @doc "Creates a consistent backup at a destination that must not already exist."
  @spec backup(Path.t(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def backup(destination, server \\ __MODULE__) do
    GenServer.call(server, {:backup, destination}, :infinity)
  end

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)

    with {:ok, path} <- writable_path(path),
         :ok <- reject_retired_backend(opts) do
      start_owned(Path.expand(path), opts)
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp start_owned(path, opts) do
    case CanonicalPath.resolve_identity(path) do
      {:ok, canonical_path} -> claim_ownership({__MODULE__, canonical_path}, path, opts)
      {:error, reason} -> {:stop, {:ownership_path_unavailable, reason}}
    end
  end

  defp claim_ownership(ownership_key, path, opts) do
    case :global.register_name(ownership_key, self()) do
      :yes -> init_sqlite(path, ownership_key, opts)
      :no -> {:stop, {:already_started, :global.whereis_name(ownership_key)}}
    end
  end

  @impl true
  def handle_call(:load, _from, state), do: {:reply, SQLite.load(state), state}

  def handle_call(:load_projection, _from, state) do
    limit = Application.get_env(:rey_code, :max_replay_events, 2_000)
    max_checkpoint_bytes = Application.get_env(:rey_code, :max_checkpoint_bytes, 67_108_864)
    {:reply, SQLite.load_projection(state, limit, max_checkpoint_bytes), state}
  end

  def handle_call({:checkpoint, projection}, _from, state) do
    max_bytes = Application.get_env(:rey_code, :max_checkpoint_bytes, 67_108_864)
    {:reply, SQLite.checkpoint(state, projection, max_bytes), state}
  end

  def handle_call({:append_many, [], _opts}, _from, state), do: {:reply, {:ok, []}, state}

  def handle_call({:append_many, entries, opts}, _from, state) do
    case SQLite.append_many(state, entries, opts) do
      {:ok, events, next} -> {:reply, {:ok, events}, next}
      {:error, reason, next} -> {:reply, {:error, reason}, next}
    end
  end

  def handle_call(:verify, _from, state), do: {:reply, SQLite.verify(state), state}

  def handle_call({:backup, destination}, _from, state),
    do: {:reply, SQLite.backup(state, destination), state}

  @impl true
  def terminate(_reason, state) do
    _ = SQLite.close(state)
    release_ownership(state.ownership_key)
    :ok
  end

  defp release_ownership(ownership_key) do
    if :global.whereis_name(ownership_key) == self() do
      :global.unregister_name(ownership_key)
    end
  end

  defp writable_path(path) do
    if Path.extname(path) in @retired_extensions do
      {:error,
       {:ndjson_no_longer_supported,
        "Event stores are SQLite-only. Use a .sqlite3/.db path and pass the NDJSON log " <>
          "through legacy_path: to import it once."}}
    else
      {:ok, path}
    end
  end

  defp reject_retired_backend(opts) do
    case Keyword.get(opts, :backend) do
      nil ->
        :ok

      :sqlite ->
        :ok

      retired ->
        {:error,
         {:ndjson_no_longer_supported,
          "backend #{inspect(retired)} is not supported; event stores are SQLite-only"}}
    end
  end

  defp init_sqlite(path, ownership_key, opts) do
    case SQLite.open(path) do
      {:ok, state} ->
        case maybe_import_legacy(state, opts[:legacy_path]) do
          {:ok, state} ->
            {:ok, Map.put(state, :ownership_key, ownership_key)}

          {:error, reason} ->
            _ = SQLite.close(state)
            release_ownership(ownership_key)
            {:stop, reason}
        end

      {:error, reason} ->
        release_ownership(ownership_key)
        {:stop, reason}
    end
  end

  defp maybe_import_legacy(%{sequence: sequence} = state, _legacy_path) when sequence > 0,
    do: {:ok, state}

  defp maybe_import_legacy(state, nil), do: {:ok, state}

  defp maybe_import_legacy(state, legacy_path) do
    legacy_path = Path.expand(legacy_path)

    if File.exists?(legacy_path) do
      backup_path = legacy_path <> ".pre-sqlite-backup"

      with :ok <- preserve_legacy(legacy_path, backup_path),
           {events, _sequence} <- LegacyNDJSON.read(legacy_path),
           {:ok, next} <- SQLite.import_events(state, events),
           true <- SQLite.load(next) == events do
        {:ok, next}
      else
        false -> {:error, :legacy_import_projection_mismatch}
        {:error, reason} -> {:error, {:legacy_import_failed, reason}}
      end
    else
      {:ok, state}
    end
  end

  defp preserve_legacy(source, destination) do
    if File.exists?(destination) do
      :ok
    else
      case File.copy(source, destination) do
        {:ok, _bytes} -> File.chmod(destination, 0o600)
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
