defmodule ReyCode.VerifiedChangeCLITest do
  use ExUnit.Case, async: true

  alias ReyCode.CLI.Run

  test "ordinary parsing and runner options remain unchanged" do
    expected = %{prompt: "prompt", workspace: File.cwd!(), timeout_ms: 600_000, json?: false}
    assert Run.parse(["prompt"]) == {:ok, expected}
    assert Run.parse(["--no-verified", "prompt"]) == {:ok, expected}
    assert {:ok, %{timeout_ms: 3_600_001}} = Run.parse(["--timeout-ms", "3600001", "prompt"])

    assert {:ok, "ordinary"} =
             Run.execute(["prompt"],
               engine: self(),
               runner: fn options, engine ->
                 assert engine == self()
                 assert options == Map.delete(expected, :json?)
                 {:ok, %{outcome: :completed, response: "ordinary"}}
               end
             )
  end

  test "verified defaults preserve repeated command order and exact text" do
    commands = [" mix test ", "mix check", " mix test "]
    argv = ["--verified"] ++ Enum.flat_map(commands, &["--check", &1]) ++ ["prompt"]

    assert {:ok, options} = Run.parse(argv)

    assert options.verified == %{
             commands: commands,
             max_repair_count: 1,
             check_timeout_ms: 120_000
           }
  end

  test "accepts command count and byte boundaries" do
    for commands <- [
          ["x"],
          List.duplicate(String.duplicate("x", 4096), 8),
          [String.duplicate("é", 2048)]
        ] do
      argv = ["--verified"] ++ Enum.flat_map(commands, &["--check", &1]) ++ ["prompt"]
      assert {:ok, options} = Run.parse(argv)
      assert options.verified.commands == commands
    end
  end

  test "rejects missing, blank, invalid UTF-8, oversized and excessive checks" do
    for commands <- [
          [],
          [""],
          [" \t\n"],
          [<<255>>],
          [String.duplicate("x", 4097)],
          [String.duplicate("é", 2049)],
          List.duplicate("mix test", 9),
          ["mix test", " "]
        ] do
      argv = ["--verified"] ++ Enum.flat_map(commands, &["--check", &1]) ++ ["prompt"]
      assert {:error, message} = Run.parse(argv)
      assert message =~ "--check"
    end
  end

  test "verification-specific switches require explicit opt-in before reading input or running" do
    for args <- [
          ["--check", "mix test"],
          ["--max-repair-count", "1"],
          ["--check-timeout-ms", "120000"],
          ["--testing-provider", "deepseek"],
          ["--testing-model", "deepseek-chat"],
          ["--release-provider", "ollama"],
          ["--release-model", "llama3"]
        ],
        opt_in <- [[], ["--no-verified"]] do
      assert {:error, message} =
               Run.execute(opt_in ++ args,
                 stdin_reader: fn -> flunk("invalid flags must be rejected before stdin") end,
                 runner: fn _, _ -> flunk("invalid flags must not run") end
               )

      assert message =~ "require --verified"
    end
  end

  test "workflow stage flags require complete pairs and flow into verified options" do
    assert {:ok, options} =
             Run.parse([
               "--verified",
               "--check",
               "mix test",
               "--testing-provider",
               "deepseek",
               "--testing-model",
               "deepseek-chat",
               "--release-provider",
               "ollama",
               "--release-model",
               "llama3",
               "prompt"
             ])

    assert options.verified.testing_provider == "deepseek"
    assert options.verified.testing_model == "deepseek-chat"
    assert options.verified.release_provider == "ollama"
    assert options.verified.release_model == "llama3"

    assert {:ok, options} =
             Run.parse([
               "--verified",
               "--check",
               "mix test",
               "--testing-provider",
               "ollama",
               "--testing-model",
               "llama3",
               "prompt"
             ])

    assert options.verified.testing_provider == "ollama"
    assert Map.get(options.verified, :release_provider) == nil

    for args <- [
          ["--testing-provider", "deepseek"],
          ["--testing-model", "deepseek-chat"],
          ["--release-provider", "deepseek"],
          ["--release-model", "deepseek-chat"]
        ] do
      assert {:error, message} =
               Run.parse(["--verified", "--check", "mix test"] ++ args ++ ["prompt"])

      assert message =~ "complete pairs"
    end
  end

  test "accepts numeric boundaries" do
    for {flag, values, key} <- [
          {"--max-repair-count", [0, 3], :max_repair_count},
          {"--check-timeout-ms", [1, 600_000], :check_timeout_ms},
          {"--timeout-ms", [1, 3_600_000], :timeout_ms}
        ],
        value <- values do
      assert {:ok, options} =
               Run.parse(["--verified", "--check", "mix test", flag, to_string(value), "prompt"])

      config = if key == :timeout_ms, do: options, else: options.verified
      assert Map.fetch!(config, key) == value
    end
  end

  test "rejects out-of-range and malformed numeric options" do
    for {flag, values} <- [
          {"--max-repair-count", ["-1", "4", "1.5", "bad"]},
          {"--check-timeout-ms", ["0", "-1", "600001", "bad"]},
          {"--timeout-ms", ["0", "-1", "3600001", "bad"]}
        ],
        value <- values do
      assert {:error, _} = Run.parse(["--verified", "--check", "mix test", flag, value, "prompt"])
    end

    assert {:error, _} = Run.parse(["--verified", "--check"])
    assert {:error, _} = Run.parse(["--verified", "--unknown", "prompt"])
  end

  test "dispatches frozen coordinator options and exposes full success and failure JSON" do
    for outcome <- [:completed, :failed] do
      report = %{
        outcome: outcome,
        response: "response with evidence",
        session_id: "session-1",
        turn_id: nil,
        verification: %{commands: ["mix test", "mix check"], status: "passed"}
      }

      report = if outcome == :failed, do: Map.put(report, :error, "check failed"), else: report
      status = if outcome == :failed, do: :error, else: :ok

      assert {^status, encoded} =
               Run.execute(
                 [
                   "--verified",
                   "--check",
                   "mix test",
                   "--check",
                   "mix check",
                   "--max-repair-count",
                   "2",
                   "--check-timeout-ms",
                   "25",
                   "--timeout-ms",
                   "100",
                   "--json",
                   "prompt"
                 ],
                 engine: self(),
                 runner: fn options, engine ->
                   assert engine == self()

                   assert options == %{
                            prompt: "prompt",
                            workspace: File.cwd!(),
                            timeout_ms: 100,
                            commands: ["mix test", "mix check"],
                            max_repair_count: 2,
                            check_timeout_ms: 25
                          }

                   {status, report}
                 end
               )

      assert Jason.decode!(encoded) == Jason.decode!(Jason.encode!(report))
    end
  end

  test "human success preserves evidence response and failures include available context" do
    report = %{
      outcome: :failed,
      response: "",
      error: "verification failed",
      session_id: "session-1",
      turn_id: "turn-1",
      verification: %{status: "failed", commands: ["mix test"]}
    }

    assert {:error, output} =
             Run.execute(["--verified", "--check", "mix test", "prompt"],
               engine: self(),
               runner: fn _, _ -> {:error, report} end
             )

    for text <- ["verification failed", "session-1", "turn-1", "verification:", "mix test"] do
      assert output =~ text
    end

    assert {:ok, success} =
             Run.execute(["--verified", "--check", "mix test", "prompt"],
               engine: self(),
               runner: fn _, _ ->
                 {:ok, %{report | outcome: :completed, response: "response with evidence"}}
               end
             )

    assert success =~ "Verification: completed"
    assert success =~ "source not automatically applied"
    assert success =~ "session-1"
    assert success =~ "response with evidence"
    assert success =~ "mix test"
  end

  test "usage warns that check authorization is host execution, not sandboxing" do
    assert Run.usage() =~
             "explicitly authorizes bounded HOST shell command execution, not a sandbox"
  end
end
