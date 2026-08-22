defmodule ReyCode.Tool do
  @moduledoc "Behaviour implemented by workspace tools executed by ReyCode."

  alias ReyCode.Tool.{Request, Result}

  @callback run(Request.t(), keyword()) :: Result.t()
end
