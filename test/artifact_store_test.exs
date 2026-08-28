defmodule ReyCode.ArtifactStoreTest do
  use ExUnit.Case, async: true

  alias ReyCode.ArtifactStore
  alias ReyCode.RuntimeConfig.Artifacts
  alias ReyCode.Tool.{ArtifactRead, Request, Result}

  test "spools large output, returns a page reference, and enforces retained bounds" do
    root = Path.join(System.tmp_dir!(), "artifacts-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    policy = %Artifacts{
      root: root,
      spool_threshold_bytes: 100,
      preview_bytes: 64,
      max_artifact_bytes: 512,
      max_artifact_count: 2
    }

    result = Result.ok(String.duplicate("first line\n", 100))
    spooled = ArtifactStore.spool(result, policy, "inv-1", "run-1")
    artifact_id = spooled.metadata["artifact_id"]

    assert spooled.truncated
    assert spooled.output =~ "artifact://#{artifact_id}"
    assert spooled.metadata["artifact_bytes"] == 512
    refute spooled.metadata["artifact_complete"]

    assert {:ok, bytes, metadata} = ArtifactStore.read(policy, artifact_id, 0, 64)
    assert byte_size(bytes) == 64
    assert metadata["total_bytes"] == 512

    request =
      Request.new(
        tool: "artifact_read",
        arguments: %{"artifact_id" => artifact_id, "offset" => 64, "limit" => 64},
        workspace: "/tmp"
      )

    assert %Result{ok: true, truncated: true, metadata: %{"offset" => 64}} =
             ArtifactRead.run(request, policy: policy)

    Enum.each(2..3, fn index ->
      output = String.duplicate("artifact-#{index}\n", 50)
      ArtifactStore.spool(Result.ok(output), policy, "inv-#{index}", "run-#{index}")
    end)

    assert length(ArtifactStore.list(policy)) == 2
  end

  test "small results stay inline and invalid artifact IDs fail closed" do
    root = Path.join(System.tmp_dir!(), "artifacts-small-#{System.unique_integer([:positive])}")

    policy = %Artifacts{
      root: root,
      spool_threshold_bytes: 100,
      preview_bytes: 32,
      max_artifact_bytes: 512,
      max_artifact_count: 2
    }

    result = Result.ok("small")

    assert ArtifactStore.spool(result, policy, "inv", "run") == result
    assert {:error, :invalid_artifact_id} = ArtifactStore.read(policy, "../escape", 0, 10)
  end
end
