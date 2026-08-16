defmodule ReyCode.Provider.Registry do
  @moduledoc """
  Stateless registry of live provider identities and metadata.

  Provider strings are matched against known IDs without converting arbitrary
  input to atoms. Historical projection values remain recognized even though
  they are not live providers.
  """

  alias ReyCode.Provider.{OpenAICompatible, OpenCode}
  alias ReyCode.Provider.OpenAICompatible.Profile

  @historical_ids [:demo, :unconfigured]

  @type descriptor :: %{
          id: atom(),
          name: String.t(),
          description: String.t(),
          module: module()
        }

  @doc "Returns provider IDs available for new runtime configuration."
  @spec live_provider_ids(keyword()) :: [atom()]
  def live_provider_ids(opts \\ []) do
    ids = Enum.map(descriptors(), & &1.id)

    if simulator_enabled?(opts), do: ids ++ [:simulator], else: ids
  end

  @doc "Normalizes a known string ID without creating atoms from external input."
  @spec normalize_provider_id(term()) :: term()
  def normalize_provider_id(value) when is_binary(value) do
    Enum.find(known_ids(), value, &(Atom.to_string(&1) == value))
  end

  def normalize_provider_id(value), do: value

  @doc "Returns the user-facing name for a provider identity."
  @spec display_name(atom() | String.t()) :: String.t()
  def display_name(provider) do
    case descriptor(provider) do
      %{name: name} -> name
      nil -> special_display_name(normalize_provider_id(provider), provider)
    end
  end

  @doc "Returns the supported OpenAI-compatible provider profiles."
  @spec api_profiles() :: [Profile.t()]
  def api_profiles, do: Profile.all()

  @doc "Fetches an OpenAI-compatible profile by atom or known string ID."
  @spec fetch_api_profile(atom() | String.t()) ::
          {:ok, Profile.t()} | {:error, :unknown_provider}
  def fetch_api_profile(provider) do
    id = normalize_provider_id(provider)

    case Enum.find(api_profiles(), &(&1.id == id)) do
      nil -> {:error, :unknown_provider}
      profile -> {:ok, profile}
    end
  end

  @doc "Checks whether a provider may be selected for new configuration."
  @spec configurable_provider?(term(), keyword()) :: boolean()
  def configurable_provider?(provider, opts \\ []) do
    id = normalize_provider_id(provider)

    id == :opencode or
      (id == :simulator and simulator_enabled?(opts)) or
      Enum.any?(api_profiles(), &(&1.id == id))
  end

  @doc "Returns metadata for providers backed by live runtime modules."
  @spec descriptors() :: [descriptor()]
  def descriptors do
    [
      %{
        id: :opencode,
        name: "OpenCode",
        description: "CLI runtime",
        module: OpenCode
      }
      | Enum.map(api_profiles(), fn profile ->
          %{
            id: profile.id,
            name: profile.name,
            description: "OpenAI-compatible API",
            module: OpenAICompatible
          }
        end)
    ]
  end

  @doc "Looks up live provider metadata by atom or known string ID."
  @spec descriptor(atom() | String.t()) :: descriptor() | nil
  def descriptor(provider) do
    id = normalize_provider_id(provider)
    Enum.find(descriptors(), &(&1.id == id))
  end

  defp known_ids do
    Enum.map(descriptors(), & &1.id) ++ [:simulator | @historical_ids]
  end

  defp simulator_enabled?(opts) do
    Keyword.get(
      opts,
      :allow_simulator?,
      Application.get_env(:rey_code, :allow_simulator_provider, false)
    )
  end

  defp special_display_name(:simulator, _provider), do: "Simulator"
  defp special_display_name(_id, provider), do: to_string(provider)
end
