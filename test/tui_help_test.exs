defmodule ReyCode.TUI.HelpTest do
  use ExUnit.Case, async: true

  alias ReyCode.TUI.Help

  test "opens, focuses, submits, and closes the help modal" do
    term = term()

    assert Help.open(term).assigns.modal == :help
    assert Help.focus(term) == term
    assert {:noreply, submitted} = Help.submit(term)
    assert submitted.assigns.modal == nil
    assert submitted.focused == "prompt"
    assert {:noreply, escaped} = Help.handle_input("Escape", term)
    assert escaped.assigns.modal == nil
    assert {:noreply, entered} = Help.handle_input("Enter", term)
    assert entered.assigns.modal == nil
    assert {:noreply, unchanged} = Help.handle_input("ArrowDown", term)
    assert unchanged == term
    assert Help.handle_event(:unknown, %{}, term) == :unhandled
  end

  test "renders capability sections and every provider readiness state" do
    rows = Help.provider_rows(term())
    assert Enum.any?(rows, &String.contains?(&1, "Configured: ready (1 models)"))
    assert Enum.any?(rows, &String.contains?(&1, "Missing: not installed"))
  end

  test "exposes the shared capability command registry" do
    assert Enum.any?(ReyCode.Capabilities.commands(), &(&1.command == "/help"))
  end

  defp term do
    %Breeze.Term{
      focused: "prompt",
      assigns: %{
        modal: :help,
        providers: %{
          configured: %{name: "Configured", status: :configured, models: ["model"]},
          available: %{name: "Available", status: :available, models: []},
          checking: %{name: "Checking", status: :checking, models: []},
          missing: %{name: "Missing", status: :missing, models: []},
          unchecked: %{name: "Unchecked", status: :unchecked, models: []},
          error: %{name: "Error", status: :error, models: []},
          binary: %{name: "Binary", status: "ready", models: []},
          unknown: %{name: "Unknown", status: :other, models: []}
        }
      }
    }
  end
end
