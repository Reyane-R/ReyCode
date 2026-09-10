defmodule ReyCode.TUI.Cancellation do
  @moduledoc "State, input handling, and rendering for cancelling active session work."

  use Breeze.Component

  alias Breeze.{Component, View}
  alias ReyCode.Orchestration.Engine
  alias ReyCode.TUI.{Notice, SlashPalette}

  @unavailable_message "Engine response unavailable; request may have been recorded. Inspect durable status; do not retry blindly."

  @doc "Opens cancellation confirmation for the active turn, if one exists."
  @spec open(map()) :: map()
  def open(term) do
    term = Component.assign(term, cancel_response_uncertain?: false)
    session = term.assigns.projection.sessions[term.assigns.selected_session_id]

    if verified_active?(session) do
      Component.assign(term,
        modal: :cancel,
        slash: nil,
        cancel_turn_id: {:verification, session.id},
        notice: nil
      )
    else
      open_turn(term, session.active_turn_id)
    end
  end

  defp open_turn(term, active_turn_id) do
    case active_turn_id do
      nil ->
        SlashPalette.close(term, Notice.new(:info, "No running turn to cancel"))

      turn_id ->
        Component.assign(term, modal: :cancel, slash: nil, cancel_turn_id: turn_id, notice: nil)
    end
  end

  @doc "Cancels the selected turn and closes the confirmation on success."
  @spec submit(map()) :: {:noreply, map()}
  def submit(%{assigns: %{cancel_turn_id: {:verification, _session_id}}} = term),
    do: stop_verification(term)

  def submit(term) do
    case Engine.cancel_turn(term.assigns.cancel_turn_id, "Cancelled by user", term.assigns.engine) do
      :ok ->
        {:noreply,
         term
         |> Component.assign(
           modal: nil,
           cancel_turn_id: nil,
           notice: Notice.new(:success, "Task cancelled")
         )
         |> View.focus("prompt")}

      {:error, reason} ->
        {:noreply,
         Component.assign(term, notice: Notice.new(:error, "Could not cancel task: #{reason}"))}
    end
  end

  @spec verified_active?(map() | nil) :: boolean()
  def verified_active?(%{verified_change: %{phase: phase}}), do: phase not in ["ready", "blocked"]
  def verified_active?(_session), do: false

  @spec stop_verification(map()) :: {:noreply, map()}
  def stop_verification(%{assigns: %{cancel_response_uncertain?: true}} = term),
    do: {:noreply, Component.assign(term, notice: Notice.new(:warning, @unavailable_message))}

  def stop_verification(term) do
    case request_stop(term.assigns.selected_session_id, term.assigns.engine) do
      :ok ->
        {:noreply,
         term
         |> cancel()
         |> Component.assign(
           notice: Notice.new(:info, "Cancellation requested; host work may still be stopping.")
         )}

      {:error, reason} ->
        {:noreply,
         Component.assign(term,
           notice: Notice.new(:error, "Could not stop verification: #{inspect(reason)}")
         )}

      :response_unavailable ->
        {:noreply,
         Component.assign(term,
           cancel_response_uncertain?: true,
           notice: Notice.new(:warning, @unavailable_message)
         )}
    end
  end

  defp request_stop(session_id, engine) do
    Engine.cancel_verified_change(session_id, engine)
  catch
    :exit, _reason -> :response_unavailable
  end

  @doc "Keeps the active turn running and closes the confirmation."
  @spec cancel(map()) :: map()
  def cancel(term) do
    term
    |> Component.assign(
      modal: nil,
      cancel_turn_id: nil,
      cancel_response_uncertain?: false,
      notice: nil
    )
    |> View.focus("prompt")
  end

  @doc "Keeps global focus unchanged while the confirmation is open."
  @spec focus(map()) :: map()
  def focus(term), do: term

  @doc "Handles one key press while the cancellation modal is active."
  @spec handle_input(String.t(), map()) :: {:noreply, map()}
  def handle_input("Enter", term), do: submit(term)
  def handle_input("Escape", term), do: {:noreply, cancel(term)}
  def handle_input(_key, term), do: {:noreply, term}

  @doc "Handles component events; the cancellation modal declares none."
  @spec handle_event(term(), map(), map()) :: {:noreply, map()} | :unhandled
  def handle_event(_event, _payload, _term), do: :unhandled

  attr :term, :map, required: true

  @doc "Renders the cancellation confirmation."
  def modal(assigns) do
    ~H"""
    <box class="w-screen h-screen bg px-4 pt-3">
      <box class="w-full border-b border-muted pb-1">
        <box class="font-bold text-error">Cancel current task</box>
        <box class="text-muted">
          This stops current work, including verification checks and repairs.
        </box>
      </box>
      <box class="pt-3 text-muted">TASK ID</box>
      <box class="pt-1 w-full">{cancel_id(@term.cancel_turn_id)}</box>
      <box :if={Map.get(@term, :cancel_response_uncertain?, false)} class="pt-2 text-warning">
        <box>Engine response unavailable; request may have been</box>
        <box>recorded. Inspect durable status;</box>
        <box>do not retry blindly.</box>
      </box>
      <box
        :if={not is_nil(@term.notice) and not Map.get(@term, :cancel_response_uncertain?, false)}
        class={"pt-2 " <> Notice.text_class(@term.notice)}
      >
        {Notice.label(@term.notice)} · {@term.notice.message}
      </box>
      <box class="pt-3 text-muted">
        {if Map.get(@term, :cancel_response_uncertain?, false) do
          "Submission locked; Esc close, then inspect status"
        else
          "Enter cancel   Esc keep running"
        end}
      </box>
    </box>
    """
  end

  defp cancel_id({:verification, session_id}), do: session_id
  defp cancel_id(turn_id), do: turn_id
end
