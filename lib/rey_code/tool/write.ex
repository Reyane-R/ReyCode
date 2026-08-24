defmodule ReyCode.Tool.Write do
  @moduledoc "Writes (creating or overwriting) a file within the trusted roots."
  @behaviour ReyCode.Tool

  alias ReyCode.RuntimeConfig.Tools.Write, as: WritePolicy
  alias ReyCode.Tool.{Request, Result, Support}

  @impl true
  def run(%Request{arguments: arguments} = request, opts) do
    %WritePolicy{} = policy = Keyword.fetch!(opts, :policy)
    max_bytes = policy.max_bytes

    with {:ok, path} <- Support.require_arg(arguments, :path),
         {:ok, content} <- Support.require_arg(arguments, :content),
         :ok <- Support.require_present(path, :missing_path),
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
    end
  end

  defp require_size(content, max_bytes) do
    if byte_size(content) > max_bytes,
      do: {:error, :content_too_large},
      else: :ok
  end
end
