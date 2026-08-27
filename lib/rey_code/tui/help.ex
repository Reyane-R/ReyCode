defmodule ReyCode.TUI.Help do
  @moduledoc "State, input handling, and rendering for the `/help` modal."

  use Breeze.Component

  alias Breeze.{Component, View}

  @doc "Opens the deterministic capability reference without creating a Message."
  @spec open(map()) :: map()
  def open(term), do: Component.assign(term, modal: :help, slash: nil, notice: nil)

  @doc "Keeps focus stable while the help modal is open."
  @spec focus(map()) :: map()
  def focus(term), do: term

  @doc "Closes the help modal."
  @spec submit(map()) :: {:noreply, map()}
  def submit(term), do: {:noreply, close(term)}

  @doc "Handles one key press while the help modal is active."
  @spec handle_input(String.t(), map()) :: {:noreply, map()}
  def handle_input("Escape", term), do: {:noreply, close(term)}
  def handle_input("Enter", term), do: {:noreply, close(term)}
  def handle_input(_key, term), do: {:noreply, term}

  @doc "Handles component events; the help modal declares none."
  @spec handle_event(term(), map(), map()) :: :unhandled
  def handle_event(_event, _payload, _term), do: :unhandled

  @doc "Closes help and restores prompt focus."
  @spec close(map()) :: map()
  def close(term), do: term |> Component.assign(modal: nil) |> View.focus("prompt")

  attr :term, :map, required: true

  @doc "Renders the capability reference and current provider readiness."
  def modal(assigns) do
    assigns = Map.put(assigns, :sections, ReyCode.Capabilities.sections())

    ~H"""
    <box class="w-screen h-screen bg px-4 pt-3">
      <box class="w-full border-b border-muted pb-1">
        <box class="font-bold text-primary">What ReyCode can do</box>
        <box class="text-muted">Esc/Enter close · Type / for commands.</box>
      </box>
      <box class="pt-2">
        <box class="font-bold text-primary">Providers now</box>
        <box :for={provider <- provider_rows(@term)} class="text-muted">  · {provider}</box>
      </box>
      <box class="pt-2">
        <box :for={section <- @sections} class="pt-1">
          <box class="font-bold text-primary">{section.title}</box>
          <box :for={item <- section.items} class="text-muted">  · {item}</box>
        </box>
      </box>
    </box>
    """
  end

  @doc "Returns one display row for each provider catalog entry."
  @spec provider_rows(map()) :: [String.t()]
  def provider_rows(%{assigns: %{providers: providers}}) when is_map(providers) do
    providers
    |> Map.values()
    |> Enum.sort_by(&Map.get(&1, :name, ""))
    |> Enum.map(&provider_row/1)
  end

  def provider_rows(_term), do: []

  defp provider_row(provider) do
    name = Map.get(provider, :name, Map.get(provider, "name", "Unknown provider"))
    status = Map.get(provider, :status, Map.get(provider, "status", :unavailable))
    models = Map.get(provider, :models, Map.get(provider, "models", []))
    model_count = if is_list(models), do: length(models), else: 0
    "#{name}: #{status_text(status)}#{model_suffix(status, model_count)}"
  end

  defp status_text(:configured), do: "ready"
  defp status_text(:available), do: "installed; needs configuration"
  defp status_text(:checking), do: "checking"
  defp status_text(:missing), do: "not installed"
  defp status_text(:unchecked), do: "discovery disabled"
  defp status_text(:error), do: "discovery error"
  defp status_text(status) when is_binary(status), do: status
  defp status_text(_status), do: "unavailable"

  defp model_suffix(:configured, count) when count > 0, do: " (#{count} models)"
  defp model_suffix(_status, _count), do: ""
end
