defmodule Mix.Tasks.ReyCode.Web do
  @shortdoc "Serves the read-only web view of Sessions on 127.0.0.1"

  @moduledoc """
  Starts ReyCode without the TUI and serves a read-only, live web view.

      mix rey_code.web            # http://127.0.0.1:4747
      mix rey_code.web --port 5000

  It attaches to the shared engine like any other client, so it can run next
  to an open TUI. It binds to loopback only; there is no authentication yet.
  """

  use Mix.Task

  alias ReyCode.Web.Endpoint

  @default_port 4747

  @impl true
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [port: :integer])
    port = Keyword.get(opts, :port, @default_port)

    Application.put_env(:rey_code, Endpoint,
      adapter: Bandit.PhoenixAdapter,
      http: [ip: {127, 0, 0, 1}, port: port],
      server: true,
      # ponytail: per-run secret, cookies reset on restart; persist one once auth exists.
      secret_key_base: Base.encode64(:crypto.strong_rand_bytes(48)),
      live_view: [signing_salt: "reycode-live"],
      check_origin: ["//127.0.0.1", "//localhost"]
    )

    {:ok, _apps} = ReyCode.Application.ensure_started_without_tui()
    {:ok, _pid} = Endpoint.start_link()
    Mix.shell().info("ReyCode web: http://127.0.0.1:#{port}")
    Process.sleep(:infinity)
  end
end
