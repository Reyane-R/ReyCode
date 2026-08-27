defmodule ReyCode.Tool.Debug do
  @moduledoc "Controls one bounded Debug Adapter Protocol session."

  @behaviour ReyCode.Tool

  alias ReyCode.DebuggerHub
  alias ReyCode.RuntimeConfig.Tools.Debugger, as: DebuggerPolicy
  alias ReyCode.Tool.{Request, Result, Support}

  @read_actions ~w(threads stack_trace scopes variables)
  @write_actions ~w(start launch attach set_breakpoints continue next step_in step_out evaluate disconnect)
  @actions @read_actions ++ @write_actions

  @impl true
  def run(%Request{arguments: arguments, workspace: workspace}, opts) do
    %DebuggerPolicy{} = policy = Keyword.fetch!(opts, :policy)

    with {:ok, action} <- Support.require_arg(arguments, :action),
         :ok <- known_action(action) do
      execute(action, arguments, workspace, policy)
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  @doc "Returns true when a debugger operation mutates session state or execution."
  @spec mutating_action?(term()) :: boolean()
  def mutating_action?(action), do: action in @write_actions

  defp known_action(action),
    do: if(action in @actions, do: :ok, else: {:error, :unsupported_debug_action})

  defp execute("start", arguments, workspace, policy) do
    with {:ok, name} <- Support.require_arg(arguments, :name),
         {:ok, command} <- command(arguments, policy.command),
         {:ok, snapshot} <- DebuggerHub.start(name, command, workspace, policy) do
      Result.ok(Jason.encode!(snapshot))
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  defp execute("launch", arguments, _workspace, _policy),
    do: request(arguments, "launch", launch_arguments(arguments))

  defp execute("attach", arguments, _workspace, _policy),
    do: request(arguments, "attach", Map.drop(arguments, ["action", :action, "name"]))

  defp execute("disconnect", arguments, _workspace, _policy),
    do: request(arguments, "disconnect", %{})

  defp execute("continue", arguments, _workspace, _policy),
    do: request(arguments, "continue", %{"threadId" => integer(arguments, "thread_id", 1)})

  defp execute("next", arguments, _workspace, _policy),
    do: request(arguments, "next", %{"threadId" => integer(arguments, "thread_id", 1)})

  defp execute("step_in", arguments, _workspace, _policy),
    do: request(arguments, "stepIn", %{"threadId" => integer(arguments, "thread_id", 1)})

  defp execute("step_out", arguments, _workspace, _policy),
    do: request(arguments, "stepOut", %{"threadId" => integer(arguments, "thread_id", 1)})

  defp execute("threads", arguments, _workspace, _policy), do: request(arguments, "threads", %{})

  defp execute("stack_trace", arguments, _workspace, _policy),
    do: request(arguments, "stackTrace", %{"threadId" => integer(arguments, "thread_id", 1)})

  defp execute("scopes", arguments, _workspace, _policy),
    do: request(arguments, "scopes", %{"frameId" => integer(arguments, "frame_id", 1)})

  defp execute("variables", arguments, _workspace, _policy),
    do:
      request(arguments, "variables", %{
        "variablesReference" => integer(arguments, "variables_reference", 1)
      })

  defp execute("evaluate", arguments, _workspace, _policy),
    do:
      request(arguments, "evaluate", %{
        "expression" => value(arguments, "expression", ""),
        "context" => value(arguments, "context", "repl")
      })

  defp execute("set_breakpoints", arguments, _workspace, _policy) do
    source = value(arguments, "source", "")
    lines = arguments |> value("lines", []) |> List.wrap() |> Enum.map(&to_integer/1)

    request(arguments, "setBreakpoints", %{
      "source" => %{"path" => source},
      "breakpoints" => Enum.map(lines, &%{"line" => &1})
    })
  end

  defp request(arguments, method, params) do
    with {:ok, name} <- Support.require_arg(arguments, :name),
         {:ok, response} <- DebuggerHub.request(name, method, params) do
      Result.ok(Jason.encode!(response))
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  defp command(arguments, default) do
    case Map.get(arguments, "command", Map.get(arguments, :command, default)) do
      command when is_list(command) and command != [] -> {:ok, command}
      _ -> {:error, :debugger_not_configured}
    end
  end

  defp launch_arguments(arguments) do
    %{
      "program" => value(arguments, "program", nil),
      "args" => List.wrap(value(arguments, "args", [])),
      "stopOnEntry" => value(arguments, "stop_on_entry", false)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp value(arguments, key, default),
    do: Map.get(arguments, key, Map.get(arguments, argument_key(key), default))

  defp argument_key("name"), do: :name
  defp argument_key("command"), do: :command
  defp argument_key("thread_id"), do: :thread_id
  defp argument_key("frame_id"), do: :frame_id
  defp argument_key("variables_reference"), do: :variables_reference
  defp argument_key("expression"), do: :expression
  defp argument_key("context"), do: :context
  defp argument_key("source"), do: :source
  defp argument_key("lines"), do: :lines
  defp argument_key("args"), do: :args
  defp argument_key("program"), do: :program
  defp argument_key("stop_on_entry"), do: :stop_on_entry

  defp integer(arguments, key, default),
    do: arguments |> value(key, default) |> to_integer(default)

  defp to_integer(value), do: to_integer(value, 0)
  defp to_integer(value, _default) when is_integer(value), do: value

  defp to_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> default
    end
  end

  defp to_integer(_, default), do: default
end
