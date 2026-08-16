defmodule ReyCode.Provider.OpenCode.DiscoveryTest do
  use ExUnit.Case, async: true

  alias ReyCode.Provider.OpenCode.Discovery

  test "discovers credentials and stable provider/model identifiers" do
    runner = fn _executable, args, _opts ->
      case args do
        ["--version"] -> {:ok, "1.18.11\n"}
        ["auth", "list"] -> {:ok, "OpenAI oauth\nOpenRouter api\n2 credentials\n"}
        ["models"] -> {:ok, "openai/gpt-5.6-sol\nnoise\nopenrouter/qwen/qwen3\n"}
      end
    end

    assert {:ok, discovery} =
             Discovery.discover(executable: "/tmp/opencode", runner: runner)

    assert discovery.version == "1.18.11"
    assert discovery.credential_count == 2
    assert discovery.models == ["openai/gpt-5.6-sol", "openrouter/qwen/qwen3"]
  end

  test "discovers models when display metadata commands fail" do
    runner = fn _executable, args, _opts ->
      case args do
        ["models"] -> {:ok, "openai/gpt-5.6-sol\n"}
        ["--version"] -> {:error, :timeout}
        ["auth", "list"] -> {:error, {:exit_status, 1, "not signed in"}}
      end
    end

    assert {:ok,
            %{
              executable: "/tmp/opencode",
              version: "unknown",
              credential_count: 0,
              models: ["openai/gpt-5.6-sol"]
            }} = Discovery.discover(executable: "/tmp/opencode", runner: runner)
  end

  test "returns a model command failure from discovery" do
    runner = fn _executable, ["models"], _opts ->
      {:error, {:exit_status, 7, "model catalog unavailable\n"}}
    end

    assert {:error, "model catalog unavailable"} =
             Discovery.discover(executable: "/tmp/opencode", runner: runner)
  end

  test "maps every command failure shape to a stable discovery error" do
    failures = [
      {{:error, :timeout}, :command_timeout},
      {{:error, {:exit_status, 7, ""}}, "command exited with status 7"},
      {{:error, {:output_limit_exceeded, 9}}, "command output exceeded 9 bytes"},
      {{:error, {:launch_failed, "spawn refused"}}, "spawn refused"},
      {{:error, :surprising}, :surprising}
    ]

    Enum.each(failures, fn {failure, expected} ->
      runner = fn _executable, ["models"], _opts -> failure end

      assert {:error, expected} =
               Discovery.discover(executable: "/tmp/opencode", runner: runner)
    end)
  end

  test "rescues metadata commands that raise or throw" do
    runner = fn _executable, args, _opts ->
      case args do
        ["models"] -> {:ok, "openai/gpt-5.6-sol\n"}
        ["--version"] -> raise "version probe exploded"
        ["auth", "list"] -> throw(:auth_threw)
      end
    end

    assert {:ok, %{version: "unknown", credential_count: 0}} =
             Discovery.discover(executable: "/tmp/opencode", runner: runner)
  end

  test "discovers through the default wrapper runner against a real executable" do
    path =
      Path.join(System.tmp_dir!(), "fake_opencode_discovery_#{System.unique_integer([:positive])}")

    File.write!(path, """
    #!/bin/sh
    case "$*" in
      *models*) printf 'openai/gpt-5.6-sol\\n' ;;
      *version*) printf '1.18.11\\n' ;;
      *auth*) printf 'OpenAI oauth\\n1 credential\\n' ;;
    esac
    """)

    File.chmod!(path, 0o700)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, discovery} = Discovery.discover(executable: path, timeout_ms: 5_000)
    assert discovery.version == "1.18.11"
    assert discovery.credential_count == 1
    assert discovery.models == ["openai/gpt-5.6-sol"]
    assert discovery.executable_identity != nil
  end

  test "keeps an unusable executable identity when identification fails" do
    runner = fn _executable, ["models"], _opts -> {:ok, "openai/gpt-5.6-sol\n"} end

    assert {:ok, %{executable_identity: nil}} =
             Discovery.discover(executable: "/nonexistent/opencode-probe", runner: runner)
  end

  test "parses model identifiers and ignores non-model lines" do
    assert Discovery.parse_models("openai/gpt-5.6-sol\nnoise\nopenrouter/qwen/qwen3\n") ==
             ["openai/gpt-5.6-sol", "openrouter/qwen/qwen3"]
  end

  test "counts credentials from auth list output" do
    assert Discovery.credential_count("OpenAI oauth\nOpenRouter api\n2 credentials\n") == 2
    assert Discovery.credential_count("not signed in") == 0
  end
end
