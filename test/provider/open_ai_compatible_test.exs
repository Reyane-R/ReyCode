defmodule ReyCode.Provider.OpenAICompatibleTest do
  use ExUnit.Case, async: false

  alias ReyCode.Failure

  alias ReyCode.OpenAICompatible.FakeTransport

  alias ReyCode.Provider.{
    Frame,
    Message,
    OpenAICompatible,
    OpenAICompatible.Profile,
    OpenAICompatible.RequestShape,
    Request,
    Response,
    Runtime,
    ToolCall
  }

  alias ReyCode.RuntimeConfig

  @key_env "DEEPSEEK_API_KEY"

  setup do
    FakeTransport.clear()
    RequestShape.clear()
    System.put_env(@key_env, "test-key")

    on_exit(fn ->
      System.delete_env(@key_env)
      FakeTransport.clear()
      RequestShape.clear()
    end)

    :ok
  end

  describe "discover/2" do
    test "reports available without a network call when the key is absent" do
      System.delete_env(@key_env)
      {:ok, profile} = Profile.fetch(:deepseek)

      assert {:ok, %{status: :available, models: [], credential_count: 0}} =
               OpenAICompatible.discover(profile, transport: FakeTransport)
    end

    test "parses the model list from /models when the key is present" do
      FakeTransport.set_models(~s({"data":[{"id":"deepseek-chat"},{"id":"deepseek-reasoner"}]}))
      {:ok, profile} = Profile.fetch(:deepseek)

      assert {:ok,
              %{
                status: :configured,
                models: ["deepseek-chat", "deepseek-reasoner"],
                credential_count: 1
              }} = OpenAICompatible.discover(profile, transport: FakeTransport)

      assert FakeTransport.last_request().method == :get
      assert FakeTransport.last_request().body == nil
    end

    test "allows a valid empty model list" do
      FakeTransport.set_models(~s({"data":[]}))
      {:ok, profile} = Profile.fetch(:deepseek)

      assert {:ok, %{status: :configured, models: [], credential_count: 1, error: nil}} =
               OpenAICompatible.discover(profile, transport: FakeTransport)
    end

    test "fails closed for every malformed model response" do
      {:ok, profile} = Profile.fetch(:deepseek)

      malformed = [
        "not-json",
        "null",
        "[]",
        ~s({}),
        ~s({"data":null}),
        ~s({"data":{}}),
        ~s({"data":[42]}),
        ~s({"data":[{}]}),
        ~s({"data":[{"id":null}]}),
        ~s({"data":[{"id":""}]})
      ]

      for body <- malformed do
        FakeTransport.set_models(body)

        assert {:ok, %{status: :error, models: [], credential_count: 1, error: error}} =
                 OpenAICompatible.discover(profile, transport: FakeTransport)

        assert is_binary(error)
      end
    end

    test "bounds model response accumulation" do
      FakeTransport.set_models(~s({"data":[{"id":"too-large"}]}))
      {:ok, profile} = Profile.fetch(:deepseek)

      assert {:ok, %{status: :error, error: "Model response exceeded 8 bytes"}} =
               OpenAICompatible.discover(profile,
                 transport: FakeTransport,
                 max_response_bytes: 8
               )
    end

    test "folds a discovery failure into an error status" do
      FakeTransport.set_models_status(429, ~s({"error":{"message":"slow down"}}))
      {:ok, profile} = Profile.fetch(:deepseek)

      assert {:ok, %{status: :error, models: [], error: "slow down"}} =
               OpenAICompatible.discover(profile, transport: FakeTransport)
    end
  end

  describe "stream/3" do
    test "emits text deltas parsed from the SSE response" do
      FakeTransport.set_stream([
        ~s(data: {"choices":[{"delta":{"content":"Hello "}}]}\n\n),
        ~s(data: {"choices":[{"delta":{"content":"there"}}]}\n\n),
        ~s(data: {"choices":[],"usage":{"prompt_tokens":2,"completion_tokens":2}}\n\n),
        "data: [DONE]\n\n"
      ])

      frames =
        collect_frames(fn emit ->
          wire_result(OpenAICompatible.stream(runtime(), request(), emit))
        end)

      {result, emitted} = frames

      assert {:ok, %Response{usage: %{"prompt_tokens" => 2, "completion_tokens" => 2}}} = result

      assert [
               %Frame{sequence: 1, kind: :text_delta, data: %{text: "Hello "}},
               %Frame{sequence: 2, kind: :text_delta, data: %{text: "there"}}
             ] = emitted
    end

    test "flushes a short text delta while the transport remains silent" do
      token = make_ref()
      test_pid = self()

      FakeTransport.set_stream([
        ~s(data: {"choices":[{"delta":{"content":"latency bounded"}}]}\n\n),
        {:pause, test_pid, token},
        "data: [DONE]\n\n"
      ])

      task =
        Task.async(fn ->
          policy = [
            openai_compatible_chunk_bytes: 1_000,
            openai_compatible_chunk_latency_ms: 50
          ]

          wire_result(
            OpenAICompatible.stream(runtime(policy), request(), fn frame ->
              send(test_pid, {:frame, frame})
              :ok
            end)
          )
        end)

      assert_receive {:transport_paused, ^token, producer}, 500

      assert_receive {:frame, %Frame{kind: :text_delta, data: %{text: "latency bounded"}}},
                     500

      assert Task.yield(task, 0) == nil
      send(producer, {token, :resume})
      assert {:ok, %Response{text: "latency bounded"}} = Task.await(task, 1_000)
      refute_receive {:frame, %Frame{kind: :text_delta, data: %{text: "latency bounded"}}}
    end

    test "starts emitted frame sequence from request.resume_from" do
      FakeTransport.set_stream([
        ~s(data: {"choices":[{"delta":{"content":"Hello "}}]}\n\n),
        ~s(data: {"choices":[{"delta":{"content":"there"}}]}\n\n),
        ~s(data: [DONE]\n\n)
      ])

      frames =
        collect_frames(fn emit ->
          wire_result(OpenAICompatible.stream(runtime(), %{request() | resume_from: 10}, emit))
        end)

      {_result, emitted} = frames

      assert Enum.map(emitted, & &1.sequence) == [11, 12]
    end

    test "assembles streamed tool-call fragments into one normalized response" do
      FakeTransport.set_stream([
        ~s(data: {"choices":[{"delta":{"tool_calls":[{"id":"call-1","index":0,"type":"function","function":{"name":"bash","arguments":"{\\\"cmd"}}]}}]}\n\n),
        ~s(data: {"choices":[{"delta":{"tool_calls":[{"id":"call-1","index":0,"function":{"arguments":"\\\":\\\"date\\\"}"}}]}}]}\n\n),
        ~s(data: {"choices":[{"finish_reason":"tool_calls","delta":{}}]}\n\n)
      ])

      frames =
        collect_frames(fn emit ->
          wire_result(OpenAICompatible.stream(runtime(), request(), emit))
        end)

      {result, emitted} = frames

      assert {:ok,
              %Response{
                text: "",
                tool_calls: [
                  %ToolCall{id: "call-1", tool: "bash", arguments: %{"cmd" => "date"}}
                ]
              }} = result

      assert emitted == []
    end

    test "assembles several parallel calls from one round in order" do
      FakeTransport.set_stream([
        ~s(data: {"choices":[{"delta":{"tool_calls":[{"id":"call-1","index":0,"type":"function","function":{"name":"read","arguments":"{\\"path\\":\\"a.txt\\"}"}}]}}]}\n\n),
        ~s(data: {"choices":[{"delta":{"tool_calls":[{"id":"call-2","index":1,"type":"function","function":{"name":"list","arguments":"{}"}}]}}]}\n\n),
        ~s(data: {"choices":[{"finish_reason":"tool_calls","delta":{}}]}\n\n)
      ])

      {:ok, %Response{tool_calls: calls}} =
        wire_result(OpenAICompatible.stream(runtime(), request(), fn _frame -> :ok end))

      assert Enum.map(calls, &{&1.id, &1.tool}) == [{"call-1", "read"}, {"call-2", "list"}]
    end

    test "drives a complete two-round conversation through the one-round contract" do
      # Round 1: the model asks for a tool.
      FakeTransport.set_stream([
        ~s(data: {"choices":[{"delta":{"tool_calls":[{"id":"call-9","index":0,"type":"function","function":{"name":"read","arguments":"{\\"path\\":\\"hello.txt\\"}"}}]}}]}\n\n),
        ~s(data: {"choices":[{"finish_reason":"tool_calls","delta":{}}]}\n\n),
        "data: [DONE]\n\n"
      ])

      {:ok, round_one} =
        wire_result(OpenAICompatible.stream(runtime(), request(), fn _frame -> :ok end))

      assert [%ToolCall{id: "call-9"} = call] = round_one.tool_calls

      # Round 2: ReyCode rebuilds the conversation from durable state — the
      # original user turn, the assistant's tool-call batch, and the durable
      # tool result — never from provider-local recursion state.
      continuation = %{
        request()
        | round_index: 1,
          messages: [
            %{role: :user, content: "Hi", author: %{id: "user", name: "You"}},
            Message.new(role: :assistant, content: "", tool_calls: [call]),
            Message.new(
              role: :tool,
              content:
                Jason.encode!(%{
                  "ok" => true,
                  "output" => "file body",
                  "error" => nil,
                  "truncated" => false,
                  "metadata" => %{}
                }),
              tool_call_id: "call-9",
              name: "read"
            )
          ]
      }

      FakeTransport.set_stream([
        ~s(data: {"choices":[{"delta":{"content":"The file says: file body"}}]}\n\n),
        ~s(data: {"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":6}}\n\n),
        "data: [DONE]\n\n"
      ])

      {:ok, round_two} =
        wire_result(OpenAICompatible.stream(runtime(), continuation, fn _frame -> :ok end))

      assert round_two.text == "The file says: file body"
      assert round_two.tool_calls == []
      assert round_two.usage == %{"prompt_tokens" => 5, "completion_tokens" => 6}

      # The wire body must carry the tool result keyed by call ID.
      body = Jason.decode!(FakeTransport.last_body())
      roles = Enum.map(body["messages"], & &1["role"])

      assert roles == ["system", "user", "assistant", "tool"]

      assert List.last(body["messages"]) == %{
               "role" => "tool",
               "tool_call_id" => "call-9",
               "content" =>
                 Jason.encode!(%{
                   "ok" => true,
                   "output" => "file body",
                   "error" => nil,
                   "truncated" => false,
                   "metadata" => %{}
                 })
             }

      assert [%{"id" => "call-9", "type" => "function"}] =
               body["messages"] |> Enum.at(2) |> Map.get("tool_calls")

      assert FakeTransport.last_request().method == :post
      assert is_binary(FakeTransport.last_request().body)
    end

    test "rejects malformed tool-call arguments as an incomplete tool response" do
      FakeTransport.set_stream([
        # Truncated JSON…
        ~s(data: {"choices":[{"delta":{"tool_calls":[{"id":"call-a","index":0,"function":{"name":"bash","arguments":"{\\"cmd\\""}}]}}]}\n\n),
        # …a non-object payload…
        ~s(data: {"choices":[{"delta":{"tool_calls":[{"id":"call-b","index":1,"function":{"name":"list","arguments":"[1,2]"}}]}}]}\n\n),
        # …and a null payload must all survive normalization.
        ~s(data: {"choices":[{"delta":{"tool_calls":[{"id":"call-c","index":2,"function":{"name":"glob"}}]}}]}\n\n),
        ~s(data: {"choices":[{"finish_reason":"tool_calls","delta":{}}]}\n\n)
      ])

      assert {:error,
              %{
                "category" => "protocol_error",
                "message" => "Provider returned an invalid streaming response"
              }} =
               wire_result(OpenAICompatible.stream(runtime(), request(), fn _frame -> :ok end))
    end

    test "fails closed for malformed and content-free successful streams" do
      invalid_streams = [
        [],
        [": keepalive\n\n"],
        ["data: [DONE]\n\n"],
        [~s(data: {"choices":[],"usage":{"prompt_tokens":1}}\n\n), "data: [DONE]\n\n"],
        ["data: not-json\n\n"],
        [~s(data: {"choices":[42]}\n\n)],
        [
          ~s(data: {"choices":[{"delta":{"content":"prefix"}}]}\n\n),
          ~s(data: {"choices":[{"delta":{},"finish_reason":42}]}\n\n)
        ],
        [~s(data: {"choices":[{"delta":{"content":42}}]}\n\n)],
        [~s(data: {"choices":[{"delta":{"tool_calls":{}}}]}\n\n)]
      ]

      for chunks <- invalid_streams do
        FakeTransport.set_stream(chunks)

        assert {:error,
                %{
                  "category" => "protocol_error",
                  "message" => "Provider returned an invalid streaming response"
                }} =
                 wire_result(OpenAICompatible.stream(runtime(), request(), fn _frame -> :ok end))
      end
    end

    test "does not expose malformed provider data in protocol errors" do
      FakeTransport.set_stream(["data: provider-secret-payload\n\n"])

      assert {:error, error} =
               wire_result(OpenAICompatible.stream(runtime(), request(), fn _frame -> :ok end))

      assert error["category"] == "protocol_error"
      refute inspect(error) =~ "provider-secret-payload"
    end

    test "accepts clean EOF after text but rejects malformed or unterminated tails" do
      text = ~s(data: {"choices":[{"delta":{"content":"valid"}}]}\n\n)

      FakeTransport.set_stream([text])

      assert {:ok, %Response{text: "valid"}} =
               wire_result(OpenAICompatible.stream(runtime(), request(), fn _frame -> :ok end))

      for tail <- ["data: not-json\n\n", "data: {\"choices\":"] do
        FakeTransport.set_stream([text, tail])

        assert {:error, %{"category" => "protocol_error"}} =
                 wire_result(OpenAICompatible.stream(runtime(), request(), fn _frame -> :ok end))
      end
    end

    test "rejects a started tool that never completes" do
      FakeTransport.set_stream([
        ~s(data: {"choices":[{"delta":{"tool_calls":[{"id":"call-1","index":0,"function":{"name":"read","arguments":"{}"}}]}}]}\n\n),
        "data: [DONE]\n\n"
      ])

      assert {:error, %{"category" => "protocol_error"}} =
               wire_result(OpenAICompatible.stream(runtime(), request(), fn _frame -> :ok end))
    end

    test "returns a missing credentials error when the key is unset" do
      System.delete_env(@key_env)

      assert {:error, %{"category" => "missing_credentials", "retryable" => false}} =
               wire_result(OpenAICompatible.stream(runtime(), request(), fn _frame -> :ok end))
    end

    test "maps a rate-limit status to a retryable error" do
      FakeTransport.set_stream_status(429, ~s({"error":{"message":"slow down"}}))

      assert {:error, %{"category" => "rate_limited", "retryable" => true, "message" => message}} =
               wire_result(OpenAICompatible.stream(runtime(), request(), fn _frame -> :ok end))

      assert message =~ "slow down"
    end

    test "maps an authentication failure to a non-retryable error" do
      FakeTransport.set_stream_status(401, ~s({"error":{"message":"bad key"}}))

      assert {:error, %{"category" => "authentication_failed", "retryable" => false}} =
               wire_result(OpenAICompatible.stream(runtime(), request(), fn _frame -> :ok end))
    end

    test "contains transport raises, throws, and exits without linking them to the caller" do
      previous = Process.flag(:trap_exit, true)
      on_exit(fn -> Process.flag(:trap_exit, previous) end)

      for failure <- [:raise, :throw, :exit] do
        FakeTransport.set_stream_failure(failure)

        assert {:error, %{"category" => "launch_failed"}} =
                 wire_result(OpenAICompatible.stream(runtime(), request(), fn _frame -> :ok end))

        refute_receive {:EXIT, _pid, _reason}, 0
      end
    end

    test "halts and errors when output exceeds the profile limit" do
      System.put_env("TINY_API_KEY", "tiny-key")

      FakeTransport.set_stream([
        ~s(data: {"choices":[{"delta":{"content":"this is far too long to fit"}}]}\n\n),
        "data: [DONE]\n\n"
      ])

      runtime = %Runtime{
        module: OpenAICompatible,
        provider_id: :tiny,
        status: :configured,
        config:
          RuntimeConfig.fresh(
            openai_compatible_transport: FakeTransport,
            openai_compatible_providers: [
              %{
                id: :tiny,
                name: "Tiny",
                base_url: "https://example.test",
                key_env: "TINY_API_KEY",
                max_output_bytes: 8
              }
            ]
          ).open_ai
      }

      assert {:error, %{"category" => "output_too_large", "retryable" => false}} =
               wire_result(OpenAICompatible.stream(runtime, request(), fn _frame -> :ok end))
    after
      System.delete_env("TINY_API_KEY")
    end

    test "streams reasoning deltas as agent_note frames without touching the body" do
      FakeTransport.set_stream([
        ~s(data: {"choices":[{"delta":{"reasoning_content":"thinking hard"}}]}\n\n),
        ~s(data: {"choices":[{"delta":{"content":"Answer"}}]}\n\n),
        ~s(data: {"choices":[{"delta":{"reasoning":"more thought"}}]}\n\n),
        "data: [DONE]\n\n"
      ])

      {result, emitted} =
        collect_frames(fn emit ->
          wire_result(OpenAICompatible.stream(runtime(), request(), emit))
        end)

      assert {:ok, %Response{text: "Answer"}} = result

      assert emitted == [
               %Frame{sequence: 1, kind: :agent_note, data: %{note: "thinking hard"}},
               %Frame{sequence: 2, kind: :text_delta, data: %{text: "Answer"}},
               %Frame{sequence: 3, kind: :agent_note, data: %{note: "more thought"}}
             ]
    end

    test "coalesces adjacent reasoning token deltas into one activity frame" do
      FakeTransport.set_stream([
        ~s(data: {"choices":[{"delta":{"reasoning":"thinking"}}]}\n\n),
        ~s(data: {"choices":[{"delta":{"reasoning":" hard"}}]}\n\n),
        ~s(data: {"choices":[{"delta":{"reasoning":" now"}}]}\n\n),
        ~s(data: {"choices":[{"delta":{"content":"Answer"}}]}\n\n),
        "data: [DONE]\n\n"
      ])

      {result, emitted} =
        collect_frames(fn emit ->
          wire_result(OpenAICompatible.stream(runtime(), request(), emit))
        end)

      assert {:ok, %Response{text: "Answer"}} = result

      assert emitted == [
               %Frame{sequence: 1, kind: :agent_note, data: %{note: "thinking hard now"}},
               %Frame{sequence: 2, kind: :text_delta, data: %{text: "Answer"}}
             ]
    end

    test "non-binary reasoning values are ignored without failing the stream" do
      FakeTransport.set_stream([
        ~s(data: {"choices":[{"delta":{"reasoning":42}}]}\n\n),
        ~s(data: {"choices":[{"delta":{"content":"ok"}}]}\n\n),
        "data: [DONE]\n\n"
      ])

      {result, emitted} =
        collect_frames(fn emit ->
          wire_result(OpenAICompatible.stream(runtime(), request(), emit))
        end)

      assert {:ok, %Response{text: "ok"}} = result
      assert [%Frame{kind: :text_delta}] = emitted
    end

    test "a reasoning-only stream fails closed as content-free output" do
      FakeTransport.set_stream([
        ~s(data: {"choices":[{"delta":{"reasoning_content":"only thinking"}}]}\n\n),
        "data: [DONE]\n\n"
      ])

      {result, emitted} =
        collect_frames(fn emit ->
          wire_result(OpenAICompatible.stream(runtime(), request(), emit))
        end)

      assert {:error, %{"category" => "protocol_error"}} = result
      assert [%Frame{kind: :agent_note}] = emitted
    end
  end

  describe "keyless profiles" do
    test "exposes built-in Ollama and LM Studio profiles on loopback endpoints" do
      assert {:ok, ollama} = Profile.fetch(:ollama)
      assert ollama.name == "Ollama"
      assert ollama.base_url == "http://localhost:11434/v1"
      refute ollama.require_key

      assert {:ok, lmstudio} = Profile.fetch(:lmstudio)
      assert lmstudio.name == "LM Studio"
      assert lmstudio.base_url == "http://localhost:1234/v1"
      refute lmstudio.require_key
    end

    test "discovery never sends Authorization for a keyless profile" do
      FakeTransport.set_models(~s({"data":[{"id":"llama3"}]}))
      {:ok, profile} = Profile.fetch(:ollama)

      assert {:ok, %{status: :configured, models: ["llama3"], credential_count: 0}} =
               OpenAICompatible.discover(profile, transport: FakeTransport)

      refute authorization_header?(FakeTransport.last_request().headers)
    end

    test "streaming never sends Authorization for a keyless profile" do
      FakeTransport.set_stream([
        ~s(data: {"choices":[{"delta":{"content":"hello"}}]}\n\n),
        "data: [DONE]\n\n"
      ])

      assert {:ok, %Response{text: "hello"}} =
               wire_result(
                 OpenAICompatible.stream(local_runtime(:ollama), request(), fn _frame -> :ok end)
               )

      refute authorization_header?(FakeTransport.last_request().headers)
    end

    test "discovery matrix covers valid, empty, malformed, and non-2xx for both profiles" do
      for id <- [:ollama, :lmstudio] do
        {:ok, profile} = Profile.fetch(id)

        FakeTransport.set_models(~s({"data":[{"id":"local-model"}]}))

        assert {:ok, %{status: :configured, models: ["local-model"], credential_count: 0}} =
                 OpenAICompatible.discover(profile, transport: FakeTransport)

        assert FakeTransport.last_request().method == :get

        assert FakeTransport.last_request().url ==
                 "#{String.trim_trailing(profile.base_url, "/")}/models"

        FakeTransport.set_models(~s({"data":[]}))

        assert {:ok, %{status: :configured, models: []}} =
                 OpenAICompatible.discover(profile, transport: FakeTransport)

        FakeTransport.set_models(~s({"data":[{"id":42}]}))

        assert {:ok, %{status: :error, models: [], error: error}} =
                 OpenAICompatible.discover(profile, transport: FakeTransport)

        assert is_binary(error)

        FakeTransport.set_models_status(503, ~s({"error":{"message":"warming up"}}))

        assert {:ok, %{status: :error, error: "warming up"}} =
                 OpenAICompatible.discover(profile, transport: FakeTransport)

        # The non-2xx stub must not leak into the next profile's iteration.
        FakeTransport.clear()
      end
    end

    test "a configured profile may opt out of credentials entirely" do
      config =
        RuntimeConfig.fresh(
          openai_compatible_providers: [
            %{
              id: :vllm_local,
              name: "vLLM",
              base_url: "http://localhost:8000/v1",
              require_key: false
            }
          ]
        )

      assert {:ok, profile} = Profile.fetch(:vllm_local, config.open_ai)
      refute profile.require_key

      FakeTransport.set_models(~s({"data":[{"id":"qwen"}]}))

      assert {:ok, %{status: :configured, models: ["qwen"], credential_count: 0}} =
               OpenAICompatible.discover(profile, transport: FakeTransport)

      refute authorization_header?(FakeTransport.last_request().headers)
    end

    test "a profile without require_key still demands a key env at configuration time" do
      assert_raise ArgumentError, ~r/key_env/, fn ->
        RuntimeConfig.fresh(
          openai_compatible_providers: [
            %{id: :broken, name: "Broken", base_url: "https://example.test"}
          ]
        )
      end
    end

    test "an invalid require_key flag fails configuration" do
      assert_raise ArgumentError, ~r/require_key/, fn ->
        RuntimeConfig.fresh(
          openai_compatible_providers: [
            %{
              id: :broken,
              name: "Broken",
              base_url: "https://example.test",
              key_env: "BROKEN_KEY",
              require_key: "no"
            }
          ]
        )
      end
    end
  end

  describe "capability downgrade" do
    @success_stream [
      ~s(data: {"choices":[{"delta":{"content":"ok"}}]}\n\n),
      "data: [DONE]\n\n"
    ]

    test "retries once without stream_options on HTTP 400 and keeps tools" do
      FakeTransport.set_stream_script([
        {:status, 400, ~s({"error":{"message":"unknown field stream_options"}})},
        {:chunks, @success_stream}
      ])

      assert {:ok, %Response{text: "ok"}} =
               wire_result(OpenAICompatible.stream(runtime(), request(), fn _frame -> :ok end))

      assert [first, second] = Enum.map(FakeTransport.requests(), &Jason.decode!(&1.body))
      assert Map.has_key?(first, "stream_options")
      assert Map.has_key?(first, "tools")
      refute Map.has_key?(second, "stream_options")
      assert Map.has_key?(second, "tools")
    end

    test "advertises orchestration and hash-anchored edit schemas on the wire" do
      FakeTransport.set_stream_script([{:chunks, @success_stream}])

      assert {:ok, %Response{}} =
               wire_result(OpenAICompatible.stream(runtime(), request(), fn _frame -> :ok end))

      body =
        FakeTransport.requests()
        |> List.last()
        |> Map.fetch!(:body)
        |> Jason.decode!()

      tools = body["tools"]
      names = Enum.map(tools, & &1["function"]["name"])
      assert "spawn_task" in names
      assert "spawn_tasks" in names
      assert "send_peer" in names
      assert "ask_operator" in names
      assert "update_plan" in names
      assert "read" in names
      assert "memory" in names

      spawn_task = Enum.find(tools, &(&1["function"]["name"] == "spawn_task"))
      spawn_tasks = Enum.find(tools, &(&1["function"]["name"] == "spawn_tasks"))
      send_peer = Enum.find(tools, &(&1["function"]["name"] == "send_peer"))
      ask_operator = Enum.find(tools, &(&1["function"]["name"] == "ask_operator"))
      update_plan = Enum.find(tools, &(&1["function"]["name"] == "update_plan"))
      memory = Enum.find(tools, &(&1["function"]["name"] == "memory"))

      assert spawn_task["type"] == "function"
      assert spawn_task["function"]["parameters"]["properties"]["agent"]
      assert spawn_task["function"]["parameters"]["properties"]["brief"]
      assert spawn_task["function"]["parameters"]["properties"]["detach"]
      assert spawn_tasks["function"]["parameters"]["properties"]["tasks"]["maxItems"] == 8
      assert spawn_tasks["function"]["parameters"]["properties"]["integrator"]
      assert send_peer["function"]["parameters"]["required"] == ["target", "body"]
      assert ask_operator["function"]["parameters"]["properties"]["options"]["minItems"] == 2
      assert ask_operator["function"]["parameters"]["properties"]["options"]["maxItems"] == 5

      assert update_plan["function"]["parameters"]["properties"]["action"]["enum"] ==
               ["init", "start", "done", "block", "unblock", "drop"]

      assert memory["function"]["description"] =~ "Record kind=decision"
      assert memory["function"]["description"] =~ "ask_operator"

      assert memory["function"]["parameters"]["properties"]["kind"]["enum"] ==
               ~w(decision assumption fact lesson)

      assert memory["function"]["parameters"]["properties"]["evidence"]["description"] =~
               "Concrete"

      edit = Enum.find(tools, &(&1["function"]["name"] == "edit"))
      edit_parameters = edit["function"]["parameters"]

      assert edit_parameters["required"] == ["path", "source_hash", "patches"]
      assert edit_parameters["additionalProperties"] == false

      assert edit_parameters["properties"]["patches"]["items"]["required"] ==
               ["old_string", "new_string"]
    end

    test "remembers the downgraded shape for the next round" do
      FakeTransport.set_stream_script([
        {:status, 400, ~s({"error":{"message":"unknown field stream_options"}})},
        {:chunks, @success_stream}
      ])

      assert {:ok, %Response{}} =
               wire_result(OpenAICompatible.stream(runtime(), request(), fn _frame -> :ok end))

      # The second round must succeed on its first attempt: no repeated 400.
      FakeTransport.set_stream_script([{:chunks, @success_stream}])

      assert {:ok, %Response{}} =
               wire_result(OpenAICompatible.stream(runtime(), request(), fn _frame -> :ok end))

      assert length(FakeTransport.requests()) == 3

      refute FakeTransport.requests()
             |> List.last()
             |> Map.fetch!(:body)
             |> Jason.decode!()
             |> Map.has_key?("stream_options")
    end

    test "fails loudly with tool_calls_unsupported when tools are rejected" do
      FakeTransport.set_stream_script([
        {:status, 400, ~s({"error":{"message":"unknown field stream_options"}})},
        {:status, 400, ~s({"error":{"message":"function calling is not supported"}})}
      ])

      assert {:error,
              %{
                "category" => "tool_calls_unsupported",
                "retryable" => false,
                "message" => message
              }} =
               wire_result(OpenAICompatible.stream(runtime(), request(), fn _frame -> :ok end))

      assert message =~ "function calling is not supported"
      assert message =~ "REYCODE_DEEPSEEK_SUPPORTS_TOOLS=false"

      assert [%{body: _}, last] = FakeTransport.requests()
      assert Jason.decode!(last.body)["tools"]
    end

    test "an unrelated HTTP 400 is preserved and never retried" do
      FakeTransport.set_stream_script([
        {:status, 400, ~s({"error":{"message":"model does not exist"}})}
      ])

      assert {:error,
              %{
                "category" => "request_failed",
                "retryable" => false,
                "message" => message
              }} =
               wire_result(OpenAICompatible.stream(runtime(), request(), fn _frame -> :ok end))

      assert message =~ "model does not exist"
      assert length(FakeTransport.requests()) == 1
    end

    test "non-400 failures keep their semantics and are never retried" do
      FakeTransport.set_stream_script([{:status, 429, ~s({"error":{"message":"slow down"}})}])

      assert {:error, %{"category" => "rate_limited", "retryable" => true}} =
               wire_result(OpenAICompatible.stream(runtime(), request(), fn _frame -> :ok end))

      assert length(FakeTransport.requests()) == 1
    end

    test "a pinned profile omits capabilities from the first attempt" do
      System.put_env("STRICT_KEY", "k")

      config =
        RuntimeConfig.fresh(
          openai_compatible_transport: FakeTransport,
          openai_compatible_providers: [
            %{
              id: :strict_local,
              name: "Strict",
              base_url: "https://strict.example.test",
              key_env: "STRICT_KEY",
              supports_tools: false
            }
          ]
        )

      runtime = %Runtime{
        module: OpenAICompatible,
        provider_id: :strict_local,
        status: :configured,
        config: config.open_ai
      }

      FakeTransport.set_stream(@success_stream)

      assert {:ok, %Response{text: "ok"}} =
               wire_result(OpenAICompatible.stream(runtime, request(), fn _frame -> :ok end))

      body = Jason.decode!(FakeTransport.last_body())
      refute Map.has_key?(body, "tools")
      assert Map.has_key?(body, "stream_options")
    after
      System.delete_env("STRICT_KEY")
    end

    test "an environment override pins a built-in profile capability" do
      System.put_env("REYCODE_DEEPSEEK_SUPPORTS_STREAM_OPTIONS", "false")

      assert {:ok, %{supports_stream_options: false, supports_tools: true}} =
               Profile.fetch(:deepseek, RuntimeConfig.load!().open_ai)
    after
      System.delete_env("REYCODE_DEEPSEEK_SUPPORTS_STREAM_OPTIONS")
    end

    test "an invalid environment capability value fails configuration loudly" do
      System.put_env("REYCODE_DEEPSEEK_SUPPORTS_TOOLS", "sometimes")

      assert_raise ArgumentError, ~r/SUPPORTS_TOOLS/, fn -> RuntimeConfig.load!() end
    after
      System.delete_env("REYCODE_DEEPSEEK_SUPPORTS_TOOLS")
    end

    test "a 400 from a fully pinned profile surfaces unchanged" do
      System.put_env("PINNED_KEY", "k")

      config =
        RuntimeConfig.fresh(
          openai_compatible_transport: FakeTransport,
          openai_compatible_providers: [
            %{
              id: :pinned,
              name: "Pinned",
              base_url: "https://pinned.example.test",
              key_env: "PINNED_KEY",
              supports_tools: false,
              supports_stream_options: false
            }
          ]
        )

      runtime = %Runtime{
        module: OpenAICompatible,
        provider_id: :pinned,
        status: :configured,
        config: config.open_ai
      }

      FakeTransport.set_stream_script([
        {:status, 400, ~s({"error":{"message":"bad request for other reasons"}})}
      ])

      assert {:error, %{"category" => "request_failed"}} =
               wire_result(OpenAICompatible.stream(runtime, request(), fn _frame -> :ok end))

      assert length(FakeTransport.requests()) == 1
    after
      System.delete_env("PINNED_KEY")
    end

    test "an explicit capability pin wins over a remembered downgrade" do
      # Prime the sticky cache: first round downgrades stream_options.
      FakeTransport.set_stream_script([
        {:status, 400, ~s({"error":{"message":"unknown field stream_options"}})},
        {:chunks, @success_stream}
      ])

      assert {:ok, %Response{}} =
               wire_result(OpenAICompatible.stream(runtime(), request(), fn _frame -> :ok end))

      # The operator then pins tools off; the memory must not re-enable them.
      # load/2 is what production uses, so it applies the env pin.
      System.put_env("REYCODE_DEEPSEEK_SUPPORTS_TOOLS", "false")

      policy =
        RuntimeConfig.load(
          fn
            :openai_compatible_transport, _default -> FakeTransport
            _key, default -> default
          end,
          &System.get_env/1
        ).open_ai

      pinned_runtime = %{runtime() | provider_id: :deepseek, config: policy}

      FakeTransport.set_stream(@success_stream)

      assert {:ok, %Response{}} =
               wire_result(
                 OpenAICompatible.stream(pinned_runtime, request(), fn _frame -> :ok end)
               )

      body =
        FakeTransport.requests()
        |> List.last()
        |> Map.fetch!(:body)
        |> Jason.decode!()

      refute Map.has_key?(body, "tools")
    after
      System.delete_env("REYCODE_DEEPSEEK_SUPPORTS_TOOLS")
    end
  end

  describe "Profile" do
    test "exposes the built-in DeepSeek profile" do
      ids = Profile.ids()
      assert :deepseek in ids
      {:ok, profile} = Profile.fetch(:deepseek)
      assert profile.name == "DeepSeek"
      assert profile.base_url =~ "api.deepseek.com"
    end

    test "an unknown profile id is not found" do
      assert Profile.fetch(:nope) == {:error, :unknown_provider}
    end

    test "a base url environment override takes precedence" do
      System.put_env("REYCODE_DEEPSEEK_BASE_URL", "https://proxy.example.test")

      {:ok, profile} = Profile.fetch(:deepseek, RuntimeConfig.load!().open_ai)
      assert profile.base_url == "https://proxy.example.test"
    after
      System.delete_env("REYCODE_DEEPSEEK_BASE_URL")
    end

    test "an injected config freezes the endpoint after startup" do
      System.put_env("REYCODE_DEEPSEEK_BASE_URL", "https://first.example.test")
      config = RuntimeConfig.load!()
      System.put_env("REYCODE_DEEPSEEK_BASE_URL", "https://second.example.test")

      assert {:ok, %{base_url: "https://first.example.test"}} =
               Profile.fetch(:deepseek, config.open_ai)
    after
      System.delete_env("REYCODE_DEEPSEEK_BASE_URL")
    end

    test "configured profiles override colliding built-in IDs without moving their slot" do
      config =
        RuntimeConfig.fresh(
          openai_compatible_providers: [
            %{
              id: :ollama,
              name: "Remote Ollama",
              base_url: "https://ollama.example.test/v1",
              key_env: "REMOTE_OLLAMA_KEY"
            }
          ]
        )

      assert {:ok, ollama} = Profile.fetch(:ollama, config.open_ai)
      assert ollama.name == "Remote Ollama"
      assert ollama.base_url == "https://ollama.example.test/v1"
      assert ollama.require_key

      assert Enum.take(Profile.ids(config.open_ai), 3) == [:deepseek, :ollama, :lmstudio]
    end
  end

  defp wire_result({:error, %Failure{} = failure}), do: {:error, Failure.to_wire(failure)}
  defp wire_result(result), do: result

  defp runtime(overrides \\ []) do
    config =
      [
        openai_compatible_transport: FakeTransport,
        openai_compatible_chunk_latency_ms: 0
      ]
      |> Keyword.merge(overrides)
      |> RuntimeConfig.fresh()
      |> Map.fetch!(:open_ai)

    %Runtime{
      module: OpenAICompatible,
      provider_id: :deepseek,
      status: :configured,
      config: config
    }
  end

  defp request do
    %Request{
      invocation_id: "inv-1",
      turn_id: "turn-1",
      session_id: "room-1",
      mode: :compare,
      participant: %{
        id: "builder",
        name: "Builder",
        perspective: "pragmatic implementation",
        provider: :deepseek,
        model: "deepseek-chat"
      },
      system_prompt: "You are helpful.",
      messages: [%{role: :user, content: "Hi", author: %{id: "user", name: "You"}}],
      workspace: System.tmp_dir!(),
      resume_from: 0,
      round_index: 0
    }
  end

  defp collect_frames(fun) do
    test_pid = self()

    result =
      fun.(fn frame ->
        send(test_pid, {:frame, frame})
        :ok
      end)

    frames =
      Enum.reduce(
        Stream.unfold(nil, fn _ ->
          receive do
            {:frame, %Frame{} = frame} -> {frame, nil}
          after
            50 -> nil
          end
        end),
        [],
        fn frame, acc -> acc ++ [frame] end
      )

    {result, frames}
  end

  defp local_runtime(provider_id), do: %{runtime() | provider_id: provider_id}

  defp authorization_header?(headers) do
    Enum.any?(headers, fn {name, _value} -> String.downcase(name) == "authorization" end)
  end
