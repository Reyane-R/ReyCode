defmodule ReyCode.Web.ErrorHTML do
  @moduledoc false

  # "404.html" -> "Not Found"; enough for a loopback, read-only view.
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end
