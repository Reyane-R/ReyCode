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

  test "parses model identifiers and ignores non-model lines" do
    assert Discovery.parse_models("openai/gpt-5.6-sol\nnoise\nopenrouter/qwen/qwen3\n") ==
             ["openai/gpt-5.6-sol", "openrouter/qwen/qwen3"]
  end

  test "counts credentials from auth list output" do
    assert Discovery.credential_count("OpenAI oauth\nOpenRouter api\n2 credentials\n") == 2
    assert Discovery.credential_count("not signed in") == 0
  end
end
