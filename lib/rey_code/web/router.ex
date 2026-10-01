defmodule ReyCode.Web.Router do
  @moduledoc false

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_query_params
    plug ReyCode.Web.Auth
    plug :put_root_layout, html: {ReyCode.Web.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/" do
    pipe_through :browser

    live_session :desktop, on_mount: ReyCode.Web.Auth do
      live "/", ReyCode.Web.SessionsLive
      live "/sessions/:id", ReyCode.Web.SessionLive
    end
  end
end
