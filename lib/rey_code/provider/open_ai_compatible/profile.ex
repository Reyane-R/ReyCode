defmodule ReyCode.Provider.OpenAICompatible.Profile do
  @moduledoc """
  Configuration for one OpenAI-compatible chat completion API provider.

  A profile binds a display name, a base URL, and — unless it is keyless —
  the environment variable that holds the API key. The key itself is read
  from the environment at invocation time and is never stored on the
  profile, in the catalog, or in the event log.

  Keyless profiles (`require_key: false`) target local servers such as
  Ollama or LM Studio; requests through them never carry an Authorization
  header, not even an empty bearer token. The capability flags
  (`supports_tools`, `supports_stream_options`) default to true and may pin
  a strict server that rejects those request features.
  """

  alias ReyCode.RuntimeConfig
  alias ReyCode.RuntimeConfig.OpenAICompatible, as: OpenAIPolicy

  @enforce_keys [:id, :name, :base_url]
  defstruct [
    :id,
    :name,
    :base_url,
    :key_env,
    require_key: true,
    supports_tools: true,
    supports_stream_options: true,
    request_timeout_ms: 600_000,
    max_output_bytes: 10_000_000,
    max_prompt_bytes: 128_000
  ]

  @type t :: %__MODULE__{
          id: atom(),
          name: String.t(),
          base_url: String.t(),
          key_env: String.t() | nil,
          require_key: boolean(),
          supports_tools: boolean(),
          supports_stream_options: boolean(),
          request_timeout_ms: pos_integer(),
          max_output_bytes: pos_integer(),
          max_prompt_bytes: pos_integer()
        }

  @spec all(OpenAIPolicy.t()) :: [t()]
  def all(policy \\ RuntimeConfig.fresh().open_ai) do
    built_ins = built_in()
    configured = Map.new(policy.profiles, &{Map.fetch!(&1, :id), &1})
    built_in_ids = MapSet.new(built_ins, & &1.id)

    (Enum.map(built_ins, &Map.get(configured, &1.id, &1)) ++
       Enum.reject(policy.profiles, &MapSet.member?(built_in_ids, Map.fetch!(&1, :id))))
    |> Enum.map(&normalize(&1, policy))
  end

  @doc "IDs of the built-in profiles; the authority for env override enumeration."
  @spec built_in_ids() :: [atom()]
  def built_in_ids, do: Enum.map(built_in(), & &1.id)

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
      },
      # Keyless local runtimes: no credential exists, so no key env is bound.
      %__MODULE__{
        id: :ollama,
        name: "Ollama",
        base_url: "http://localhost:11434/v1",
        key_env: nil,
        require_key: false
      },
      %__MODULE__{
        id: :lmstudio,
        name: "LM Studio",
        base_url: "http://localhost:1234/v1",
        key_env: nil,
        require_key: false
      }
    ]
  end

  defp normalize(%__MODULE__{} = profile, policy) do
    profile
    |> Map.replace!(:base_url, resolved_base_url(profile, policy))
    |> apply_capability_overrides(policy)
    |> validate()
  end

  defp normalize(map, policy) when is_map(map) do
    struct!(
      __MODULE__,
      Map.take(map, [
        :id,
        :name,
        :base_url,
        :key_env,
        :require_key,
        :supports_tools,
        :supports_stream_options,
        :request_timeout_ms,
        :max_output_bytes,
        :max_prompt_bytes
      ])
    )
    |> normalize(policy)
  end

  # Environment-level capability overrides (REYCODE_<ID>_SUPPORTS_*) win over
  # per-profile config so an operator can pin a strict server without editing
  # configuration files.
  defp apply_capability_overrides(%__MODULE__{} = profile, policy) do
    overrides = Map.get(policy.capability_overrides, profile.id, %{})

    %__MODULE__{
      profile
      | supports_tools: Map.get(overrides, :supports_tools, profile.supports_tools),
        supports_stream_options:
          Map.get(overrides, :supports_stream_options, profile.supports_stream_options)
    }
  end

  # Fail fast on an impossible profile instead of crashing mid-invocation.
  defp validate(%__MODULE__{require_key: true, key_env: key_env} = profile)
       when is_binary(key_env) and key_env != "",
       do: profile

  defp validate(%__MODULE__{require_key: false} = profile), do: profile

  defp validate(%__MODULE__{}) do
    raise ArgumentError, "invalid profile: key_env is required unless require_key is false"
  end

  defp resolved_base_url(%__MODULE__{id: id, base_url: base_url}, policy) do
    Map.get(policy.base_url_overrides, id, base_url)
  end
end
