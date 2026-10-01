defmodule ReyCode.Web do
  @moduledoc """
  Starts the read-only web view (ReyCode Desktop) and opens it in a browser.

  Shared by `reycode desktop`, `mix rey_code.web`, and the TUI's `/desktop`.
  The endpoint runs under `ReyCode.Supervisor`, so it never takes the caller
  down with it, and binds to loopback only because there is no authentication.
  """

  alias ReyCode.Web.Endpoint

  @default_port 4747

  @spec default_port() :: pos_integer()
  def default_port, do: @default_port

  @spec url(pos_integer()) :: String.t()
  def url(port), do: "http://127.0.0.1:#{port}"

  @doc "Starts the endpoint once; a second call returns the running one."
  @spec start(pos_integer()) :: {:ok, pid()} | {:error, term()}
  def start(port \\ @default_port) do
    case Process.whereis(Endpoint) do
      nil -> start_endpoint(port)
      pid -> {:ok, pid}
    end
  end

  defp start_endpoint(port) do
    Application.put_env(:rey_code, Endpoint,
      adapter: Bandit.PhoenixAdapter,
      http: [ip: {127, 0, 0, 1}, port: port],
      server: true,
      # ponytail: per-run secret, cookies reset on restart; persist one once auth exists.
      secret_key_base: Base.encode64(:crypto.strong_rand_bytes(48)),
      live_view: [signing_salt: "reycode-live"],
      check_origin: ["//127.0.0.1", "//localhost"],
      render_errors: [formats: [html: ReyCode.Web.ErrorHTML], layout: false]
    )

    case Supervisor.start_child(ReyCode.Supervisor, Endpoint) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, :already_present} -> restart_endpoint()
      {:error, reason} -> {:error, reason}
    end
  end

  defp restart_endpoint do
    case Supervisor.restart_child(ReyCode.Supervisor, Endpoint) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Asks the OS to open a URL in the default browser."
  @spec open_browser(String.t()) :: :ok | {:error, :browser_unavailable}
  def open_browser(url) do
    case Enum.find_value(["open", "xdg-open"], &System.find_executable/1) do
      nil ->
        {:error, :browser_unavailable}

      opener ->
        case System.cmd(opener, [url], stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {_output, _status} -> {:error, :browser_unavailable}
        end
    end
  end

  @doc "Human-readable reason for a failed start, naming the port when it is taken."
  @spec describe_error(term(), pos_integer()) :: String.t()
  def describe_error(reason, port) do
    if inspect(reason) =~ "eaddrinuse",
      do:
        "Port #{port} is already in use. If ReyCode Desktop is already running, open #{url(port)}.",
      else: "Could not start ReyCode Desktop: #{inspect(reason)}"
  end
end
