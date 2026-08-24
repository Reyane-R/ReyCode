defmodule ReyCode.Provider do
  @moduledoc """
  Logical interface implemented by streaming provider adapters.

  One `stream/3` call performs exactly one bounded ProviderRound. It may emit
  ordered display Frames and returns either a normalized Response or a typed
  Failure. Providers never execute tools, mutate orchestration state, retry,
  or schedule follow-up rounds. The caller owns the total deadline,
  cancellation, retry policy, frame durability, and Invocation recovery.
  Adapter implementations translate foreign faults at this seam.
  """

  alias ReyCode.Failure
  alias ReyCode.Provider.{Frame, Request, Response, Runtime}

  @type emit :: (Frame.t() -> :ok)
  @type result :: {:ok, Response.t()} | {:error, Failure.t()}

  @callback stream(Runtime.t(), Request.t(), emit()) :: result()
end
