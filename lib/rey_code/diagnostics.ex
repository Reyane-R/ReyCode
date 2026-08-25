defmodule ReyCode.Diagnostics do
  @moduledoc """
  Builds a sanitized operational diagnostics report.

  The report contains no environment dump, credential metadata, model names, event
  contents, or prompts. Configured provider endpoints are reduced to a sanitized
  origin (scheme, host, and non-default port) so URL userinfo, paths, query values,
  and fragments never enter the report; malformed or non-HTTP(S) values are
  reported as unavailable without echoing the raw input. Callers may inject probes
  for deterministic tests; the release CLI supplies the frozen startup config.
  """

  alias ReyCode.Provider.{Catalog, Registry}
  alias ReyCode.RuntimeConfig
  alias ReyCode.Security.Workspace

  @default_catalog_wait_ms 15_000

  @type report :: %{
          app: map(),
          system: map(),
          runtime: map(),
          paths: map(),
          opencode: map(),
          omp: map(),
          api_providers: [map()],
          limits: map(),
          security: map()
        }

  @doc "Builds a diagnostics snapshot without exposing application data or secrets."
  @spec snapshot(keyword()) :: report()
  def snapshot(opts \\ []) do
    raw_config = Keyword.get_lazy(opts, :config, &RuntimeConfig.fresh/0)
    config = normalize_config(raw_config)
    path_config = Keyword.get(opts, :path_config, raw_config)
    {data_path, database_path} = resolved_paths(path_config, opts)
    path_probe = Keyword.get(opts, :path_probe, &probe_path/1)
    free_space_probe = Keyword.get(opts, :free_space_probe, &probe_free_space/1)
    catalog = catalog_snapshot(opts)

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
      opencode: opencode_report(catalog),
      omp: omp_report(catalog),
      limits: limits(config),
      api_providers: api_providers_report(config),
      security: %{workspace_roots: workspace_roots(config)}
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
      read_catalog(source, System.monotonic_time(:millisecond) + wait_ms).providers
    else
      source
    end
  end

  defp read_catalog(source, deadline) do
    snapshot = safe_snapshot(source)

    if discovery_checking?(snapshot.providers) and
         System.monotonic_time(:millisecond) < deadline do
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

  defp discovery_checking?(snapshot) do
    snapshot
    |> Enum.filter(fn {key, _entry} -> key in [:opencode, :omp, "opencode", "omp"] end)
    |> Enum.any?(fn {_key, entry} -> entry_get(entry, :status, :unavailable) == :checking end)
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

  defp omp_report(snapshot) do
    entry = entry_get(snapshot, :omp, %{})
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

  defp api_providers_report(config) do
    Enum.map(Registry.api_profiles(config), fn profile ->
      %{
        id: profile.id,
        name: profile.name,
        endpoint: sanitize_endpoint(profile.base_url)
      }
    end)
  end

  defp sanitize_endpoint(raw) do
    case URI.new(raw) do
      {:ok, %URI{scheme: scheme, host: host, port: port}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        format_endpoint(scheme, host, explicit_port(scheme, port))

      _other ->
        "[unavailable]"
    end
  end

  defp format_endpoint(scheme, host, port) do
    host = if String.contains?(host, ":"), do: "[#{host}]", else: host
    port = if is_integer(port), do: ":#{port}", else: ""
    "#{scheme}://#{host}#{port}"
  end

  defp explicit_port("http", 80), do: nil
  defp explicit_port("https", 443), do: nil
  defp explicit_port(_scheme, port), do: port

  defp limits(%RuntimeConfig{} = config) do
    %{
      global_concurrency: config.orchestration.global_concurrency,
      global_queue_limit: config.orchestration.global_queue_limit,
      max_checkpoint_bytes: config.persistence.max_checkpoint_bytes,
      max_replay_events: config.persistence.max_replay_events,
      opencode_cpu_seconds: config.open_code.cpu_seconds,
      opencode_max_diagnostic_bytes: config.open_code.max_diagnostic_bytes,
      opencode_max_output_bytes: config.open_code.max_output_bytes,
      opencode_max_prompt_bytes: config.open_code.max_prompt_bytes,
      opencode_open_files: config.open_code.open_files,
      opencode_text_chunk_bytes: config.open_code.text_chunk_bytes,
      opencode_text_chunk_latency_ms: config.open_code.text_chunk_latency_ms,
      omp_cpu_seconds: config.omp.cpu_seconds,
      omp_max_diagnostic_bytes: config.omp.max_diagnostic_bytes,
      omp_max_output_bytes: config.omp.max_output_bytes,
      omp_max_prompt_bytes: config.omp.max_prompt_bytes,
      omp_open_files: config.omp.open_files,
      omp_text_chunk_bytes: config.omp.text_chunk_bytes,
      omp_text_chunk_latency_ms: config.omp.text_chunk_latency_ms,
      omp_discovery_output_bytes: config.omp.discovery_output_bytes,
      projection_checkpoint_interval: config.persistence.checkpoint_interval,
      provider_discovery_command_timeout_ms: config.providers.discovery_command_timeout_ms,
      provider_discovery_output_bytes: config.providers.discovery_output_bytes,
      provider_timeout_ms: config.open_code.provider_timeout_ms,
      squad_rework_budget: config.squad.rework_budget,
      workspace_concurrency: config.orchestration.workspace_concurrency,
      workspace_queue_limit: config.orchestration.workspace_queue_limit
    }
  end

  defp workspace_roots(%RuntimeConfig{} = config), do: Workspace.roots(config.workspace)

  defp normalize_config(%RuntimeConfig{} = config), do: config

  defp normalize_config(config) when is_list(config),
    do: config |> Map.new() |> normalize_config()

  defp normalize_config(config) when is_map(config) do
    declared = RuntimeConfig.declared_defaults() |> Map.keys() |> MapSet.new()
    known = Map.filter(config, fn {key, _value} -> MapSet.member?(declared, key) end)
    RuntimeConfig.fresh(known)
  end

  defp config_get(config, key, default \\ nil)

  defp config_get(%RuntimeConfig{}, _key, default), do: default

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
