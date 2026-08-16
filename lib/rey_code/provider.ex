defmodule ReyCode.Provider do
  @moduledoc "Contract implemented by streaming agent providers."

  alias ReyCode.Provider.{Frame, Request, Runtime}

  @type emit :: (Frame.t() -> :ok)
  @type result :: {:ok, map()} | {:error, map()}

  @callback stream(Runtime.t(), Request.t(), emit()) :: result()
end
