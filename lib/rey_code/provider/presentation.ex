defmodule ReyCode.Provider.Presentation do
  @moduledoc "Pure presentation calculations for provider runtimes and readiness."

  alias ReyCode.Failure
  alias ReyCode.Provider.Registry

  @doc "Formats a participant's configured runtime and current catalog status."
  @spec runtime_label(map(), map()) :: String.t()
  def runtime_label(%{provider: :unconfigured}, _providers),
    do: "Model API · not configured"

  def runtime_label(%{provider: :simulator}, _providers), do: "Simulator (test only)"

  def runtime_label(%{provider: provider}, _providers)
      when provider in [:opencode, :omp, :open_code, "opencode", "omp", "open_code"],
      do: "#{Registry.display_name(provider)} · select a model API in /connect"

  def runtime_label(%{provider: provider, model: model}, _providers) do
    [provider_name(provider), if(is_binary(model), do: short_model(model))]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  @doc "Returns the display name for a provider, or nil for an unconfigured runtime."
  @spec provider_name(term()) :: String.t() | nil
  def provider_name(:unconfigured), do: nil
  def provider_name(provider), do: Registry.display_name(provider)

  @doc "Formats a participant's runtime for compact timeline rows."
  @spec short_runtime_label(map()) :: String.t()
  def short_runtime_label(%{provider: :unconfigured}), do: "not configured"
  def short_runtime_label(%{provider: :simulator}), do: "simulator"

  def short_runtime_label(%{model: model}) when is_binary(model),
    do: short_model(model)

  def short_runtime_label(%{model: nil}), do: "model required"
  def short_runtime_label(participant), do: to_string(participant.provider)

  @doc "Checks whether a participant's configured model is ready in a catalog entry."
  @spec ready?(map() | nil, map()) :: boolean()
  def ready?(%{id: :simulator, status: :configured}, _participant), do: true

  def ready?(%{status: :configured, models: models}, participant) do
    is_binary(participant.model) and participant.model in models
  end

  def ready?(_provider, _participant), do: false

  @doc "Returns the presentation class for a participant's provider readiness."
  @spec text_class(map() | nil, map()) :: String.t()
  def text_class(provider, participant) do
    cond do
      ready?(provider, participant) -> "px-1 text-success"
      provider && provider.status in [:checking, :available] -> "px-1 text-warning"
      true -> "px-1 text-error"
    end
  end

  @doc "Formats a provider catalog status for display."
  @spec status_label(map() | nil) :: String.t()
  def status_label(nil), do: "unknown"
  def status_label(%{status: :configured, models: []}), do: "no models"
  def status_label(%{failure: %Failure{category: :missing_credentials}}), do: "key required"

  def status_label(%{failure: %Failure{category: :authentication_failed}}),
    do: "authentication failed"

  def status_label(%{failure: %Failure{category: :provider_unavailable}}),
    do: "server unavailable"

  def status_label(%{failure: %Failure{category: :timeout}}), do: "timed out"
  def status_label(%{status: :configured}), do: "configured"
  def status_label(%{status: :checking}), do: "checking"
  def status_label(%{status: :missing}), do: "missing"
  def status_label(%{status: :available}), do: "setup required"
  def status_label(%{status: :unchecked}), do: "not checked"
  def status_label(%{status: :error}), do: "error"
  def status_label(%{status: status}), do: to_string(status)

  @doc "Returns setup or availability help for a selected provider."
  @spec selection_help(map() | nil) :: String.t()
  def selection_help(nil), do: ""

  def selection_help(%{status: :configured, models: []} = entry), do: no_models_help(entry)

  def selection_help(%{id: id, status: :configured} = entry) do
    "#{provider_display_name(id, entry)} · #{length(entry.models)} models"
  end

  def selection_help(%{status: :checking}), do: refresh_notice()

  def selection_help(entry), do: unavailable_help(entry)

  @doc "Returns actionable help when a provider cannot be selected."
  @spec unavailable_help(map()) :: String.t()
  def unavailable_help(%{status: :configured, models: []} = entry), do: no_models_help(entry)

  def unavailable_help(%{status: :checking}), do: refresh_notice()

  def unavailable_help(%{id: id} = entry) do
    case Registry.fetch_api_profile(id) do
      {:ok, profile} -> setup_help(profile, entry)
      _ -> "Provider is not configured. Select a model API in /connect."
    end
  end

  @doc "Returns a sanitized technical discovery diagnostic, separate from setup help."
  @spec details(map() | nil) :: String.t() | nil
  def details(%{failure: %Failure{message: message}}), do: message
  def details(_entry), do: nil

  @doc "Returns the notice shown while provider discovery refreshes."
  @spec refresh_notice() :: String.t()
  def refresh_notice, do: "Checking providers..."

  @doc "Removes provider namespaces from a model identifier."
  @spec short_model(String.t()) :: String.t()
  def short_model(model), do: model |> String.split("/") |> List.last()

  defp setup_help(profile, %{status: :unchecked}) do
    if profile.require_key do
      "Provider discovery is disabled. Set #{profile.key_env}, enable provider_discovery, " <>
        "then restart ReyCode to use #{profile.name}."
    else
      "Provider discovery is disabled. Start or check the #{profile.name} server, " <>
        "enable provider_discovery, then restart ReyCode."
    end
  end

  defp setup_help(profile, %{failure: %Failure{category: :authentication_failed}}) do
    if profile.require_key do
      "#{profile.name} rejected authentication. Check #{profile.key_env} and account access, " <>
        "then restart ReyCode with the corrected key."
    else
      "#{profile.name} rejected authentication. This profile sends no API key. " <>
        "Check the server's access settings, then press R to recheck."
    end
  end

  defp setup_help(profile, %{failure: %Failure{category: category}})
       when category in [:provider_unavailable, :timeout] do
    server_help(profile)
  end

  defp setup_help(profile, %{status: :available}) do
    if profile.require_key do
      "Restart ReyCode with #{profile.key_env} set to use #{profile.name}. " <>
        "An export in another shell cannot update this running process."
    else
      server_help(profile)
    end
  end

  defp setup_help(profile, _entry) do
    "Could not list #{profile.name} models. Check the server/API configuration and service status, " <>
      "then press R to recheck. Press D for technical details."
  end

  defp server_help(%{require_key: false, name: name}) do
    "Start or check the #{name} server and its configured endpoint, then press R to recheck."
  end

  defp server_help(%{name: name}) do
    "Cannot reach #{name}. Check the API endpoint, network and service status, then press R to recheck."
  end

  defp no_models_help(%{id: id}) do
    case Registry.fetch_api_profile(id) do
      {:ok, %{require_key: false, name: name}} ->
        "#{name} is reachable but lists no models. Download or load a model on the server, " <>
          "then press R to recheck."

      _ ->
        "The API lists no models. Check your account's model access and API endpoint, " <>
          "then press R to recheck."
    end
  end

  defp provider_display_name(id, entry) do
    case Registry.fetch_api_profile(id) do
      {:ok, profile} -> profile.name
      _ -> entry.name
    end
  end
end
