defmodule ReyCode.Provider.OpenAICompatibleTest do
  use ExUnit.Case, async: false

  alias ReyCode.OpenAICompatible.FakeTransport

  alias ReyCode.Provider.{
    Frame,
    Message,
    OpenAICompatible,
    OpenAICompatible.Profile,
    Request,
    Response,
    Runtime,
    ToolCall
  }

  @key_env "DEEPSEEK_API_KEY"

  setup do
    previous_transport = Application.get_env(:rey_code, :openai_compatible_transport)

    previous_chunk_latency =
      Application.get_env(:rey_code, :openai_compatible_chunk_latency_ms)

    Application.put_env(:rey_code, :openai_compatible_transport, FakeTransport)
    FakeTransport.clear()
    System.put_env(@key_env, "test-key")

    on_exit(fn ->
      if previous_transport do
        Application.put_env(:rey_code, :openai_compatible_transport, previous_transport)
      else
        Application.delete_env(:rey_code, :openai_compatible_transport)
      end

      if previous_chunk_latency do
        Application.put_env(
          :rey_code,
          :openai_compatible_chunk_latency_ms,
          previous_chunk_latency
        )
      else
        Application.delete_env(:rey_code, :openai_compatible_chunk_latency_ms)
      end

      System.delete_env(@key_env)
      FakeTransport.clear()
    end)

    :ok
  end

  describe "discover/2" do
    test "reports available without a network call when the key is absent" do
      System.delete_env(@key_env)
      {:ok, profile} = Profile.fetch(:deepseek)

      assert {:ok, %{status: :available, models: [], credential_count: 0}} =
               OpenAICompatible.discover(profile)
    end

    test "parses the model list from /models when the key is present" do
      FakeTransport.set_models(~s({"data":[{"id":"deepseek-chat"},{"id":"deepseek-reasoner"}]}))
      {:ok, profile} = Profile.fetch(:deepseek)

      assert {:ok,
              %{
                status: :configured,
                models: ["deepseek-chat", "deepseek-reasoner"],
                credential_count: 1
              }} = OpenAICompatible.discover(profile)
    end

    test "folds a discovery failure into an error status" do
      FakeTransport.set_models_status(429, ~s({"error":{"message":"slow down"}}))
      {:ok, profile} = Profile.fetch(:deepseek)

      assert {:ok, %{status: :error, models: [], error: "slow down"}} =
               OpenAICompatible.discover(profile)
    end
  end

  describe "stream/3" do
    test "emits text deltas parsed from the SSE response" do
      Application.put_env(:rey_code, :openai_compatible_chunk_latency_ms, 0)

      FakeTransport.set_stream([
        ~s(data: {"choices":[{"delta":{"content":"Hello "}}]}\n\n),
        ~s(data: {"choices":[{"delta":{"content":"there"}}]}\n\n),
        ~s(data: {"choices":[],"usage":{"prompt_tokens":2,"completion_tokens":2}}\n\n),
        "data: [DONE]\n\n"
      ])

      frames = collect_frames(fn emit -> OpenAICompatible.stream(runtime(), request(), emit) end)

      {result, emitted} = frames

      assert {:ok, %Response{usage: %{"prompt_tokens" => 2, "completion_tokens" => 2}}} = result

      assert [
               %Frame{sequence: 1, kind: :text_delta, data: %{text: "Hello "}},
               %Frame{sequence: 2, kind: :text_delta, data: %{text: "there"}}
             ] = emitted
    end

    test "starts emitted frame sequence from request.resume_from" do
      Application.put_env(:rey_code, :openai_compatible_chunk_latency_ms, 0)

      FakeTransport.set_stream([
        ~s(data: {"choices":[{"delta":{"content":"Hello "}}]}\n\n),
        ~s(data: {"choices":[{"delta":{"content":"there"}}]}\n\n),
        ~s(data: [DONE]\n\n)
      ])

      frames =
        collect_frames(fn emit ->
          OpenAICompatible.stream(runtime(), %{request() | resume_from: 10}, emit)
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
          OpenAICompatible.stream(runtime(), request(), emit)
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
        OpenAICompatible.stream(runtime(), request(), fn _frame -> :ok end)

      assert Enum.map(calls, &{&1.id, &1.tool}) == [{"call-1", "read"}, {"call-2", "list"}]
    end

    test "drives a complete two-round conversation through the one-round contract" do
      Application.put_env(:rey_code, :openai_compatible_chunk_latency_ms, 0)

      # Round 1: the model asks for a tool.
      FakeTransport.set_stream([
        ~s(data: {"choices":[{"delta":{"tool_calls":[{"id":"call-9","index":0,"type":"function","function":{"name":"read","arguments":"{\\"path\\":\\"hello.txt\\"}"}}]}}]}\n\n),
        ~s(data: {"choices":[{"finish_reason":"tool_calls","delta":{}}]}\n\n),
        "data: [DONE]\n\n"
      ])

      {:ok, round_one} = OpenAICompatible.stream(runtime(), request(), fn _frame -> :ok end)

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

      {:ok, round_two} = OpenAICompatible.stream(runtime(), continuation, fn _frame -> :ok end)

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
    end

    test "normalizes malformed tool-call arguments to an empty map" do
      FakeTransport.set_stream([
        # Truncated JSON…
        ~s(data: {"choices":[{"delta":{"tool_calls":[{"id":"call-a","index":0,"function":{"name":"bash","arguments":"{\\"cmd\\""}}]}}]}\n\n),
        # …a non-object payload…
        ~s(data: {"choices":[{"delta":{"tool_calls":[{"id":"call-b","index":1,"function":{"name":"list","arguments":"[1,2]"}}]}}]}\n\n),
        # …and a null payload must all survive normalization.
        ~s(data: {"choices":[{"delta":{"tool_calls":[{"id":"call-c","index":2,"function":{"name":"glob"}}]}}]}\n\n),
        ~s(data: {"choices":[{"finish_reason":"tool_calls","delta":{}}]}\n\n)
      ])

      {:ok, %Response{tool_calls: calls}} =
        OpenAICompatible.stream(runtime(), request(), fn _frame -> :ok end)

      assert [
               %ToolCall{id: "call-a", tool: "bash", arguments: %{}},
               %ToolCall{id: "call-b", tool: "list", arguments: %{}},
               %ToolCall{id: "call-c", tool: "glob", arguments: %{}}
             ] = calls
    end

    test "returns a missing credentials error when the key is unset" do
      System.delete_env(@key_env)

      assert {:error, %{"category" => "missing_credentials", "retryable" => false}} =
               OpenAICompatible.stream(runtime(), request(), fn _frame -> :ok end)
    end

    test "maps a rate-limit status to a retryable error" do
      FakeTransport.set_stream_status(429, ~s({"error":{"message":"slow down"}}))

      assert {:error, %{"category" => "rate_limited", "retryable" => true, "message" => message}} =
               OpenAICompatible.stream(runtime(), request(), fn _frame -> :ok end)

      assert message =~ "slow down"
    end

    test "maps an authentication failure to a non-retryable error" do
      FakeTransport.set_stream_status(401, ~s({"error":{"message":"bad key"}}))

      assert {:error, %{"category" => "authentication_failed", "retryable" => false}} =
               OpenAICompatible.stream(runtime(), request(), fn _frame -> :ok end)
    end

    test "halts and errors when output exceeds the profile limit" do
      Application.put_env(:rey_code, :openai_compatible_providers, [
        %{
          id: :tiny,
          name: "Tiny",
          base_url: "https://example.test",
          key_env: "TINY_API_KEY",
          max_output_bytes: 8
        }
      ])

      System.put_env("TINY_API_KEY", "tiny-key")

      FakeTransport.set_stream([
        ~s(data: {"choices":[{"delta":{"content":"this is far too long to fit"}}]}\n\n),
        "data: [DONE]\n\n"
      ])

      runtime = %Runtime{module: OpenAICompatible, provider_id: :tiny, status: :configured}

      assert {:error, %{"category" => "output_too_large", "retryable" => false}} =
               OpenAICompatible.stream(runtime, request(), fn _frame -> :ok end)
    after
      Application.delete_env(:rey_code, :openai_compatible_providers)
      System.delete_env("TINY_API_KEY")
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

      {:ok, profile} = Profile.fetch(:deepseek)
      assert profile.base_url == "https://proxy.example.test"
    after
      System.delete_env("REYCODE_DEEPSEEK_BASE_URL")
    end
  end

  defp runtime do
    %Runtime{module: OpenAICompatible, provider_id: :deepseek, status: :configured}
  end

  defp request do
    %Request{
      invocation_id: "inv-1",
      turn_id: "turn-1",
      room_id: "room-1",
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
end

defmodule ReyCode.OpenAICompatible.FakeTransport do
  @behaviour ReyCode.Provider.OpenAICompatible.HTTP

  alias ReyCode.Provider.OpenAICompatible.HTTP

  def clear do
    [:models, :stream, :models_status, :stream_status, :last_body]
    |> Enum.each(&:persistent_term.erase({__MODULE__, &1}))
  end

  def set_models(body), do: :persistent_term.put({__MODULE__, :models}, body)
  def set_stream(chunks), do: :persistent_term.put({__MODULE__, :stream}, chunks)

  def last_body, do: :persistent_term.get({__MODULE__, :last_body}, "{}")

  def set_models_status(status, body),
    do: :persistent_term.put({__MODULE__, :models_status}, {status, body})

  def set_stream_status(status, body),
    do: :persistent_term.put({__MODULE__, :stream_status}, {status, body})

  @impl true
  def start(url, _headers, body, _opts) do
    :persistent_term.put({__MODULE__, :last_body}, body)

    if String.ends_with?(url, "/models"), do: {:ok, :models}, else: {:ok, :stream}
  end

  @impl true
  def collect(:models, _on_event, acc) do
    case :persistent_term.get({__MODULE__, :models_status}, nil) do
      {status, body} -> {:error, HTTP.status_error(status, body)}
      nil -> {:ok, acc, %{status: 200, body: :persistent_term.get({__MODULE__, :models}, "")}}
    end
  end

  def collect(:stream, on_event, acc) do
    case :persistent_term.get({__MODULE__, :stream_status}, nil) do
      {status, body} ->
        {:error, HTTP.status_error(status, body)}

      nil ->
        reduce_stream(on_event, acc)
    end
  end

  defp reduce_stream(on_event, acc) do
    chunks = :persistent_term.get({__MODULE__, :stream}, [])

    result =
      Enum.reduce_while(chunks, {:ok, acc}, fn chunk, {:ok, current} ->
        case on_event.({:partial, chunk}, current) do
          {:cont, next} -> {:cont, {:ok, next}}
          {:halt, _acc, error} -> {:halt, {:error, error}}
        end
      end)

    case result do
      {:ok, final} -> {:ok, final, %{status: 200, body: ""}}
      {:error, error} -> {:error, error}
    end
  end
end
