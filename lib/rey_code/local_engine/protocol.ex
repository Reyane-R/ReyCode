defmodule ReyCode.LocalEngine.Protocol do
  @moduledoc "Versioned, bounded local IPC. The socket is private to the owning OS user."
  alias ReyCode.Provider.OpenAICompatible.Profile
  alias ReyCode.Security.Environment
  @version 1
  @max_packet_bytes 67_108_864
  @timeout_ms 5_000

  def version, do: @version
  def timeout_ms, do: @timeout_ms

  def request_timeout_ms(:catalog, {:resolve_when_ready, _, _}), do: 20_000

  def request_timeout_ms(:engine, {:ui_verified_change_run, options}) when is_map(options),
    do: verification_timeout(Map.get(options, :timeout_ms))

  def request_timeout_ms(:engine, request)
      when is_tuple(request) and elem(request, 0) in [:resolve_merge, :cancel_turn], do: 30_000

  def request_timeout_ms(_service, _request), do: 4_500

  defp verification_timeout(timeout_ms)
       when is_integer(timeout_ms) and timeout_ms in 1..3_600_000,
       do: timeout_ms + 5_000

  defp verification_timeout(_timeout_ms), do: 4_500

  def socket_options,
    do: [
      :binary,
      packet: 4,
      packet_size: @max_packet_bytes,
      active: false,
      send_timeout: @timeout_ms,
      send_timeout_close: true
    ]

  def connect(path), do: :gen_tcp.connect({:local, path}, 0, socket_options(), @timeout_ms)

  def send(socket, term) do
    if :erlang.external_size(term) <= @max_packet_bytes,
      do: :gen_tcp.send(socket, :erlang.term_to_binary(term)),
      else: {:error, :packet_too_large}
  end

  def recv(socket) do
    with {:ok, bytes} <- :gen_tcp.recv(socket, 0, @timeout_ms), do: decode(bytes)
  end

  def decode(<<131, 80, _::binary>>), do: {:error, :compressed_packet_forbidden}

  def decode(bytes) when byte_size(bytes) <= @max_packet_bytes do
    {:ok, :erlang.binary_to_term(bytes, [:safe])}
  rescue
    ArgumentError -> {:error, :invalid_packet}
  end

  def decode(_bytes), do: {:error, :packet_too_large}

  @doc "Loads the application's finite atom vocabulary before safe term decoding."
  def load_types do
    Enum.each(Application.spec(:rey_code, :modules) || [], &Code.ensure_loaded/1)
  end

  def identity(config) do
    config = ReyCode.RuntimeConfig.canonical_paths(config)
    modules = Application.spec(:rey_code, :modules) || []
    code = modules |> Enum.sort() |> Enum.map(&{&1, &1.module_info(:md5)})

    dependencies =
      (Application.spec(:rey_code, :applications) || [])
      |> Enum.sort()
      |> Enum.map(&{&1, Application.spec(&1, :vsn)})

    policy = config |> Map.from_struct() |> Map.drop([:tui, :logging])
    storage = ReyCode.Application.storage_paths().database |> ReyCode.Paths.canonical_future()

    key_envs =
      Profile.all(config.open_ai)
      |> Enum.map(& &1.key_env)
      |> Enum.reject(&is_nil/1)

    credentials = Map.new(key_envs, &{&1, System.get_env(&1)})

    names =
      [
        config.tools.bash,
        config.tools.lsp,
        config.tools.process,
        config.tools.debugger,
        config.tools.evaluation
      ]
      |> Enum.flat_map(& &1.env_allowlist)

    environment =
      Environment.allowlisted(additional_names: names)
      |> Map.delete("TERM")
      |> Map.update("PATH", "", fn path ->
        path |> String.split(":") |> Enum.uniq() |> Enum.join(":")
      end)

    details =
      Map.new(policy, fn {key, value} -> {Atom.to_string(key), digest(value)} end)
      |> Map.put("credentials", digest(credentials))
      |> Map.merge(Map.new(environment, fn {key, value} -> {"env:" <> key, digest(value)} end))

    %{
      protocol: @version,
      version: Application.spec(:rey_code, :vsn) |> to_string(),
      build: digest({code, dependencies}),
      storage: storage,
      policy_details: details,
      policy: digest({policy, credentials, environment})
    }
  end

  defp digest(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)
end
