defmodule ReyCode.Orchestration.Engine.OwnerCommand do
  @moduledoc """
  Executes one owner-typed shell command and records its transcript message.

  The Operator typed the command, so the owner is the approver: owner commands
  reuse the same bounded Bash tool the agents use, without an approval gate.
  Execution runs on the engine's task supervisor so the engine never blocks on
  a shell; the result is appended durably when the command finishes.
  """

  alias ReyCode.Orchestration.Engine.{Identity, Persistence}
  alias ReyCode.Orchestration.{EventEntries, Validation}
  alias ReyCode.Security.Workspace
  alias ReyCode.Tool.{Bash, Request, Result}
  @display_limit 4_000

  @doc "Validates and asynchronously starts one owner shell command."
  @spec run(map(), term(), term()) :: {:reply, :ok | {:error, atom()}, map()}

  def run(state, session_id, raw_command) do
    with %{} = session <- state.projection.sessions[session_id],
         {:ok, command} <- Validation.owner_command(raw_command),
         :ok <- dispatch(state, session, command) do
      {:reply, :ok, state}
    else
      nil -> {:reply, {:error, :session_not_found}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @doc "Appends the durable transcript message for one finished owner command."
  @spec finish(map(), term(), String.t(), String.t(), map()) :: {:noreply, map()}
  def finish(state, session_id, message_id, command, result) do
    if is_nil(state.projection.sessions[session_id]) do
      {:noreply, state}
    else
      entry = EventEntries.owner_command_posted(session_id, message_id, body(command, result))
      {:noreply, Persistence.append_and_apply!(state, [entry])}
    end
  end

  defp dispatch(state, session, command) do
    message_id = Identity.new_id("msg")
    parent = self()
    config = state.config
    workspace = session.workspace

    task = fn ->
      result = execute(command, workspace, config)
      send(parent, {:owner_command_result, session.id, message_id, command, result})
    end

    case Task.Supervisor.start_child(state.task_supervisor, task) do
      {:ok, _pid} -> :ok
      {:error, _reason} -> {:error, :command_dispatch_failed}
    end
  end

  defp execute(command, workspace, config) do
    request = %Request{
      tool: "bash",
      arguments: %{"command" => command},
      workspace: workspace,
      roots: Workspace.roots(config.workspace)
    }

    Bash.run(request, policy: config.tools.bash)
  rescue
    _error -> Result.error(:owner_command_crashed)
  end

  defp body(command, result) do
    output = result_output(Result.to_wire(result))
    text = "! " <> command <> "\n" <> output

    if String.length(text) > @display_limit,
      do: String.slice(text, 0, @display_limit) <> "\n… output truncated",
      else: text
  end

  defp result_output(wire) do
    suffix = if wire["truncated"], do: "\n… output truncated", else: ""

    cond do
      is_binary(wire["output"]) and wire["output"] != "" ->
        String.trim_trailing(wire["output"]) <> suffix

      is_nil(wire["error"]) ->
        "(no output)" <> suffix

      true ->
        "error: " <> inspect(wire["error"]) <> suffix
    end
  end
end
