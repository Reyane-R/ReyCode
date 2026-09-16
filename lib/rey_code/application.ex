defmodule ReyCode.Application do
  @moduledoc false

  require Logger
  alias ReyCode.LocalEngine.Bootstrap

  use Application

  @impl true
  def start(_type, _args) do
    role = ReyCode.LocalEngine.role()
    if role == :engine, do: Bootstrap.restore()
    runtime_config = ReyCode.RuntimeConfig.load!()
    :ok = ReyCode.Logging.install!(runtime_config.logging, role)

    case role do
      :client ->
        result =
          Supervisor.start_link(
            ReyCode.LocalEngine.client_children(runtime_config) ++ tui_children(runtime_config),
            strategy: :rest_for_one,
            name: ReyCode.Supervisor
          )

        if match?({:error, _}, result) do
          Logger.error(
            "Could not attach to the shared ReyCode engine. Build/settings mismatches require an explicit engine restart (reycode engine stop, or mix rey_code.engine stop). An older standalone instance must be quit once before shared startup; no database lock was bypassed."
          )
        end

        result

      role ->
        start_engine(runtime_config, role)
    end
  end

  defp start_engine(runtime_config, role) do
    event_store_options = event_store_options()
    :ok = event_store_options |> Keyword.fetch!(:path) |> Path.dirname() |> File.mkdir_p()

    children = [
      {Registry, keys: :unique, name: ReyCode.LocalEngine.ProxyRegistry},
      {Registry, keys: :unique, name: ReyCode.AgentRegistry},
      {Registry, keys: :duplicate, name: ReyCode.EventRegistry},
      {ReyCode.EventStore, [config: runtime_config.persistence] ++ event_store_options},
      {Task.Supervisor, name: ReyCode.ProviderTaskSupervisor},
      {Task.Supervisor, name: ReyCode.IPCTaskSupervisor, max_children: 64},
      {ReyCode.Provider.Credentials, []},
      {ReyCode.Provider.Catalog, [config: runtime_config]},
      ReyCode.ProcessHub,
      ReyCode.DebuggerHub,
      ReyCode.EvalHub,
      {Registry, keys: :unique, name: ReyCode.ResourceRegistry},
      ReyCode.ResourceScopes,
      {DynamicSupervisor, strategy: :one_for_one, name: ReyCode.ResourceSupervisor},
      ReyCode.Memory.Store,
      {ReyCode.Orchestration.Supervisor, config: runtime_config}
    ]

    children =
      children ++
        if(role == :standalone,
          do:
            tui_children(runtime_config) ++
              [
                {ReyCode.Herdr,
                 task_supervisor: ReyCode.ProviderTaskSupervisor,
                 engine: ReyCode.Orchestration.Engine}
              ],
          else: []
        )

    children =
      if role == :engine,
        do: children ++ [ReyCode.LocalEngine.server_child(runtime_config)],
        else: children

    opts = [strategy: :rest_for_one, name: ReyCode.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc false
  @spec tui_server_child_spec(ReyCode.RuntimeConfig.t()) :: Supervisor.child_spec()
  def tui_server_child_spec(runtime_config) do
    Supervisor.child_spec(
      {Breeze.Server,
       view: ReyCode.TUI,
       start_opts: [config: runtime_config, workspace: File.cwd!()],
       theme: ReyCode.Theme.default(),
       logger: :replace,
       mouse: true,
       global_keybindings: ReyCode.TUI.global_keybindings(runtime_config)},
      restart: :transient
    )
  end

  defp tui_children(runtime_config) do
    if Application.get_env(:rey_code, :start_tui, true) do
      if terminal_attached?() do
        [tui_server_child_spec(runtime_config)]
      else
        announce_headless()
        []
      end
    else
      []
    end
  end

  defp terminal_attached? do
    match?({:ok, _}, :io.columns())
  rescue
    _ -> false
  end

  defp announce_headless do
    message =
      "ReyCode: no terminal detected — starting headless. Run inside a terminal for the TUI, " <>
        "or use `mix rey_code.squad` for headless squads."

    try do
      IO.puts(message)
    rescue
      _ -> Logger.info(message)
    end
  end

  @doc false
  @spec ensure_started_without_tui() :: {:ok, [atom()]} | {:error, term()}
  def ensure_started_without_tui do
    previous = Application.get_env(:rey_code, :start_tui, :not_configured)
    Application.put_env(:rey_code, :start_tui, false)

    try do
      Application.ensure_all_started(:rey_code)
    after
      restore_tui_config(previous)
    end
  end

  defp restore_tui_config(:not_configured),
    do: Application.delete_env(:rey_code, :start_tui)

  defp restore_tui_config(value),
    do: Application.put_env(:rey_code, :start_tui, value)

  @doc false
  def storage_paths do
    case Application.get_env(:rey_code, :event_path) do
      nil ->
        %{
          database: Path.join(data_home(), "rey_code.sqlite3"),
          legacy: legacy_path()
        }

      path ->
        %{database: Path.expand(path), legacy: nil}
    end
  end

  defp event_store_options do
    %{database: database, legacy: legacy} = storage_paths()

    if is_nil(legacy) do
      [path: database]
    else
      [path: database, backend: :sqlite, legacy_path: legacy]
    end
  end

  @doc "Resolves the selected data directory at bootstrap, including not-yet-created suffixes."
  def data_home do
    (Application.get_env(:rey_code, :data_dir) || System.get_env("REYCODE_DATA_DIR") ||
       ReyCode.Paths.data_home())
    |> ReyCode.Paths.canonical_future()
  end

  defp legacy_path do
    if data_home() == ReyCode.Paths.canonical_future(ReyCode.Paths.data_home()),
      do: Path.join([legacy_xdg_data_home(), "rey_code", "events-v2.ndjson"]),
      else: nil
  end

  # The retired NDJSON store only ever lived at the XDG data location; its
  # import path is historical fact rather than a platform convention.
  defp legacy_xdg_data_home do
    System.get_env("XDG_DATA_HOME") || Path.expand("~/.local/share")
  end
end
