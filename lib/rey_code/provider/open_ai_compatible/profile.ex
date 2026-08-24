defmodule ReyCode.Provider.OpenAICompatible.Profile do
  @moduledoc """
  Configuration for one OpenAI-compatible chat completion API provider.

  A profile binds a display name, a base URL, and the environment variable that
  holds the API key. The key itself is read from the environment at invocation
  time and is never stored on the profile, in the catalog, or in the event log.

  Profiles resolve against an injected runtime configuration. Callers that do
  not provide one receive the validated schema defaults.
  """

  alias ReyCode.RuntimeConfig

  @enforce_keys [:id, :name, :base_url, :key_env]
  defstruct [
    :id,
    :name,
    :base_url,
    :key_env,
    request_timeout_ms: 600_000,
    max_output_bytes: 10_000_000,
    max_prompt_bytes: 128_000
  ]

  @type t :: %__MODULE__{
          id: atom(),
          name: String.t(),
          base_url: String.t(),
          key_env: String.t(),
          request_timeout_ms: pos_integer(),
          max_output_bytes: pos_integer(),
          max_prompt_bytes: pos_integer()
        }

  @spec all(ReyCode.RuntimeConfig.t() | nil) :: [t()]
  def all(config \\ nil) do
    config = config || RuntimeConfig.fresh()
    configured = RuntimeConfig.policy(config, :openai_compatible_providers, [])

    (built_in() ++ configured)
    |> Enum.uniq_by(& &1.id)
    |> Enum.map(&normalize(&1, config))
  end

  @spec ids(ReyCode.RuntimeConfig.t() | nil) :: [atom()]
  def ids(config \\ nil), do: Enum.map(all(config), & &1.id)

  @spec fetch(atom(), ReyCode.RuntimeConfig.t() | nil) ::
          {:ok, t()} | {:error, :unknown_provider}
  def fetch(id, config \\ nil) do
    case Enum.find(all(config), &(&1.id == id)) do
      nil -> {:error, :unknown_provider}
      profile -> {:ok, profile}
    end
  end

  defp built_in do
    [
      %__MODULE__{
        id: :deepseek,
        name: "DeepSeek",
        base_url: "https://api.deepseek.com",
        key_env: "DEEPSEEK_API_KEY"
      }
    ]
  end

  defp normalize(%__MODULE__{} = profile, config),
    do: %{profile | base_url: resolved_base_url(profile, config)}

  defp normalize(map, config) when is_map(map) do
    struct!(
      __MODULE__,
      Map.take(map, [
        :id,
        :name,
        :base_url,
        :key_env,
        :request_timeout_ms,
        :max_output_bytes,
        :max_prompt_bytes
      ])
    )
    |> normalize(config)
  end

  defp resolved_base_url(%__MODULE__{id: id, base_url: base_url}, config) do
    config
    |> RuntimeConfig.policy(:openai_compatible_base_url_overrides, %{})
    |> Map.get(id, base_url)
  end
end
