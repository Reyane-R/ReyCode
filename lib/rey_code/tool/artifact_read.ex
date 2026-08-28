defmodule ReyCode.Tool.ArtifactRead do
  @moduledoc "Reads one bounded byte window from ReyCode's private artifact spool."

  @behaviour ReyCode.Tool

  alias ReyCode.ArtifactStore
  alias ReyCode.RuntimeConfig.Artifacts
  alias ReyCode.Tool.{Request, Result, Support}

  @impl true
  def run(%Request{arguments: arguments}, opts) do
    %Artifacts{} = policy = Keyword.fetch!(opts, :policy)

    with {:ok, artifact_id} <- Support.require_arg(arguments, :artifact_id),
         {:ok, offset} <- integer(arguments, :offset, 0, 0),
         {:ok, limit} <- integer(arguments, :limit, policy.preview_bytes, 1),
         {:ok, bytes, metadata} <- ArtifactStore.read(policy, artifact_id, offset, limit) do
      truncated? = offset + byte_size(bytes) < metadata["total_bytes"]
      Result.ok(bytes, truncated: truncated?, metadata: metadata)
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  defp integer(arguments, key, default, minimum) do
    case Support.integer_arg(arguments, key, default) do
      {:ok, value} when value >= minimum -> {:ok, value}
      _other -> {:error, :invalid_artifact_window}
    end
  end
end
