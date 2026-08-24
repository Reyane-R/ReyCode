defmodule ReyCode.Provider.OpenAICompatible.Profile do
  @moduledoc """
  Configuration for one OpenAI-compatible chat completion API provider.

  A profile binds a display name, a base URL, and the environment variable that
  holds the API key. The key itself is read from the environment at invocation
  time and is never stored on the profile, in the catalog, or in the event log.
  """

  alias ReyCode.RuntimeConfig
  alias ReyCode.RuntimeConfig.OpenAICompatible, as: OpenAIPolicy

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

  @spec all(OpenAIPolicy.t()) :: [t()]
  def all(policy \\ RuntimeConfig.fresh().open_ai) do
    (built_in() ++ policy.profiles)
    |> Enum.uniq_by(& &1.id)
    |> Enum.map(&normalize(&1, policy))
  end

  @spec ids(OpenAIPolicy.t()) :: [atom()]
  def ids(policy \\ RuntimeConfig.fresh().open_ai), do: Enum.map(all(policy), & &1.id)

  @spec fetch(atom(), OpenAIPolicy.t()) :: {:ok, t()} | {:error, :unknown_provider}
  def fetch(id, policy \\ RuntimeConfig.fresh().open_ai) do
    case Enum.find(all(policy), &(&1.id == id)) do
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

  defp normalize(%__MODULE__{} = profile, policy),
    do: %{profile | base_url: resolved_base_url(profile, policy)}

  defp normalize(map, policy) when is_map(map) do
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
    |> normalize(policy)
  end

  defp resolved_base_url(%__MODULE__{id: id, base_url: base_url}, policy) do
    Map.get(policy.base_url_overrides, id, base_url)
  end
end
