defmodule ReyCode.Web.Auth do
  @moduledoc """
  Fails closed unless the browser presented this VM's access token.

  The token arrives once as `?token=` from `ReyCode.Web.open_url/1`, moves
  into the signed session cookie, and the URL is cleaned by a redirect. Both
  the HTTP render and the LiveView socket mount check it.
  """

  import Plug.Conn

  alias ReyCode.Web

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    cond do
      Web.valid_token?(conn.query_params["token"]) ->
        conn
        |> put_session(:token, conn.query_params["token"])
        |> Phoenix.Controller.redirect(to: conn.request_path)
        |> halt()

      Web.valid_token?(get_session(conn, :token)) ->
        conn

      true ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(
          403,
          "Open ReyCode Desktop with /desktop in the TUI or `reycode desktop`; " <>
            "this browser does not have the access token."
        )
        |> halt()
    end
  end

  @doc false
  def on_mount(:default, _params, session, socket) do
    if Web.valid_token?(session["token"]),
      do: {:cont, socket},
      else: {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
  end
end
