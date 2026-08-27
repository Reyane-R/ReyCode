defmodule ReyCode.DebuggerHub do
  @moduledoc "Supervises bounded Debug Adapter Protocol sessions and request routing."

  use GenServer

  alias ReyCode.RuntimeConfig.Tools.Debugger
  alias ReyCode.Security.Environment

  @type snapshot :: %{
          name: String.t(),
          command: [String.t()],
          workspace: String.t(),
          status: :running | :stopped | :exited,
          output_bytes: non_neg_integer(),
          truncated: boolean()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)

  @spec start(String.t(), [String.t()], String.t(), Debugger.t(), GenServer.server()) ::
          {:ok, snapshot()} | {:error, term()}
  def start(name, command, workspace, policy, server \\ __MODULE__),
    do: GenServer.call(server, {:start, name, command, workspace, policy})

  @spec request(String.t(), String.t(), map(), GenServer.server()) ::
          {:ok, term()} | {:error, term()}
  def request(name, method, arguments, server \\ __MODULE__),
    do: GenServer.call(server, {:request, name, method, arguments}, :infinity)

  @spec stop(String.t(), GenServer.server()) :: :ok | {:error, atom()}
  def stop(name, server \\ __MODULE__), do: GenServer.call(server, {:stop, name})

  @spec list(GenServer.server()) :: [snapshot()]
  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  @impl true
  def init(_opts), do: {:ok, %{sessions: %{}, ports: %{}}}

  @impl true
  def handle_call({:start, name, command, workspace, policy}, _from, state) do
    with :ok <- valid_name(name),
         :ok <- valid_command(command),
         :ok <- available(state, name),
         {:ok, port} <- open(command, workspace, policy) do
      entry = %{
        name: name,
        command: command,
        workspace: workspace,
        policy: policy,
        port: port,
        status: :running,
        buffer: "",
        next_id: 1,
        pending: %{},
        output_bytes: 0,
        truncated: false
      }

      next = %{
        state
        | sessions: Map.put(state.sessions, name, entry),
          ports: Map.put(state.ports, port, name)
      }

      {:reply, {:ok, snapshot(entry)}, next}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:request, name, method, arguments}, from, state) do
    case state.sessions[name] do
      %{status: :running} = entry ->
        id = entry.next_id
        :ok = send_request(entry.port, id, method, arguments)
        timer = Process.send_after(self(), {:debugger_timeout, name, id}, entry.policy.timeout_ms)
        pending = Map.put(entry.pending, id, {from, timer})
        next_entry = %{entry | next_id: id + 1, pending: pending}
        {:noreply, put_session(state, next_entry)}

      nil ->
        {:reply, {:error, :debug_session_not_found}, state}

      _entry ->
        {:reply, {:error, :debug_session_not_running}, state}
    end
  end

  def handle_call({:stop, name}, _from, state) do
    case state.sessions[name] do
      nil ->
        {:reply, {:error, :debug_session_not_found}, state}

      entry ->
        close(entry.port)

        next =
          state |> remove_port(entry.port) |> put_session(%{entry | port: nil, status: :stopped})

        {:reply, :ok, next}
    end
  end

  def handle_call(:list, _from, state),
    do: {:reply, Enum.map(state.sessions, fn {_name, entry} -> snapshot(entry) end), state}

  @impl true
  def handle_info({port, {:data, data}}, state) when is_port(port) do
    case state.ports[port] do
      nil -> {:noreply, state}
      name -> consume_data(state, name, data)
    end
  end

  def handle_info({port, {:exit_status, status}}, state) when is_port(port) do
    case state.ports[port] do
      nil ->
        {:noreply, state}

      name ->
        entry = state.sessions[name]

        Enum.each(entry.pending, fn {_id, {from, _timer}} ->
          GenServer.reply(from, {:error, {:debugger_exit, status}})
        end)

        next =
          state
          |> remove_port(port)
          |> put_session(%{entry | port: nil, status: :exited, pending: %{}})

        {:noreply, next}
    end
  end

  def handle_info({:debugger_timeout, name, id}, state) do
    case state.sessions[name] do
      %{pending: %{^id => {from, _timer}}} = entry ->
        GenServer.reply(from, {:error, :debugger_timeout})
        {:noreply, put_session(state, %{entry | pending: Map.delete(entry.pending, id)})}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.ports, fn {port, _name} -> close(port) end)
    :ok
  end

  defp consume_data(state, name, data) do
    entry = state.sessions[name]
    bytes = entry.output_bytes + byte_size(data)

    if bytes > entry.policy.max_output_bytes do
      fail_pending(entry, :debugger_output_too_large)

      {:noreply,
       put_session(state, %{entry | output_bytes: entry.policy.max_output_bytes, truncated: true})}
    else
      entry = %{entry | buffer: entry.buffer <> data, output_bytes: bytes}
      {records, buffer} = frames(entry.buffer)
      entry = %{entry | buffer: buffer}
      entry = Enum.reduce(records, entry, &route_record/2)
      {:noreply, put_session(state, entry)}
    end
  end

  defp route_record(%{"type" => "response", "request_seq" => id} = record, entry) do
    case Map.pop(entry.pending, id) do
      {nil, _pending} ->
        entry

      {{from, timer}, pending} ->
        Process.cancel_timer(timer)

        reply =
          if record["success"] == false,
            do: {:error, {:debugger_error, record["message"]}},
            else: {:ok, record["body"]}

        GenServer.reply(from, reply)
        %{entry | pending: pending}
    end
  end

  defp route_record(_record, entry), do: entry

  defp frames(buffer), do: frames(buffer, [])

  defp frames(buffer, records) do
    case :binary.match(buffer, "\r\n\r\n") do
      :nomatch -> {Enum.reverse(records), buffer}
      {header_end, 4} -> frame_from_header(buffer, header_end, records)
    end
  end

  defp frame_from_header(buffer, header_end, records) do
    header = binary_part(buffer, 0, header_end)
    body_start = header_end + 4

    case content_length(header) do
      {:ok, length} when byte_size(buffer) >= body_start + length ->
        decode_frame(buffer, body_start, length, records)

      _ ->
        {Enum.reverse(records), buffer}
    end
  end

  defp decode_frame(buffer, body_start, length, records) do
    body = binary_part(buffer, body_start, length)
    rest_start = body_start + length
    rest = binary_part(buffer, rest_start, byte_size(buffer) - rest_start)

    case Jason.decode(body) do
      {:ok, record} -> frames(rest, [record | records])
      {:error, _} -> {Enum.reverse(records), buffer}
    end
  end

  defp content_length(header) do
    header
    |> String.split("\r\n")
    |> Enum.find_value(&content_length_line/1)
    |> parse_content_length()
  end

  defp content_length_line(line) do
    case String.split(line, ":", parts: 2) do
      [name, value] ->
        if String.downcase(String.trim(name)) == "content-length",
          do: Integer.parse(String.trim(value))

      _ ->
        nil
    end
  end

  defp parse_content_length({length, ""}) when length >= 0, do: {:ok, length}
  defp parse_content_length(_), do: {:error, :invalid_debugger_frame}

  defp send_request(port, id, method, arguments) do
    body =
      Jason.encode!(%{
        "seq" => id,
        "type" => "request",
        "command" => method,
        "arguments" => arguments
      })

    Port.command(port, ["Content-Length: ", Integer.to_string(byte_size(body)), "\r\n\r\n", body])
    :ok
  end

  defp open([executable | args], workspace, policy) do
    path =
      if Path.type(executable) == :absolute,
        do: executable,
        else: System.find_executable(executable)

    if is_binary(path) do
      {wrapper, wrapped_args, env} =
        Environment.wrap(path, args,
          source: System.get_env(),
          additional_names: policy.env_allowlist,
          cpu_seconds: policy.cpu_seconds,
          open_files: policy.open_files
        )

      options = [
        :binary,
        :exit_status,
        :use_stdio,
        {:args, Enum.map(wrapped_args, &String.to_charlist/1)},
        {:cd, String.to_charlist(workspace)},
        {:env,
         Enum.map(env, fn {name, value} ->
           {String.to_charlist(name), String.to_charlist(value)}
         end)}
      ]

      {:ok, Port.open({:spawn_executable, String.to_charlist(wrapper)}, options)}
    else
      {:error, :debugger_executable_not_found}
    end
  rescue
    error in ErlangError -> {:error, {:debugger_launch_failed, Exception.message(error)}}
  end

  defp valid_name(name) when is_binary(name) and byte_size(name) in 1..64, do: :ok
  defp valid_name(_), do: {:error, :invalid_debug_session_name}

  defp valid_command([executable | args])
       when is_binary(executable) and executable != "" and is_list(args), do: :ok

  defp valid_command(_), do: {:error, :invalid_debugger_command}

  defp available(state, name),
    do:
      if(state.sessions[name] && state.sessions[name].status == :running,
        do: {:error, :debug_session_in_use},
        else: :ok
      )

  defp put_session(state, entry),
    do: %{state | sessions: Map.put(state.sessions, entry.name, entry)}

  defp remove_port(state, port), do: %{state | ports: Map.delete(state.ports, port)}

  defp fail_pending(entry, reason) do
    Enum.each(entry.pending, fn {_id, {from, _timer}} ->
      GenServer.reply(from, {:error, reason})
    end)
  end

  defp snapshot(entry),
    do: Map.take(entry, [:name, :command, :workspace, :status, :output_bytes, :truncated])

  defp close(nil), do: :ok

  defp close(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) ->
        _ = System.cmd("/bin/kill", ["-KILL", "-#{pid}"], stderr_to_stdout: true)
        _ = System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

      _ ->
        :ok
    end

    if Port.info(port), do: Port.close(port), else: :ok
  rescue
    ArgumentError -> :ok
  end
end
