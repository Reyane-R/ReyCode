defmodule ReyCode.LocalEngineTest do
  use ExUnit.Case, async: false
  alias ReyCode.{EventStore, RuntimeConfig}
  alias ReyCode.LocalEngine.{Connection, Launcher, Protocol, Proxy, Server}
  alias ReyCode.Orchestration.{Engine, Projector}
  alias ReyCode.Provider.Catalog, as: ProviderCatalog
  alias ReyCode.Provider.Catalog.Snapshot
  alias ReyCode.Provider.Credentials
  alias ReyCode.Test.Wait

  defmodule Catalog do
    use GenServer
    def start_link(_opts), do: GenServer.start_link(__MODULE__, [])
    @impl true
    def init(_), do: {:ok, %Snapshot{generation: 1, providers: %{}}}
    @impl true
    def handle_call(:snapshot, _from, state), do: {:reply, state, state}

    def handle_call({action, _provider, _model}, _from, state)
        when action in [:resolve, :resolve_when_ready, :resolve_continuation],
        do:
          {:reply,
           {:ok,
            %ReyCode.Provider.Runtime{module: ReyCode.Provider.Simulator, status: :available}},
           state}
  end

  defmodule CredentialStub do
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, %{})
    @impl true
    def init(state), do: {:ok, state}
    @impl true
    def handle_call({:fetch, key}, _from, state), do: {:reply, Map.get(state, key, :error), state}

    def handle_call({:remember, key, value, _persist}, _from, state),
      do: {:reply, :ok, Map.put(state, key, {:ok, value, :session})}

    def handle_call({:remove, key}, _from, state), do: {:reply, :ok, Map.delete(state, key)}
  end

  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    store = start_supervised!({EventStore, name: nil, path: Path.join(dir, "events.sqlite3")})
    start_supervised!({Registry, keys: :unique, name: __MODULE__.Agents})
    start_supervised!({Registry, keys: :duplicate, name: __MODULE__.Events})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: __MODULE__.Workers})
    config = RuntimeConfig.fresh(provider_discovery: false, tui_update_check: false)
    catalog = start_supervised!({Catalog, []})

    memory =
      start_supervised!({ReyCode.Memory.Store, name: nil, path: Path.join(dir, "memory.sqlite3")})

    credentials = start_supervised!({CredentialStub, []})

    engine =
      start_supervised!(
        {Engine,
         name: __MODULE__.Engine,
         event_store: store,
         config: config,
         agent_registry: __MODULE__.Agents,
         event_registry: __MODULE__.Events,
         agent_supervisor: __MODULE__.Workers,
         provider_catalog: catalog}
      )

    socket = Path.expand(".reycode/ipc-test-#{System.unique_integer([:positive])}/socket")
    on_exit(fn -> File.rm_rf!(Path.dirname(socket)) end)

    services = %{
      engine: engine,
      catalog: catalog,
      memory: memory,
      credentials: credentials
    }

    start_supervised!(
      {Server, name: __MODULE__.Server, path: socket, config: config, services: services}
    )

    %{engine: engine, socket: socket, config: config, services: services}
  end

  test "two socket clients execute in their own directories and disconnect independently",
       context do
    first = client(context, {__MODULE__.ClientA, __MODULE__.ProxyA, __MODULE__.RegistryA})
    second = client(context, {__MODULE__.ClientB, __MODULE__.ProxyB, __MODULE__.RegistryB})
    a = Path.join(context.tmp_dir, "a")
    b = Path.join(context.tmp_dir, "b")
    File.mkdir_p!(a)
    File.mkdir_p!(b)
    {:ok, session_a} = Engine.ensure_workspace_session(a, first.proxy)
    {:ok, session_b} = Engine.ensure_workspace_session(b, second.proxy)
    refute session_a == session_b
    assert Engine.snapshot(first.proxy).sessions[session_b].workspace == Path.expand(b)
    assert :ok = Engine.run_owner_command(session_a, "pwd > cwd.txt", first.proxy)
    assert :ok = Engine.run_owner_command(session_b, "pwd > cwd.txt", second.proxy)

    Wait.projection(first.proxy, fn projection ->
      Enum.count(projection.messages, fn {_id, message} ->
        String.starts_with?(message.body, "! pwd")
      end) >= 2
    end)

    assert String.trim(File.read!(Path.join(a, "cwd.txt"))) == Path.expand(a)
    assert String.trim(File.read!(Path.join(b, "cwd.txt"))) == Path.expand(b)
    stop_supervised!(__MODULE__.ClientA)
    assert Process.alive?(context.engine)
    assert Engine.snapshot(second.proxy).sessions[session_a].workspace == Path.expand(a)
  end

  test "build and configuration mismatches fail before any command runs", context do
    identity = Protocol.identity(context.config)
    {:ok, socket} = Protocol.connect(context.socket)
    :ok = Protocol.send(socket, {:hello, %{identity | build: "different"}})
    assert {:ok, {:error, {:engine_build_mismatch, _version}}} = Protocol.recv(socket)
    :gen_tcp.close(socket)
    {:ok, socket} = Protocol.connect(context.socket)
    :ok = Protocol.send(socket, {:hello, %{identity | policy: "different"}})
    assert {:ok, {:error, {:engine_configuration_mismatch, _fields}}} = Protocol.recv(socket)
    :gen_tcp.close(socket)
  end

  test "startup preflight accepts a missing engine directory", context do
    socket = Path.join([context.tmp_dir, "not-created", ".engine", "socket"])
    assert :ok = Launcher.prepare(socket, Protocol.identity(context.config))
    refute File.exists?(Path.dirname(socket))
  end

  test "an idle engine hands off to a mismatched build before client startup", context do
    socket = Path.expand(".reycode/upgrade-test-#{System.unique_integer([:positive])}/socket")
    server_name = Module.concat(__MODULE__, UpgradeServer)

    on_exit(fn -> File.rm_rf!(Path.dirname(socket)) end)

    start_supervised!(%{
      id: server_name,
      restart: :temporary,
      start:
        {Server, :start_link,
         [
           [
             name: server_name,
             path: socket,
             config: context.config,
             services: context.services,
             shutdown: fn -> GenServer.stop(server_name, :normal) end
           ]
         ]}
    })

    identity = %{Protocol.identity(context.config) | build: "new-build"}
    assert :ok = Launcher.prepare(socket, identity)
    assert {:error, :enoent} = Protocol.connect(socket)
  end

  test "an idle engine hands off to a changed configuration before client startup", context do
    socket = Path.expand(".reycode/config-test-#{System.unique_integer([:positive])}/socket")
    server_name = Module.concat(__MODULE__, ConfigUpgradeServer)

    on_exit(fn -> File.rm_rf!(Path.dirname(socket)) end)

    start_supervised!(%{
      id: server_name,
      restart: :temporary,
      start:
        {Server, :start_link,
         [
           [
             name: server_name,
             path: socket,
             config: context.config,
             services: context.services,
             shutdown: fn -> GenServer.stop(server_name, :normal) end
           ]
         ]}
    })

    identity = Protocol.identity(context.config)

    mismatched = %{
      identity
      | policy_details: Map.put(identity.policy_details, "env:PATH", "changed")
    }

    assert :ok = Launcher.prepare(socket, mismatched)
    assert {:error, :enoent} = Protocol.connect(socket)
  end

  test "a mismatched build does not interrupt active engine work", context do
    {:ok, session_id} = Engine.ensure_workspace_session(context.tmp_dir, context.engine)
    assert :ok = Engine.run_owner_command(session_id, "sleep 2", context.engine)

    socket = Path.expand(".reycode/busy-upgrade-#{System.unique_integer([:positive])}/socket")
    server_name = Module.concat(__MODULE__, BusyUpgradeServer)
    test_pid = self()
    on_exit(fn -> File.rm_rf!(Path.dirname(socket)) end)

    start_upgrade_server(server_name, socket, context, fn -> send(test_pid, :shutdown) end)

    identity = %{Protocol.identity(context.config) | build: "new-build"}
    assert {:error, :engine_busy} = Launcher.prepare(socket, identity)
    refute_receive :shutdown
    assert Process.alive?(context.engine)
  end

  test "a changed configuration does not interrupt active engine work", context do
    {:ok, session_id} = Engine.ensure_workspace_session(context.tmp_dir, context.engine)
    assert :ok = Engine.run_owner_command(session_id, "sleep 2", context.engine)

    socket = Path.expand(".reycode/busy-config-#{System.unique_integer([:positive])}/socket")
    server_name = Module.concat(__MODULE__, BusyConfigServer)
    test_pid = self()
    on_exit(fn -> File.rm_rf!(Path.dirname(socket)) end)

    start_upgrade_server(server_name, socket, context, fn -> send(test_pid, :shutdown) end)

    identity = Protocol.identity(context.config)

    mismatched = %{
      identity
      | policy_details: Map.put(identity.policy_details, "env:PATH", "changed")
    }

    assert {:error, :engine_busy} = Launcher.prepare(socket, mismatched)
    refute_receive :shutdown
    assert Process.alive?(context.engine)
  end

  test "wire decoding rejects compressed and invalid data" do
    assert {:error, :compressed_packet_forbidden} = Protocol.decode(<<131, 80, 0, 0, 0, 1>>)
    assert {:error, :invalid_packet} = Protocol.decode("invalid")
  end

  test "catalog, credentials and memory APIs preserve their contracts through IPC", context do
    peer = client(context, {__MODULE__.ClientA, __MODULE__.ProxyA, __MODULE__.RegistryA})

    assert {:ok, %{status: :available}} =
             ProviderCatalog.resolve(:zai, "glm", peer.catalog)

    assert {:ok, %{status: :available}} =
             ProviderCatalog.resolve_when_ready(:zai, "glm", peer.catalog)

    assert {:ok, %{status: :available}} =
             ProviderCatalog.resolve_continuation(:zai, peer.catalog)

    assert {:error, :unsupported_engine_operation} =
             GenServer.call(peer.catalog, {:resolve_continuation, :zai, "unexpected"})

    assert :ok = Credentials.remember("TEST_KEY", "test-value", false, peer.credentials)
    assert Credentials.known?("TEST_KEY", peer.credentials)
    assert :ok = Credentials.remove("TEST_KEY", peer.credentials)
    refute Credentials.known?("TEST_KEY", peer.credentials)

    assert {:error, :invalid_credential_name} =
             GenServer.call(peer.credentials, {:fetch, "bad=key"})

    assert {:error, :invalid_credential} =
             GenServer.call(peer.credentials, {:remember, "TEST_KEY", <<0>>, false})

    project = Path.expand(context.tmp_dir)
    assert {:ok, _} = GenServer.call(peer.memory, {:retain, project, "fact", "value", []})
    assert {:ok, _} = GenServer.call(peer.memory, {:learn, project, "lesson", "value", []})

    assert {:ok, _} =
             GenServer.call(peer.memory, {:record, project, "decision", "choice", "value", []})

    assert {:ok, entries} = GenServer.call(peer.memory, {:list, project, [], 10})
    assert length(entries) == 3
    assert {:ok, _} = GenServer.call(peer.memory, {:recall, project, "value", 10})
    assert {:ok, _} = GenServer.call(peer.memory, {:reflect, project})
    assert :ok = GenServer.call(peer.memory, {:forget, project, "fact"})

    assert {:error, :invalid_memory_request} =
             GenServer.call(peer.memory, {:record, project, "decision", "bad", :invalid, []})

    assert {:error, :invalid_memory_request} = GenServer.call(peer.memory, :unknown)
    assert {:error, :invalid_engine_request} = GenServer.call(peer.proxy, {:post_message})
    assert Process.alive?(context.engine)
  end

  test "verification APIs run on the host when addressed through a proxy", context do
    peer = client(context, {__MODULE__.ClientA, __MODULE__.ProxyA, __MODULE__.RegistryA})

    options = %{
      prompt: "Check a non-Git directory",
      workspace: context.tmp_dir,
      commands: ["true"],
      timeout_ms: 5_000,
      check_timeout_ms: 1_000,
      max_repair_count: 0
    }

    assert {:error, report} = ReyCode.VerifiedChange.run(options, peer.proxy)
    refute Jason.encode!(report) =~ "unsupported_engine_operation"
    {:ok, source} = Engine.create_blank_session("verification", context.tmp_dir, peer.proxy)
    assert {:ok, id} = Engine.start_verified_change(source, options, peer.proxy)
    assert Map.has_key?(Engine.snapshot(peer.proxy).sessions, id)
    Wait.projection(context.engine, fn p -> p.sessions[id].verified_change.phase == "blocked" end)
    directory = Engine.snapshot(peer.proxy).sessions[id].verified_change.workspace
    on_exit(fn -> File.rm_rf!(directory) end)
  end

  test "snapshot reads publish updates to existing subscribers before the next poll", context do
    first =
      client(context, {__MODULE__.ClientA, __MODULE__.ProxyA, __MODULE__.RegistryA},
        poll_ms: 5_000
      )

    baseline = Engine.subscribe(first.proxy)
    {:ok, id} = Engine.create_blank_session("new snapshot", context.tmp_dir, context.engine)
    snapshot = Engine.snapshot(first.proxy)
    assert snapshot.sequence > baseline.sequence
    assert_receive {:projection_snapshot, received}, 500
    assert Map.has_key?(received.sessions, id)
  end

  test "polls carry only the events since the client's sequence and rebuild the projection",
       context do
    first = client(context, {__MODULE__.ClientA, __MODULE__.ProxyA, __MODULE__.RegistryA})
    baseline = Connection.snapshot(:engine, first.connection)

    ids =
      for title <- ["delta one", "delta two", "delta three"] do
        {:ok, id} = Engine.create_blank_session(title, context.tmp_dir, context.engine)
        id
      end

    engine_snapshot = Engine.snapshot(context.engine)
    assert engine_snapshot.sequence > baseline.sequence

    # The engine hands out exactly the appended events, in order, and refuses
    # a gap it no longer holds.
    assert {:ok, events} = GenServer.call(context.engine, {:events_since, baseline.sequence})

    assert Enum.map(events, & &1.sequence) ==
             Enum.to_list((baseline.sequence + 1)..engine_snapshot.sequence)

    assert Enum.reduce(events, baseline, &Projector.apply/2) == engine_snapshot
    assert {:ok, []} = GenServer.call(context.engine, {:events_since, engine_snapshot.sequence})
    assert :stale = GenServer.call(context.engine, {:events_since, -1})

    # The client converges on the same projection through its polls alone.
    assert await_sequence(first.connection, engine_snapshot.sequence, 100)
    assert Connection.snapshot(:engine, first.connection) == engine_snapshot
    assert Enum.all?(ids, &Map.has_key?(engine_snapshot.sessions, &1))
  end

  test "clients reconnect with fresh history and do not replay disconnected requests", context do
    first = client(context, {__MODULE__.ClientA, __MODULE__.ProxyA, __MODULE__.RegistryA})
    Engine.subscribe(first.proxy)
    {:ok, id} = Engine.create_blank_session("reconnect", context.tmp_dir, first.proxy)
    stop_supervised!(Server)
    assert_receive {:engine_connection, :disconnected}, 1_000
    assert Map.has_key?(Engine.snapshot(first.proxy).sessions, id)
    assert Credentials.source("EXAMPLE_KEY", first.credentials) == :unavailable
    refute Credentials.known?("EXAMPLE_KEY", first.credentials)

    assert {:error, :engine_disconnected} =
             Engine.create_blank_session("must not replay", context.tmp_dir, first.proxy)

    assert :ok = Engine.run_owner_command(id, "printf while-disconnected", context.engine)

    Wait.projection(context.engine, fn projection ->
      Enum.any?(projection.messages, fn {_id, message} ->
        String.contains?(message.body, "while-disconnected")
      end)
    end)

    start_supervised!(
      {Server,
       name: __MODULE__.Server,
       path: context.socket,
       config: context.config,
       services: context.services}
    )

    assert_receive {:engine_connection, :connected}, 2_000
    snapshot = Engine.snapshot(first.proxy)

    assert Enum.any?(snapshot.messages, fn {_id, message} ->
             String.contains?(message.body, "while-disconnected")
           end)

    refute Enum.any?(snapshot.sessions, fn {_id, session} ->
             session.title == "must not replay"
           end)
  end

  test "two terminal views preserve independent drafts and can explicitly share a session",
       context do
    a = client(context, {__MODULE__.ClientA, __MODULE__.ProxyA, __MODULE__.RegistryA})
    b = client(context, {__MODULE__.ClientB, __MODULE__.ProxyB, __MODULE__.RegistryB})
    dir_a = Path.join(context.tmp_dir, "a")
    dir_b = Path.join(context.tmp_dir, "b")
    File.mkdir_p!(dir_a)
    File.mkdir_p!(dir_b)
    {:ok, id_a} = Engine.ensure_workspace_session(dir_a, a.proxy)
    {:ok, id_b} = Engine.ensure_workspace_session(dir_b, b.proxy)

    for id <- [id_a, id_b] do
      :ok =
        Engine.configure_participants(id, ["assistant"], :zai_coding, "glm-4.7", context.engine)

      :ok = Engine.run_owner_command(id, "printf initial", context.engine)
    end

    Wait.projection(context.engine, fn p ->
      Enum.count(p.messages, fn {_, m} -> String.contains?(m.body, "initial") end) >= 2
    end)

    view_a = view(a, context.config, dir_a, id_a)
    view_b = view(b, context.config, dir_b, id_b)
    Breeze.Test.input(view_a, "a")
    Breeze.Test.input(view_b, "b")
    assert Breeze.Test.metadata(view_a).assigns.drafts[id_a] == "a"
    assert Breeze.Test.metadata(view_b).assigns.drafts[id_b] == "b"
    snapshot = Engine.snapshot(context.engine)

    Breeze.Test.info(
      view_a,
      {:projection_snapshot, %{snapshot | sequence: snapshot.sequence + 1000}}
    )

    Breeze.Test.info(view_a, {:engine_reconnected, snapshot})
    assert Breeze.Test.metadata(view_a).assigns.projection.sequence == snapshot.sequence
    assert Breeze.Test.metadata(view_a).assigns.drafts[id_a] == "a"
    assert Breeze.Test.metadata(view_a).assigns.selected_session_id == id_a
    assert Breeze.Test.metadata(view_b).assigns.selected_session_id == id_b
    Breeze.Test.input(view_b, %{"ctrlKey" => true, "key" => "p"})
    Breeze.Test.event(view_b, "prompt_changed", %{value: "/resume #{id_a}"})
    Breeze.Test.render!(view_b)
    Breeze.Test.input(view_b, "Enter")
    assert Breeze.Test.metadata(view_b).assigns.selected_session_id == id_a
    assert :ok = Engine.run_owner_command(id_a, "printf shared-update", context.engine)

    Wait.projection(b.proxy, fn p ->
      Enum.any?(p.messages, fn {_, m} -> String.contains?(m.body, "shared-update") end)
    end)

    assert await_text(view_a, "shared-update", 100)
    assert await_text(view_b, "shared-update", 100)
    assert Breeze.Test.metadata(view_a).assigns.drafts[id_a] == "a"
    assert Breeze.Test.metadata(view_b).assigns.drafts[id_b] == "b"
  end

  defp view(client, config, workspace, session_id) do
    view =
      Breeze.Test.start!(ReyCode.TUI,
        size: {100, 30},
        global_keybindings: ReyCode.TUI.global_keybindings(),
        start_opts: [
          engine: client.proxy,
          provider_catalog: client.catalog,
          config: config,
          workspace: workspace
        ]
      )

    on_exit(fn -> Breeze.Test.stop(view) end)
    Breeze.Test.event(view, "prompt_submitted", %{value: "/resume #{session_id}"})
    Breeze.Test.render!(view)
    view
  end

  defp await_text(_view, _text, 0), do: false

  defp await_text(view, text, remaining) do
    if Breeze.Test.render!(view) =~ text do
      true
    else
      receive do
      after
        10 -> await_text(view, text, remaining - 1)
      end
    end
  end

  defp await_sequence(_connection, _sequence, 0), do: false

  defp await_sequence(connection, sequence, remaining) do
    if Connection.snapshot(:engine, connection).sequence >= sequence do
      true
    else
      Process.sleep(20)
      await_sequence(connection, sequence, remaining - 1)
    end
  end

  defp client(context, {connection_name, proxy_name, registry_name}, extra \\ []) do
    start_supervised!({Registry, keys: :duplicate, name: registry_name}, id: registry_name)

    connection =
      start_supervised!(
        {Connection,
         name: connection_name,
         path: context.socket,
         config: context.config,
         registry: registry_name,
         poll_ms: Keyword.get(extra, :poll_ms, 100),
         launch?: false},
        id: connection_name
      )

    proxy =
      start_supervised!(
        {Proxy,
         name: proxy_name, service: :engine, connection: connection, registry: registry_name},
        id: proxy_name
      )

    catalog =
      start_supervised!(
        {Proxy, name: nil, service: :catalog, connection: connection, registry: registry_name},
        id: {proxy_name, :catalog}
      )

    credentials =
      start_supervised!(
        {Proxy,
         name: nil, service: :credentials, connection: connection, registry: registry_name},
        id: {proxy_name, :credentials}
      )

    memory =
      start_supervised!(
        {Proxy, name: nil, service: :memory, connection: connection, registry: registry_name},
        id: {proxy_name, :memory}
      )

    %{
      connection: connection,
      proxy: proxy,
      catalog: catalog,
      credentials: credentials,
      memory: memory
    }
  end

  defp start_upgrade_server(name, socket, context, shutdown) do
    start_supervised!(%{
      id: name,
      restart: :temporary,
      start:
        {Server, :start_link,
         [
           [
             name: name,
             path: socket,
             config: context.config,
             services: context.services,
             shutdown: shutdown
           ]
         ]}
    })
  end
end
