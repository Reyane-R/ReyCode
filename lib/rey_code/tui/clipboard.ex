defmodule ReyCode.TUI.Clipboard do
  @moduledoc "Bounded clipboard writes through the platform clipboard utility, without shell interpolation."

  alias ReyCode.Security.Environment

  @max_copy_bytes 10_000_000
  @timeout_ms 2_000

  @spec copy(String.t(), keyword()) :: :ok | {:error, term()}
  def copy(text, opts \\ [])
  def copy(text, _opts) when byte_size(text) > @max_copy_bytes, do: {:error, :clipboard_too_large}

  def copy(text, opts) do
    reply = Process.alias()
    {pid, monitor} = spawn_monitor(fn -> send(reply, {reply, perform_copy(text, opts)}) end)

    try do
      receive do
        {^reply, result} -> result
        {:DOWN, ^monitor, :process, ^pid, _reason} -> {:error, :clipboard_failed}
      after
        @timeout_ms ->
          Process.exit(pid, :kill)
          {:error, :clipboard_timeout}
      end
    after
      Process.demonitor(monitor, [:flush])
      Process.unalias(reply)
    end
  end

  defp perform_copy(text, opts) do
    with {:ok, command} <- command(opts), do: write(command, text)
  rescue
    _error -> {:error, :clipboard_failed}
  catch
    :exit, _reason -> {:error, :clipboard_failed}
  end

  defp command(opts) do
    executable =
      Keyword.get_lazy(opts, :executable, fn ->
        case :os.type() do
          {:unix, :darwin} -> System.find_executable("pbcopy")
          {:unix, _} -> System.find_executable("wl-copy")
          _ -> nil
        end
      end)

    if executable, do: {:ok, executable}, else: {:error, :clipboard_unavailable}
  end

  defp write(executable, text) do
    {wrapper, args, env} =
      Environment.wrap(executable, [],
        additional_names: ["DISPLAY", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR"]
      )

    with {:ok, process} <- Exile.Process.start_link([wrapper | args], env: env, stderr: :disable) do
      written =
        with :ok <- Exile.Process.write(process, text), do: Exile.Process.close_stdin(process)

      # Wait for natural completion before asking Exile to reap. Its await_exit
      # initiates shutdown, which can otherwise interrupt the clipboard write.
      output = if written == :ok, do: Exile.Process.read(process, 1), else: nil
      exit = Exile.Process.await_exit(process, 1_000)

      case {written, output, exit} do
        {:ok, :eof, {:ok, 0}} -> :ok
        _ -> {:error, :clipboard_failed}
      end
    end
  end
end
