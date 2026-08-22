defmodule ReyCode.Provider do
  @moduledoc """
  Contract implemented by streaming agent providers.

  A provider performs exactly one model round per `stream/3` call: it emits
  display frames through `emit` and returns a normalized response containing
  the round's text and any tool calls. Providers never execute tools or drive
  follow-up rounds; ReyCode owns the tool loop.
  """

  alias ReyCode.Provider.{Frame, Request, Response, Runtime}

  @type emit :: (Frame.t() -> :ok)
  @type result :: {:ok, Response.t()} | {:error, map()}

  @callback stream(Runtime.t(), Request.t(), emit()) :: result()
end
