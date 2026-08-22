defmodule ReyCode.Tool.Write do
  @moduledoc "Writes (creating or overwriting) a file within the trusted roots."
  @behaviour ReyCode.Tool

  alias ReyCode.Tool.{Request, Result, Support}

  @max_bytes_default 512_000

  defp max_bytes, do: Application.get_env(:rey_code, :tool_write_max_bytes, @max_bytes_default)

  @impl true
  def run(%Request{arguments: arguments} = request, _opts) do
    path = Support.arg(arguments, :path)
    content = Support.arg(arguments, :content, "")

    with :ok <- Support.require_present(path, :missing_path),
         true <- is_binary(content),
         :ok <- require_size(content),
         {:ok, canonical} <- Support.within_roots(path, request) do
      case File.write(canonical, content) do
        :ok ->
          Result.ok("wrote #{canonical}",
            metadata: %{"path" => canonical, "bytes" => byte_size(content)}
          )

        {:error, reason} ->
          Result.error(reason)
      end
    else
      {:error, reason} -> Result.error(reason)
      false -> Result.error(:invalid_content)
    end
  end

  defp require_size(content) do
    if byte_size(content) > max_bytes(),
      do: {:error, :content_too_large},
      else: :ok
  end
end
