defmodule ReyCode.Tool.Write do
  @moduledoc "Writes (creating or overwriting) a file within the trusted roots."
  @behaviour ReyCode.Tool

  alias ReyCode.RuntimeConfig
  alias ReyCode.Tool.{Request, Result, Support}

  @max_bytes_default 512_000

  @impl true
  def run(%Request{arguments: arguments} = request, opts) do
    path = Support.arg(arguments, :path)
    content = Support.arg(arguments, :content, "")

    max_bytes =
      RuntimeConfig.policy(
        Keyword.fetch!(opts, :policy),
        :tool_write_max_bytes,
        @max_bytes_default
      )

    with :ok <- Support.require_present(path, :missing_path),
         true <- is_binary(content),
         :ok <- require_size(content, max_bytes),
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

  defp require_size(content, max_bytes) do
    if byte_size(content) > max_bytes,
      do: {:error, :content_too_large},
      else: :ok
  end
end
