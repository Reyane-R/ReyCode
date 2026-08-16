defmodule ReyCode.Diagnostics do
  @moduledoc """
  Builds a sanitized operational diagnostics report.

  The report contains no environment dump, credential metadata, model names, event
  contents, or prompts. Callers may inject probes for deterministic tests or use
  `snapshot/0` from a running application or release CLI.
  """

  alias ReyCode.Provider.{Catalog, Registry}

  @default_catalog_wait_ms 15_000
  @default_limits %{
    global_concurrency: 2,
    global_queue_limit: 100,
    max_checkpoint_bytes: 67_108_864,
    max_replay_events: 2_000,
    opencode_cpu_seconds: 900,
    opencode_max_diagnostic_bytes: 64_000,
    opencode_max_output_bytes: 10_000_000,
    opencode_max_prompt_bytes: 128_000,
    opencode_open_files: 1_024,
    opencode_text_chunk_bytes: 8_192,
    opencode_text_chunk_latency_ms: 50,
    projection_checkpoint_interval: 500,
    provider_discovery_command_timeout_ms: 5_000,
    provider_discovery_output_bytes: 256_000,
    provider_timeout_ms: 600_000,
    squad_rework_budget: 3,
    workspace_concurrency: 1,
    workspace_queue_limit: 20
  }

  @type report :: %{
          app: map(),
          system: map(),
          runtime: map(),
          paths: map(),
          opencode: map(),
          api_providers: [map()],
          limits: map()
        }

  @doc "Builds a diagnostics snapshot without exposing application data or secrets."
  @spec snapshot(keyword()) :: report()
  def snapshot(opts \\ []) do
    config = Keyword.get_lazy(opts, :config, fn -> Application.get_all_env(:rey_code) end)
    {data_path, database_path} = resolved_paths(config, opts)
    path_probe = Keyword.get(opts, :path_probe, &probe_path/1)
    free_space_probe = Keyword.get(opts, :free_space_probe, &probe_free_space/1)

    %{
      app: %{
        name: "rey_code",
        version: Keyword.get_lazy(opts, :app_version, &app_version/0)
      },
      system: system_info(Keyword.get(opts, :system_info)),
      runtime: runtime_info(Keyword.get(opts, :runtime_info)),
      paths: %{
        data: path_report(data_path, path_probe, free_space_probe),
        database: path_report(database_path, path_probe, free_space_probe)
      },
      opencode: opencode_report(catalog_snapshot(opts)),
      api_providers: api_providers_report(),
      limits: limits(config)
    }
  end

  @doc "Resolves the effective data directory and SQLite database path."
  @spec resolved_paths(keyword() | map(), keyword()) :: {Path.t(), Path.t()}
  def resolved_paths(config, opts \\ []) do
    configured_database_path = config_get(config, :event_path)

    database_path =
      configured_database_path ||
        Path.join(
          config_get(config, :data_dir) ||
            Keyword.get_lazy(opts, :data_home, &default_data_home/0),
          "rey_code.sqlite3"
        )

    database_path = Path.expand(database_path)
    {Path.dirname(database_path), database_path}
  end

  defp app_version do
    case Application.spec(:rey_code, :vsn) do
      nil -> "unknown"
      version -> to_string(version)
    end
  end

  defp default_data_home do
    if :os.type() == {:unix, :darwin} do
      Path.expand("~/Library/Application Support/ReyCode")
    else
      Path.join(System.get_env("XDG_DATA_HOME") || Path.expand("~/.local/share"), "rey_code")
    end
  end

  defp system_info(nil) do
    {family, name} = :os.type()

    %{
      os: Atom.to_string(name),
      os_family: Atom.to_string(family),
      architecture: :erlang.system_info(:system_architecture) |> to_string()
    }
  end

  defp system_info(info), do: info

  defp runtime_info(nil) do
    %{
      elixir: System.version(),
      otp: :erlang.system_info(:otp_release) |> to_string()
    }
  end

  defp runtime_info(info), do: info

  defp path_report(path, path_probe, free_space_probe) do
    path
    |> path_probe.()
    |> Map.new()
    |> Map.put(:path, path)
    |> Map.put(:free_bytes, free_bytes(free_space_probe.(path)))
  end

  defp probe_path(path) do
    case File.stat(path) do
      {:ok, stat} ->
        {readable, writable} = access(stat.access)

        %{
          exists: true,
          type: stat.type,
          readable: readable,
          writable: writable
        }

      {:error, :enoent} ->
        %{
          exists: false,
          type: nil,
          readable: nil,
          writable: parent_writable(path)
        }

      {:error, _reason} ->
        %{exists: nil, type: nil, readable: nil, writable: nil}
    end
  end

  defp parent_writable(path) do
    case existing_ancestor(Path.dirname(path)) do
      nil -> nil
      ancestor -> ancestor_writable(ancestor)
    end
  end

  defp ancestor_writable(path) do
    case File.stat(path) do
      {:ok, stat} -> elem(access(stat.access), 1)
      {:error, _reason} -> nil
    end
  end

  defp access(:read_write), do: {true, true}
  defp access(:read), do: {true, false}
  defp access(:write), do: {false, true}
  defp access(:none), do: {false, false}
  defp access(_other), do: {nil, nil}

  defp probe_free_space(path) do
    with existing when is_binary(existing) <- existing_ancestor(path),
         {output, 0} <- System.cmd("df", ["-Pk", existing], stderr_to_stdout: true),
         {:ok, available_kib} <- parse_available_kib(output) do
      {:ok, available_kib * 1024}
    else
      _unavailable -> :unavailable
    end
  rescue
    _error -> :unavailable
  end

  defp existing_ancestor(path) do
    expanded = Path.expand(path)

    case File.stat(expanded) do
      {:ok, _stat} ->
        expanded

      {:error, :enoent} ->
        parent = Path.dirname(expanded)
        if parent == expanded, do: nil, else: existing_ancestor(parent)

      {:error, _reason} ->
        nil
    end
  end

  defp parse_available_kib(output) do
    fields =
      output
      |> String.split(~r/\R/, trim: true)
      |> List.last()
      |> to_string()
      |> String.split()

    case fields do
      [_filesystem, _blocks, _used, available | _rest] -> parse_integer(available)
      _other -> :unavailable
    end
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _other -> :unavailable
    end
  end

  defp free_bytes({:ok, bytes}) when is_integer(bytes) and bytes >= 0, do: bytes
  defp free_bytes(_unavailable), do: nil

  defp catalog_snapshot(opts) do
    source = Keyword.get(opts, :catalog_snapshot, &Catalog.snapshot/0)
    wait_ms = Keyword.get(opts, :catalog_wait_ms, @default_catalog_wait_ms)

    if is_function(source, 0) do
      read_catalog(source, System.monotonic_time(:millisecond) + wait_ms)
    else
      source
    end
  end

  defp read_catalog(source, deadline) do
    snapshot = safe_snapshot(source)

    if opencode_status(snapshot) == :checking and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(50)
      read_catalog(source, deadline)
    else
      snapshot
    end
  end

  defp safe_snapshot(source) do
    source.()
  catch
    :exit, _reason -> %{}
  end

  defp opencode_status(snapshot) do
    snapshot
    |> entry_get(:opencode, %{})
    |> entry_get(:status, :unavailable)
  end

  defp opencode_report(snapshot) do
    entry = entry_get(snapshot, :opencode, %{})
    status = entry_get(entry, :status, :unavailable)
    executable = entry_get(entry, :executable)

    %{
      status: status,
      ready: status in [:configured, "configured"],
      installed: is_binary(executable) and executable != "",
      executable: executable,
      version: entry_get(entry, :version)
    }
  end

  defp api_providers_report do
    Enum.map(Registry.api_profiles(), fn profile ->
      %{
        id: profile.id,
        name: profile.name,
        base_url: profile.base_url
      }
    end)
  end

  defp limits(config) do
    Map.new(@default_limits, fn {key, default} ->
      {key, config_get(config, key, default)}
    end)
  end

  defp config_get(config, key, default \\ nil)

  defp config_get(config, key, default) when is_list(config),
    do: Keyword.get(config, key, default)

  defp config_get(config, key, default) when is_map(config) do
    Map.get(config, key, Map.get(config, Atom.to_string(key), default))
  end

  defp entry_get(map, key, default \\ nil)

  defp entry_get(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp entry_get(_other, _key, default), do: default
end
