defmodule ReyCode.TUI.ToolReview do
  @moduledoc """
  State, input handling, and rendering for owner review of a pending tool
  request.
  """

  use Breeze.Component

  alias Breeze.{Component, View}
  alias ReyCode.Orchestration.Engine
  alias ReyCode.Security.Environment
  alias ReyCode.TUI.SlashPalette

  @options [:approve, :deny]

  @spec initial() :: map()
  def initial, do: %{invocation_id: nil, review: nil, index: 0}

  @spec options() :: [atom()]
  def options, do: @options

  @spec open(map()) :: map()
  def open(term) do
    room = term.assigns.projection.rooms[term.assigns.selected_room_id]
    invocation = pending_invocation(term.assigns.projection, room && room.active_turn_id)

    if invocation do
      Component.assign(term,
        modal: :tool_review,
        slash: nil,
        tool_review: %{
          invocation_id: invocation.id,
          review: invocation.pending_tool_review,
          index: 0
        },
        notice: nil
      )
    else
      SlashPalette.close(term, "No tool request is awaiting approval")
    end
  end

  @spec move(map(), integer()) :: map()
  def move(term, offset) do
    index = Integer.mod(term.assigns.tool_review.index + offset, length(@options))
    Component.assign(term, tool_review: %{term.assigns.tool_review | index: index})
  end

  @spec choose(map(), String.t()) :: {:noreply, map()}
  def choose(term, key) do
    index = %{"a" => 0, "d" => 1}[String.downcase(key)]

    term
    |> Component.assign(tool_review: %{term.assigns.tool_review | index: index})
    |> submit()
  end

  @spec submit(map()) :: {:noreply, map()}
  def submit(term) do
    review_state = term.assigns.tool_review
    decision = Enum.at(@options, review_state.index)
    run_id = review_state.review && review_state.review.request_id

    case Engine.resolve_tool_run(
           review_state.invocation_id,
           run_id,
           decision,
           term.assigns.engine
         ) do
      :ok ->
        {:noreply,
         term
         |> Component.assign(
           modal: nil,
           tool_review: initial(),
           notice: resolution_notice(decision)
         )
         |> View.focus("prompt")}

      {:error, reason} ->
        {:noreply, Component.assign(term, notice: "Could not resolve tool request: #{reason}")}
    end
  end

  @spec cancel(map()) :: map()
  def cancel(term) do
    term
    |> Component.assign(modal: nil, tool_review: initial(), notice: nil)
    |> View.focus("prompt")
  end

  defp pending_invocation(_projection, nil), do: nil

  defp pending_invocation(projection, turn_id) do
    projection.invocations
    |> Map.values()
    |> Enum.find(fn invocation ->
      invocation.turn_id == turn_id and not is_nil(invocation.pending_tool_review)
    end)
  end

  defp resolution_notice(:approve), do: "Tool request approved"
  defp resolution_notice(:deny), do: "Tool request denied"

  @doc "Keeps global focus unchanged while the review is open."
  @spec focus(map()) :: map()
  def focus(term), do: term

  @doc "Handles one key press while the tool-review modal is active."
  @spec handle_input(String.t(), map()) :: {:noreply, map()}
  def handle_input(key, term) when key in ["ArrowUp", "ArrowDown", "j", "k"] do
    offset = if key in ["ArrowUp", "k"], do: -1, else: 1
    {:noreply, move(term, offset)}
  end

  def handle_input(key, term) when key in ["a", "A", "d", "D"], do: choose(term, key)
  def handle_input("Enter", term), do: submit(term)
  def handle_input("Escape", term), do: {:noreply, cancel(term)}
  def handle_input(_key, term), do: {:noreply, term}

  @doc "Handles component events; the review declares none."
  @spec handle_event(term(), map(), map()) :: {:noreply, map()} | :unhandled
  def handle_event(_event, _payload, _term), do: :unhandled

  attr :term, :map, required: true

  @doc "Renders the pending tool request for owner approval."
  def modal(assigns) do
    ~H"""
    <box class="w-screen h-screen bg px-4 pt-2">
      <box class="w-full border-b border-muted pb-1">
        <box class="font-bold text-primary">Tool approval</box>
        <box class="text-muted">This request is waiting for owner approval.</box>
      </box>
      <box class="pt-2 text-muted">TOOL</box>
      <box class="pt-1 font-bold text-warning">{@term.tool_review.review.tool}</box>
      <box
        :for={{label, value} <- details(@term.tool_review.review)}
        class="pt-2 w-full overflow-hidden"
      >
        <box class="text-muted">{label}</box>
        <box class="pt-1 text-default w-full overflow-hidden">{value}</box>
      </box>
      <box class="pt-2 text-muted">WORKSPACE</box>
      <box class="pt-1 text-muted w-full overflow-hidden">{@term.tool_review.review.workspace}</box>
      <box class="pt-3 text-muted">OWNER DECISION</box>
      <box
        :for={{decision, index} <- Enum.with_index(@term.tool_review_options)}
        class={row_class(index, @term.tool_review.index)}
      >
        {marker(index, @term.tool_review.index)} {decision}
      </box>
      <box :if={not is_nil(@term.notice)} class="pt-2 text-error">{@term.notice}</box>
      <box class="pt-3 text-muted">A approve   D deny   Enter confirm   Esc close</box>
    </box>
    """
  end

  defp details(%{tool: "bash", arguments: arguments}) do
    [
      {"COMMAND", argument(arguments, "command", "(none)")},
      {"CWD", argument(arguments, "cwd", "(workspace)")},
      {"ENV NAMES", bash_env_names()},
      {"SCOPE", "host execution — not sandboxed to the workspace"}
    ]
  end

  defp details(%{tool: "write", arguments: arguments}) do
    content = argument(arguments, "content", "")

    [
      {"WRITE PATH", argument(arguments, "path", "(none)")},
      {"CONTENT SIZE", "#{byte_size(content)} bytes"},
      {"CONTENT PREVIEW", preview(content)}
    ]
  end

  defp details(%{tool: "edit", arguments: arguments}) do
    old = argument(arguments, "old_string", "")
    new = argument(arguments, "new_string", "")

    [
      {"EDIT PATH", argument(arguments, "path", "(none)")},
      {"OLD STRING (#{byte_size(old)} bytes)", preview(old)},
      {"NEW STRING (#{byte_size(new)} bytes)", preview(new)},
      {"MATCHING", "the anchor must match exactly once or the edit fails"}
    ]
  end

  defp details(%{tool: tool, arguments: arguments}) do
    [{"ARGUMENTS", compact_arguments(tool, arguments)}]
  end

  defp argument(arguments, key, default) when is_map(arguments) do
    case Map.fetch(arguments, key) do
      {:ok, value} when is_binary(value) -> value
      _other -> default
    end
  end

  defp argument(_arguments, _key, default), do: default

  defp bash_env_names do
    names =
      Environment.allowlisted(
        source: System.get_env(),
        additional_names: Application.get_env(:rey_code, :tool_bash_env_allowlist, [])
      )
      |> Map.keys()
      |> Enum.sort()
      |> Enum.join(", ")

    truncate(names, 160)
  end

  defp compact_arguments(_tool, arguments) when is_map(arguments) do
    arguments
    |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{inspect(value)}" end)
    |> truncate(200)
  end

  defp compact_arguments(_tool, _arguments), do: "(none)"

  defp preview(content) do
    content
    |> String.replace("\n", "\\n")
    |> truncate(200)
    |> case do
      "" -> "(empty)"
      shown -> shown
    end
  end

  defp truncate(value, limit) when is_binary(value) do
    if String.length(value) <= limit,
      do: value,
      else: String.slice(value, 0, limit - 1) <> "…"
  end

  defp row_class(index, index), do: "w-full px-1 bg-panel font-bold text-primary"

  defp row_class(_index, _selected), do: "w-full px-1 text-muted"

  defp marker(index, index), do: ">"
  defp marker(_index, _selected), do: " "
end
