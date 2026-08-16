defmodule ReyCode.Provider.OpenAICompatible.Profile do
  @moduledoc """
  Configuration for one OpenAI-compatible chat completion API provider.

  A profile binds a display name, a base URL, and the environment variable that
  holds the API key. The key itself is read from the environment at invocation
  time and is never stored on the profile, in the catalog, or in the event log.
  """

  @enforce_keys [:id, :name, :base_url, :key_env]
  defstruct [
    :id,
    :name,
    :base_url,
    :key_env,
    request_timeout_ms: 600_000,
    max_output_bytes: 10_000_000,
    max_prompt_bytes: 128_000,
    extra_headers: []
  ]

  @type t :: %__MODULE__{
          id: atom(),
          name: String.t(),
          base_url: String.t(),
          key_env: String.t(),
          request_timeout_ms: pos_integer(),
          max_output_bytes: pos_integer(),
          max_prompt_bytes: pos_integer(),
          extra_headers: [{String.t(), String.t()}]
        }

  @spec all() :: [t()]
  def all do
    configured = Application.get_env(:rey_code, :openai_compatible_providers, [])
    (built_in() ++ configured) |> Enum.uniq_by(& &1.id) |> Enum.map(&normalize/1)
  end

  @spec ids() :: [atom()]
  def ids, do: Enum.map(all(), & &1.id)

  @spec fetch(atom()) :: {:ok, t()} | {:error, :unknown_provider}
  def fetch(id) do
    case Enum.find(all(), &(&1.id == id)) do
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

  defp normalize(%__MODULE__{} = profile), do: %{profile | base_url: resolved_base_url(profile)}

  defp normalize(map) when is_map(map) do
    struct!(
      __MODULE__,
      Map.take(map, [
        :id,
        :name,
        :base_url,
        :key_env,
        :request_timeout_ms,
        :max_output_bytes,
        :max_prompt_bytes,
        :extra_headers
      ])
    )
    |> normalize()
  end

  defp resolved_base_url(%__MODULE__{id: id, base_url: base_url}) do
    override_env = "REYCODE_#{id |> Atom.to_string() |> String.upcase()}_BASE_URL"
    System.get_env(override_env) || base_url
  end
end
