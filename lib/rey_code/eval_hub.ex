defmodule ReyCode.EvalHub do
  @moduledoc "Supervises bounded persistent Python and JavaScript evaluation kernels."

  use GenServer

  alias ReyCode.RuntimeConfig.Tools.Evaluation
  alias ReyCode.Security.Environment

  @type snapshot :: %{
          name: String.t(),
          language: atom(),
          workspace: String.t(),
          status: atom(),
          output_bytes: non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)

  @spec start(String.t(), atom(), String.t(), Evaluation.t(), GenServer.server()) ::
          {:ok, snapshot()} | {:error, term()}
  def start(name, language, workspace, policy, server \\ __MODULE__),
    do: GenServer.call(server, {:start, name, language, workspace, policy})

  @spec evaluate(String.t(), String.t(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def evaluate(name, code, server \\ __MODULE__),
    do: GenServer.call(server, {:evaluate, name, code}, :infinity)

  @spec stop(String.t(), GenServer.server()) :: :ok | {:error, atom()}
  def stop(name, server \\ __MODULE__), do: GenServer.call(server, {:stop, name})

  @spec list(GenServer.server()) :: [snapshot()]
  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  @impl true
  def init(_opts), do: {:ok, %{kernels: %{}, ports: %{}}}

  @impl true
  def handle_call({:start, name, language, workspace, policy}, _from, state) do
    with :ok <- valid_name(name),
         :ok <- valid_language(language),
         :ok <- available(state, name),
         {:ok, port} <- open(language, workspace, policy) do
      kernel = %{
        name: name,
        language: language,
        workspace: workspace,
        policy: policy,
        port: port,
        status: :running,
        buffer: "",
        pending: nil,
        output_bytes: 0
      }

      {:reply, {:ok, snapshot(kernel)},
       %{
         state
         | kernels: Map.put(state.kernels, name, kernel),
           ports: Map.put(state.ports, port, name)
       }}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:evaluate, name, code}, from, state) do
    case state.kernels[name] do
      %{status: :running, pending: nil} = kernel ->
        if byte_size(code) > kernel.policy.max_code_bytes do
          {:reply, {:error, :evaluation_code_too_large}, state}
        else
          ref = System.unique_integer([:positive, :monotonic])
          true = Port.command(kernel.port, [Jason.encode!(%{"id" => ref, "code" => code}), "\n"])

          timer =
            Process.send_after(self(), {:evaluation_timeout, name, ref}, kernel.policy.timeout_ms)

          next = %{kernel | pending: {ref, from, timer}}
          {:noreply, put_kernel(state, next)}
        end

      %{pending: {_ref, _from, _timer}} ->
        {:reply, {:error, :evaluation_busy}, state}

      nil ->
        {:reply, {:error, :evaluation_not_found}, state}

      _ ->
        {:reply, {:error, :evaluation_not_running}, state}
    end
  end

  def handle_call({:stop, name}, _from, state) do
    case state.kernels[name] do
      nil ->
        {:reply, {:error, :evaluation_not_found}, state}

      kernel ->
        close(kernel.port)

        {:reply, :ok,
         state
         |> remove_port(kernel.port)
         |> put_kernel(%{kernel | port: nil, status: :stopped, pending: nil})}
    end
  end

  def handle_call(:list, _from, state),
    do: {:reply, Enum.map(state.kernels, fn {_name, kernel} -> snapshot(kernel) end), state}

  @impl true
  def handle_info({port, {:data, data}}, state) when is_port(port) do
    case state.ports[port] do
      nil -> {:noreply, state}
      name -> consume(state, name, data)
    end
  end

  def handle_info({port, {:exit_status, status}}, state) when is_port(port) do
    case state.ports[port] do
      nil ->
        {:noreply, state}

      name ->
        kernel = state.kernels[name]
        reply_pending(kernel, {:error, {:evaluation_exit, status}})

        {:noreply,
         state
         |> remove_port(port)
         |> put_kernel(%{kernel | port: nil, status: :exited, pending: nil})}
    end
  end

  def handle_info({:evaluation_timeout, name, ref}, state) do
    case state.kernels[name] do
      %{pending: {^ref, from, _timer}} = kernel ->
        GenServer.reply(from, {:error, :evaluation_timeout})
        {:noreply, put_kernel(state, %{kernel | pending: nil})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: Enum.each(state.ports, fn {port, _name} -> close(port) end)

  defp consume(state, name, data) do
    kernel = state.kernels[name]
    bytes = kernel.output_bytes + byte_size(data)

    if bytes > kernel.policy.max_output_bytes do
      reply_pending(kernel, {:error, :evaluation_output_too_large})

      {:noreply,
       put_kernel(state, %{kernel | output_bytes: kernel.policy.max_output_bytes, pending: nil})}
    else
      {records, rest} = lines(kernel.buffer <> data)
      kernel = %{kernel | buffer: rest, output_bytes: bytes}
      kernel = Enum.reduce(records, kernel, &handle_record/2)
      {:noreply, put_kernel(state, kernel)}
    end
  end

  defp lines(buffer), do: split_lines(buffer, [])

  defp split_lines(buffer, records) do
    case :binary.match(buffer, "\n") do
      :nomatch ->
        {Enum.reverse(records), buffer}

      {index, 1} ->
        line = binary_part(buffer, 0, index) |> String.trim()
        rest_start = index + 1
        rest = binary_part(buffer, rest_start, byte_size(buffer) - rest_start)

        case Jason.decode(line) do
          {:ok, record} -> split_lines(rest, [record | records])
          {:error, _} -> split_lines(rest, records)
        end
    end
  end

  defp handle_record(%{"id" => id} = record, %{pending: {id, from, timer}} = kernel) do
    Process.cancel_timer(timer)
    GenServer.reply(from, {:ok, Map.drop(record, ["id"])})
    %{kernel | pending: nil}
  end

  defp handle_record(_record, kernel), do: kernel

  defp reply_pending(%{pending: {_id, from, _timer}}, reply), do: GenServer.reply(from, reply)
  defp reply_pending(_kernel, _reply), do: :ok

  defp open(language, workspace, policy) do
    command = command(language, policy)

    with [executable | args] <- command,
         path when is_binary(path) <- resolve_executable(executable),
         {wrapper, wrapped_args, env} <-
           Environment.wrap(path, args_for(language, args),
             source: System.get_env(),
             additional_names: policy.env_allowlist,
             cpu_seconds: policy.cpu_seconds,
             open_files: policy.open_files
           ) do
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
      [] -> {:error, :evaluation_runtime_not_configured}
      nil -> {:error, :evaluation_runtime_not_found}
      _ -> {:error, :evaluation_launch_failed}
    end
  rescue
    error in ErlangError -> {:error, {:evaluation_launch_failed, Exception.message(error)}}
  end

  defp command(:python, policy), do: policy.python_command
  defp command(:javascript, policy), do: policy.javascript_command
  defp args_for(:python, args), do: args ++ ["-u", "-c", python_kernel()]
  defp args_for(:javascript, args), do: args ++ ["-e", javascript_kernel()]

  defp python_kernel do
    "import sys,json,io,contextlib,traceback\nns={}\nfor line in sys.stdin:\n r=json.loads(line); out=io.StringIO()\n try:\n  with contextlib.redirect_stdout(out): exec(r['code'],ns,ns)\n  value=repr(ns.get('_result',''))\n  response={'id':r['id'],'ok':True,'stdout':out.getvalue(),'value':value}\n except Exception as e:\n  response={'id':r['id'],'ok':False,'stdout':out.getvalue(),'error':str(e),'traceback':traceback.format_exc(limit=4)}\n print(json.dumps(response,separators=(',',':')),flush=True)"
  end

  defp javascript_kernel do
    "const readline=require('readline'); const vm=require('vm'); const context=vm.createContext({}); const rl=readline.createInterface({input:process.stdin}); rl.on('line',line=>{const r=JSON.parse(line); try { const value=vm.runInContext(r.code,context); process.stdout.write(JSON.stringify({id:r.id,ok:true,stdout:'',value:String(value)})+'\\n'); } catch(e) { process.stdout.write(JSON.stringify({id:r.id,ok:false,stdout:'',error:String(e)})+'\\n'); }});"
  end

  defp resolve_executable(executable) when is_binary(executable) do
    if Path.type(executable) == :absolute,
      do: if(File.exists?(executable), do: executable),
      else: System.find_executable(executable)
  end

  defp resolve_executable(_), do: nil
  defp valid_name(name) when is_binary(name) and byte_size(name) in 1..64, do: :ok
  defp valid_name(_), do: {:error, :invalid_evaluation_name}
  defp valid_language(language) when language in [:python, :javascript], do: :ok
  defp valid_language(_), do: {:error, :unsupported_evaluation_language}

  defp available(state, name),
    do:
      if(state.kernels[name] && state.kernels[name].status == :running,
        do: {:error, :evaluation_name_in_use},
        else: :ok
      )

  defp put_kernel(state, kernel),
    do: %{state | kernels: Map.put(state.kernels, kernel.name, kernel)}

  defp remove_port(state, port), do: %{state | ports: Map.delete(state.ports, port)}

  defp snapshot(kernel),
    do: Map.take(kernel, [:name, :language, :workspace, :status, :output_bytes])

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
