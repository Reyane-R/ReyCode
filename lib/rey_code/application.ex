defmodule ReyCode.Application do
  @moduledoc false

  require Logger

  use Application

  @impl true
  def start(_type, _args) do
    runtime_config = ReyCode.RuntimeConfig.load!()
    :ok = ReyCode.Logging.install!(runtime_config.logging)
    event_store_options = event_store_options()
    :ok = event_store_options |> Keyword.fetch!(:path) |> Path.dirname() |> File.mkdir_p()

    children = [
      {Registry, keys: :unique, name: ReyCode.AgentRegistry},
      {Registry, keys: :duplicate, name: ReyCode.EventRegistry},
      {ReyCode.EventStore, [config: runtime_config.persistence] ++ event_store_options},
      {Task.Supervisor, name: ReyCode.ProviderTaskSupervisor},
      {ReyCode.Provider.Catalog, [config: runtime_config]},
      {ReyCode.Orchestration.Supervisor, config: runtime_config}
    ]

    children = children ++ tui_children(runtime_config)

    opts = [strategy: :rest_for_one, name: ReyCode.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp tui_children(runtime_config) do
    if Application.get_env(:rey_code, :start_tui, true) do
      if terminal_attached?() do
        [
          Supervisor.child_spec(
            {Breeze.Server,
             view: ReyCode.TUI,
             start_opts: [config: runtime_config],
             theme: ReyCode.Theme.default(),
             logger: :replace,
             global_keybindings: ReyCode.TUI.global_keybindings()},
            restart: :transient
          )
        ]
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
  def storage_paths do
    case Application.get_env(:rey_code, :event_path) do
      nil ->
        %{
          database: Path.join(data_home(), "rey_code.sqlite3"),
          legacy: Path.join([legacy_xdg_data_home(), "rey_code", "events-v2.ndjson"])
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

  defp data_home do
    Application.get_env(:rey_code, :data_dir) || ReyCode.Paths.data_home()
  end

  # The retired NDJSON store only ever lived at the XDG data location; its
  # import path is historical fact rather than a platform convention.
  defp legacy_xdg_data_home do
    System.get_env("XDG_DATA_HOME") || Path.expand("~/.local/share")
  end
end
