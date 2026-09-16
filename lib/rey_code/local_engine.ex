defmodule ReyCode.LocalEngine do
  @moduledoc "Bootstrap and explicit lifecycle controls for the shared local engine."
  alias ReyCode.LocalEngine.{Connection, Protocol, Proxy, Server}

  def role do
    case System.get_env("REYCODE_ENGINE_ROLE") ||
           Application.get_env(:rey_code, :engine_role, :client) do
      role when role in [:client, "client"] -> :client
      role when role in [:engine, "engine"] -> :engine
      role when role in [:standalone, "standalone"] -> :standalone
      _ -> raise ArgumentError, "REYCODE_ENGINE_ROLE must be client, engine, or standalone"
    end
  end

  def socket_path, do: Path.join([ReyCode.Application.data_home(), ".engine", "socket"])

  def client_children(config) do
    [
      {Registry, keys: :unique, name: ReyCode.LocalEngine.ProxyRegistry},
      {Registry, keys: :duplicate, name: ReyCode.EventRegistry},
      {Connection, path: socket_path(), config: config}
    ] ++
      Enum.map(
        [
          engine: ReyCode.Orchestration.Engine,
          catalog: ReyCode.Provider.Catalog,
          memory: ReyCode.Memory.Store,
          credentials: ReyCode.Provider.Credentials
        ],
        fn {service, name} ->
          Supervisor.child_spec({Proxy, service: service, name: name}, id: name)
        end
      ) ++
      [
        {Task.Supervisor, name: ReyCode.ProviderTaskSupervisor},
        {ReyCode.Herdr, task_supervisor: ReyCode.ProviderTaskSupervisor}
      ]
  end

  def server_child(config), do: {Server, path: socket_path(), config: config}

  @doc "Queries or stops the engine explicitly without starting another instance."
  def control(action) when action in [:status, :stop] do
    Protocol.load_types()

    with {:ok, socket} <- Protocol.connect(socket_path()) do
      try do
        with :ok <- Protocol.send(socket, {:control, action}),
             {:ok, result} <- Protocol.recv(socket),
             do: result
      after
        :gen_tcp.close(socket)
      end
    end
  end
end
