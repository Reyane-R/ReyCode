defmodule ReyCode.Tool.Glob do
  @moduledoc "Expands a glob pattern rooted within the trusted roots."
  @behaviour ReyCode.Tool

  alias ReyCode.Tool.{Request, Result, Support}

  @impl true
  def run(%Request{arguments: arguments} = request, _opts) do
    pattern = Support.arg(arguments, :pattern)

    with {:ok, canonical} <- Support.require_path(arguments, :path, request),
         :ok <- Support.require_present(pattern, :missing_pattern) do
      expanded = Path.join(canonical, pattern)
      Result.ok(Enum.join(Path.wildcard(expanded), "\n"))
    else
      {:error, reason} -> Result.error(reason)
    end
  end
end
