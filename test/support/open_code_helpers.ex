defmodule ReyCode.Test.OpenCodeHelpers do
  @moduledoc false

  alias ReyCode.Provider.{OpenCode, Request, Runtime}

  def request do
    %Request{
      invocation_id: "inv-1",
      turn_id: "turn-1",
      room_id: "room-1",
      mode: :compare,
      participant: %{
        id: "builder",
        name: "Builder",
        perspective: "implementation",
        provider: :opencode,
        model: "openai/gpt-5.6-sol"
      },
      system_prompt: "Respond concisely",
      messages: [%{role: :user, content: "Hello", author: %{name: "You"}}],
      workspace: System.tmp_dir!(),
      resume_from: 0,
      round_index: 0
    }
  end

  def runtime(path) do
    %Runtime{
      module: OpenCode,
      executable: path,
      version: "test",
      models: ["openai/gpt-5.6-sol"],
      status: :configured
    }
  end

  def text_record(text) do
    Jason.encode!(%{type: "text", sessionID: "session-1", part: %{text: text}}) <> "\n"
  end

  def json_line(text) do
    payload = Jason.encode!(%{type: "text", sessionID: "session-1", part: %{text: text}})
    "printf '%s\\n' '#{payload}'"
  end

  def fake_opencode(body) do
    path =
      Path.join(
        System.tmp_dir!(),
        "fake_opencode_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    File.write!(path, """
    #!/bin/sh
    #{body}
    """)

    File.chmod!(path, 0o700)
    path
  end

  def restore_env(key, nil), do: Application.delete_env(:rey_code, key)
  def restore_env(key, value), do: Application.put_env(:rey_code, key, value)

  def collect_frames(frames \\ []) do
    receive do
      {:frame, frame} -> collect_frames([frame | frames])
    after
      0 -> Enum.reverse(frames)
    end
  end

  def eventually(fun, attempts \\ 20)
  def eventually(fun, 0), do: fun.()

  def eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(50)
      eventually(fun, attempts - 1)
    end
  end

  def process_alive?(pid) do
    case System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end
end
