defmodule ReyCode.Update do
  @moduledoc """
  Release update discovery for installed ReyCode releases.

  `check/0` compares the running version against the latest published GitHub
  release. Auto-checks run only inside release builds (source sessions never
  phone home); every network step is bounded and every failure returns a tagged
  error that callers are expected to ignore.
  """

  @repo "Reyane-R/ReyCode"
  @latest_url "https://api.github.com/repos/#{@repo}/releases/latest"
  @request_timeout_ms 3_000
  @max_body_bytes 262_144
  @max_notice_bytes 96

  @doc "The running application version."
  @spec current() :: String.t()
  def current do
    case :application.get_key(:rey_code, :vsn) do
      {:ok, vsn} -> to_string(vsn)
      :undefined -> "0.0.0"
    end
  end

  @doc "Whether the configured update check is enabled."
  @spec check_enabled?(ReyCode.RuntimeConfig.TUI.t()) :: boolean()
  def check_enabled?(%ReyCode.RuntimeConfig.TUI{} = tui), do: tui.update_check_enabled?

  @doc """
  Whether the session should auto-check for updates: enabled by configuration
  and running from a release build, never from a source checkout.
  """
  @spec auto_check?(ReyCode.RuntimeConfig.TUI.t()) :: boolean()
  def auto_check?(tui), do: check_enabled?(tui) and not Code.ensure_loaded?(Mix)

  @doc "Compares the running version with the latest published release."
  @spec check(ReyCode.RuntimeConfig.t()) :: {:ok, map()} | {:error, term()}
  def check(config \\ ReyCode.RuntimeConfig.fresh()) do
    if check_enabled?(config.tui) do
      do_check()
    else
      {:error, :update_check_disabled}
    end
  end

  defp do_check do
    with {:ok, payload} <- latest_release() do
      from_payload(payload)
    end
  rescue
    error -> {:error, {:update_check_failed, Exception.message(error)}}
  end

  @doc "One bounded operator-facing notice for an update, or `nil` when current."
  @spec notice(map()) :: String.t() | nil
  def notice(%{update?: false}), do: nil

  def notice(%{current: current, latest: latest}) do
    "Update available: #{current} → #{latest} · run `reycode update`"
    |> String.slice(0, @max_notice_bytes)
  end

  @doc """
  Checks for a newer release and delivers the update notice to `parent` as an
  `{:update_available, notice}` message; every other outcome stays silent.
  """
  @spec notify_when_newer(pid(), ReyCode.RuntimeConfig.t()) :: :ok
  def notify_when_newer(parent, config), do: deliver(parent, check(config))

  @doc "Delivers one check result to `parent` when it announces an update."
  @spec deliver(pid(), {:ok, map()} | {:error, term()}) :: :ok
  def deliver(parent, {:ok, %{update?: true} = info}) do
    send(parent, {:update_available, notice(info)})
    :ok
  end

  def deliver(_parent, _other), do: :ok

  @doc """
  Parses a GitHub latest-release payload into update info for the running
  version. Malformed payloads fail closed.
  """
  @spec from_payload(term()) :: {:ok, map()} | {:error, :invalid_update_payload}
  def from_payload(payload) when is_map(payload) do
    latest = payload["tag_name"]
    url = payload["html_url"]

    if is_binary(latest) and latest != "" do
      current = current()

      {:ok,
       %{
         current: current,
         latest: latest,
         update?: newer?(current, latest),
         url: if(is_binary(url), do: url, else: nil)
       }}
    else
      {:error, :invalid_update_payload}
    end
  end

  def from_payload(_payload), do: {:error, :invalid_update_payload}

  @spec latest_release() :: {:ok, term()} | {:error, term()}
  defp latest_release do
    request = {
      String.to_charlist(@latest_url),
      [
        {~c"user-agent", ~c"reycode-update-check"},
        {~c"accept", ~c"application/vnd.github+json"}
      ]
    }

    http_options = [timeout: @request_timeout_ms, connect_timeout: @request_timeout_ms]

    with {:ok, {{_http, 200, _phrase}, _headers, body}} <-
           :httpc.request(:get, request, http_options, body_format: :binary),
         :ok <- bounded_body(body),
         {:ok, payload} <- Jason.decode(body) do
      {:ok, payload}
    else
      {:ok, {{_http, status, _phrase}, _headers, _body}} ->
        {:error, {:update_http_status, status}}

      {:error, reason} ->
        {:error, {:update_http_error, reason}}
    end
  end

  defp bounded_body(body) when byte_size(body) <= @max_body_bytes, do: :ok
  defp bounded_body(_body), do: {:error, :update_payload_too_large}

  @spec newer?(String.t(), String.t()) :: boolean()
  defp newer?(current, latest) do
    with {:ok, current_version} <- Version.parse(current),
         {:ok, latest_version} <- Version.parse(String.trim_leading(latest, "v")) do
      Version.compare(latest_version, current_version) == :gt
    else
      _unparsable -> false
    end
  end
end
