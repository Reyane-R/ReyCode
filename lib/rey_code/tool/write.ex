defmodule ReyCode.Tool.Write do
  @moduledoc "Writes (creating or overwriting) a file within the trusted roots."
  @behaviour ReyCode.Tool

  alias ReyCode.Tool.{Request, Result, Support}

  @impl true
  def run(%Request{arguments: arguments} = request, _opts) do
    path = Support.arg(arguments, :path)
    content = Support.arg(arguments, :content, "")

    with :ok <- Support.require_present(path, :missing_path),
         true <- is_binary(content),
         {:ok, canonical} <- Support.within_roots(path, request) do
      case File.write(canonical, content) do
        :ok -> Result.ok("wrote #{canonical}")
        {:error, reason} -> Result.error(reason)
      end
    else
      {:error, reason} -> Result.error(reason)
      false -> Result.error(:invalid_content)
    end
  end
end
