defmodule ReyCode.Tool.BashTest do
  use ExUnit.Case, async: true

  alias ReyCode.RuntimeConfig
  alias ReyCode.Tool.{Bash, Request, Result}

  test "explicit environment is the entire source, filtered by policy, with no ambient fallback" do
    policy = RuntimeConfig.fresh(tool_bash_env_allowlist: ["CHECK_FIXTURE"]).tools.bash

    request =
      Request.new(
        tool: "bash",
        arguments: %{
          "command" =>
            "test -z \"$HOME\" && test -z \"$DENIED_FIXTURE\" && printf '%s' \"$CHECK_FIXTURE\""
        },
        workspace: File.cwd!(),
        roots: [File.cwd!()]
      )

    assert %Result{ok: true, output: "frozen"} =
             Bash.run(request,
               policy: policy,
               environment: %{
                 "PATH" => "/usr/bin:/bin",
                 "CHECK_FIXTURE" => "frozen",
                 "DENIED_FIXTURE" => "denied"
               }
             )
  end

  test "successful stderr is metadata without changing stdout output" do
    policy = RuntimeConfig.fresh().tools.bash

    request =
      Request.new(
        tool: "bash",
        arguments: %{"command" => "printf stdout; printf stderr >&2"},
        workspace: File.cwd!(),
        roots: [File.cwd!()]
      )

    assert %Result{
             ok: true,
             output: "stdout",
             metadata: %{"stderr" => "stderr", "exit_code" => 0}
           } =
             Bash.run(request, policy: policy)
  end

  test "non-UTF-8 streams produce a JSON-safe failure rather than invalid durable metadata" do
    for redirect <- ["", " >&2"] do
      request =
        Request.new(
          tool: "bash",
          arguments: %{"command" => "printf ok; printf '\\377'" <> redirect},
          workspace: File.cwd!(),
          roots: [File.cwd!()]
        )

      result = Bash.run(request, policy: RuntimeConfig.fresh().tools.bash)
      assert result.ok == false
      assert result.metadata["invalid_utf8"]
      assert {:ok, encoded} = Jason.encode(Result.to_wire(result))
      assert Jason.decode!(encoded)["metadata"]["invalid_utf8"]
    end
  end
end
