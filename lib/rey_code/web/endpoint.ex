defmodule ReyCode.Web.Endpoint do
  @moduledoc """
  Loopback-only HTTP endpoint for the read-only web view of Sessions.

  It is a second client of the same Engine the TUI uses: LiveViews subscribe
  to projection broadcasts and never write events.
  """

  use Phoenix.Endpoint, otp_app: :rey_code

  @session_options [store: :cookie, key: "_rey_code_web", signing_salt: "reycode-web"]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.Static, at: "/assets/phoenix", from: {:phoenix, "priv/static"})
  plug(Plug.Static, at: "/assets/live_view", from: {:phoenix_live_view, "priv/static"})
  plug(Plug.Session, @session_options)
  plug(ReyCode.Web.Router)
end