end

defmodule ReyCode.OpenAICompatible.FakeTransport do
  @behaviour ReyCode.Provider.OpenAICompatible.HTTP

  alias ReyCode.Provider.OpenAICompatible.HTTP

  def clear do
    [:models, :stream, :models_status, :stream_status, :stream_failure, :last_request, :script]
    |> Enum.each(&:persistent_term.erase({__MODULE__, &1}))

    :persistent_term.erase({__MODULE__, :requests})
  end

  def set_models(body), do: :persistent_term.put({__MODULE__, :models}, body)
  def set_stream(chunks), do: :persistent_term.put({__MODULE__, :stream}, chunks)

  def set_stream_failure(failure),
    do: :persistent_term.put({__MODULE__, :stream_failure}, failure)

  def last_body, do: last_request().body || ""
  def last_request, do: :persistent_term.get({__MODULE__, :last_request}, %{})

  def set_models_status(status, body),
    do: :persistent_term.put({__MODULE__, :models_status}, {status, body})

  def set_stream_status(status, body),
    do: :persistent_term.put({__MODULE__, :stream_status}, {status, body})

  # One step per stream attempt: {:status, code, body} fails the attempt;
  # {:chunks, list} replays a successful SSE body.
  def set_stream_script(script), do: :persistent_term.put({__MODULE__, :script}, script)

  def requests, do: :persistent_term.get({__MODULE__, :requests}, [])

  @impl true
  def start(method, url, headers, body, _opts) do
    request = %{method: method, url: url, headers: headers, body: body}
    :persistent_term.put({__MODULE__, :last_request}, request)
    :persistent_term.put({__MODULE__, :requests}, requests() ++ [request])

    if String.ends_with?(url, "/models"), do: {:ok, :models}, else: {:ok, :stream}
  end

  @impl true
  def collect(:models, on_event, acc) do
    case :persistent_term.get({__MODULE__, :models_status}, nil) do
      {status, body} ->
        {:error, HTTP.status_error(status, body)}

      nil ->
        body = :persistent_term.get({__MODULE__, :models}, "")

        case on_event.({:partial, body}, acc) do
          {:cont, next} -> {:ok, next, %{status: 200, headers: []}}
          {:halt, _next, error} -> {:error, error}
        end
    end
  end

  def collect(:stream, on_event, acc) do
    case :persistent_term.get({__MODULE__, :stream_failure}, nil) do
      :raise -> raise "transport raised"
      :throw -> throw(:transport_threw)
      :exit -> exit(:transport_exited)
      nil -> collect_stream_status(on_event, acc)
    end
  end

  defp collect_stream_status(on_event, acc) do
    case take_script_step() do
      {:status, status, body} ->
        {:error, HTTP.status_error(status, body)}

      {:chunks, chunks} ->
        reduce_stream(on_event, acc, chunks)

      nil ->
        case :persistent_term.get({__MODULE__, :stream_status}, nil) do
          {status, body} ->
            {:error, HTTP.status_error(status, body)}

          nil ->
            reduce_stream(on_event, acc, :persistent_term.get({__MODULE__, :stream}, []))
        end
    end
  end

  defp take_script_step do
    case :persistent_term.get({__MODULE__, :script}, nil) do
      [step | rest] ->
        :persistent_term.put({__MODULE__, :script}, rest)
        step

      _other ->
        nil
    end
  end

  defp reduce_stream(on_event, acc, chunks) do
    result =
      Enum.reduce_while(chunks, {:ok, acc}, fn
        {:pause, test_pid, token}, {:ok, current} ->
          send(test_pid, {:transport_paused, token, self()})

          receive do
            {^token, :resume} -> {:cont, {:ok, current}}
          end

        chunk, {:ok, current} ->
          case on_event.({:partial, chunk}, current) do
            {:cont, next} -> {:cont, {:ok, next}}
            {:halt, _acc, error} -> {:halt, {:error, error}}
          end
      end)

    case result do
      {:ok, final} -> {:ok, final, %{status: 200, headers: []}}
      {:error, error} -> {:error, error}
    end
  end
end
