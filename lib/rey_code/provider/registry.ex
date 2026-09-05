defmodule ReyCode.Provider.Registry do
  @moduledoc """
  Stateless registry of live provider identities and metadata.

  Provider strings are matched against known IDs without converting arbitrary
  input to atoms. Historical projection values remain recognized even though
  they are not live providers.
  """

  alias ReyCode.Provider.OpenAICompatible
  alias ReyCode.Provider.OpenAICompatible.Profile
  alias ReyCode.RuntimeConfig

  @historical_ids [:demo, :unconfigured, :opencode, :omp, :open_code]

  @type descriptor :: %{
          id: atom(),
          name: String.t(),
          description: String.t(),
          module: module()
        }

  @doc "Returns provider IDs available for new runtime configuration."
  @spec live_provider_ids(keyword()) :: [atom()]
  def live_provider_ids(opts \\ []) do
    ids = Enum.map(descriptors(Keyword.get(opts, :config)), & &1.id)

    if simulator_enabled?(opts), do: ids ++ [:simulator], else: ids
  end

  @doc "Normalizes a known string ID without creating atoms from external input."
  @spec normalize_provider_id(term(), ReyCode.RuntimeConfig.t() | nil) :: term()
  def normalize_provider_id(value, config \\ nil)

  def normalize_provider_id(value, config) when is_binary(value) do
    Enum.find(known_ids(config), value, &(Atom.to_string(&1) == value))
  end

  def normalize_provider_id(value, _config), do: value

  @doc "Returns the user-facing name for a provider identity."
  @spec display_name(atom() | String.t(), ReyCode.RuntimeConfig.t() | nil) :: String.t()
  def display_name(provider, config \\ nil) do
    case descriptor(provider, config) do
      %{name: name} -> name
      nil -> special_display_name(normalize_provider_id(provider, config), provider)
    end
  end

  @doc "Returns the supported OpenAI-compatible provider profiles."
  @spec api_profiles(ReyCode.RuntimeConfig.t() | nil) :: [Profile.t()]
  def api_profiles(config \\ nil), do: Profile.all(open_ai_policy(config))

  @doc "Fetches an OpenAI-compatible profile by atom or known string ID."
  @spec fetch_api_profile(atom() | String.t(), ReyCode.RuntimeConfig.t() | nil) ::
          {:ok, Profile.t()} | {:error, :unknown_provider}
  def fetch_api_profile(provider, config \\ nil) do
    id = normalize_provider_id(provider, config)

    case Enum.find(api_profiles(config), &(&1.id == id)) do
      nil -> {:error, :unknown_provider}
      profile -> {:ok, profile}
    end
  end

  @doc "Checks whether a provider may be selected for new configuration."
  @spec configurable_provider?(term(), keyword()) :: boolean()
  def configurable_provider?(provider, opts \\ []) do
    id = normalize_provider_id(provider, Keyword.get(opts, :config))

    (id == :simulator and simulator_enabled?(opts)) or
      Enum.any?(api_profiles(Keyword.get(opts, :config)), &(&1.id == id))
  end

  @doc "Returns metadata for providers backed by live runtime modules."
  @spec descriptors(ReyCode.RuntimeConfig.t() | nil) :: [descriptor()]
  def descriptors(config \\ nil) do
    Enum.map(api_profiles(config), fn profile ->
      %{
        id: profile.id,
        name: profile.name,
        description: "OpenAI-compatible API",
        module: OpenAICompatible
      }
    end)
  end

  @doc "Looks up live provider metadata by atom or known string ID."
  @spec descriptor(atom() | String.t(), ReyCode.RuntimeConfig.t() | nil) :: descriptor() | nil
  def descriptor(provider, config \\ nil) do
    id = normalize_provider_id(provider, config)
    Enum.find(descriptors(config), &(&1.id == id))
  end

  defp known_ids(config) do
    Enum.map(descriptors(config), & &1.id) ++ [:simulator | @historical_ids]
  end

  defp simulator_enabled?(opts) do
    Keyword.get_lazy(opts, :allow_simulator?, fn ->
      case Keyword.fetch(opts, :config) do
        {:ok, %RuntimeConfig{} = config} -> config.providers.allow_simulator?
        :error -> false
      end
    end)
  end

  defp open_ai_policy(nil), do: RuntimeConfig.fresh().open_ai
  defp open_ai_policy(%RuntimeConfig{} = config), do: config.open_ai

  defp special_display_name(:simulator, _provider), do: "Simulator"

  defp special_display_name(id, _provider) when id in [:opencode, :open_code],
    do: "OpenCode (retired)"

  defp special_display_name(:omp, _provider), do: "OMP (retired)"
  defp special_display_name(_id, provider), do: to_string(provider)
end
