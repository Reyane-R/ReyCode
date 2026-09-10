defmodule ReyCode.TUI.Action do
  @moduledoc "Stateless implicit button routing explicit activation through br-change."
  @behaviour Breeze.Implicit

  @impl true
  def init(_children, _attrs, _previous),
    do: {:ok, %{}, captures_keys: ["Enter", " "]}

  @impl true
  def handle_event(:input, %{"key" => key}, state) when key in ["Enter", " "],
    do: {{:change, %{}}, state}

  def handle_event(:input, %{"mouse" => %{"button" => "left", "action" => "press"}}, state),
    do: {{:change, %{}}, state}

  def handle_event(_event, _payload, state), do: {:noreply, state}

  @impl true
  def handle_modifiers(_element, _flags, _state), do: []
end
