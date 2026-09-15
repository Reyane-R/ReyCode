defmodule ReyCode.TUI.ClipboardTest do
  use ExUnit.Case, async: true

  alias ReyCode.TUI.{AnswerCopy, Clipboard}

  @tag :tmp_dir
  test "clipboard utility receives exact Unicode text through stdin", %{tmp_dir: dir} do
    destination = Path.join(dir, "copied")
    executable = Path.join(dir, "clipboard")
    File.write!(executable, "#!/bin/sh\n/bin/cat > \"#{destination}\"\n")
    File.chmod!(executable, 0o700)
    text = "Hello 世界\n$(not-a-command)\n**Markdown**"
    assert :ok = Clipboard.copy(text, executable: executable)
    assert File.read!(destination) == text
  end

  test "missing clipboard utilities and oversized answers return explicit errors" do
    assert {:error, :clipboard_unavailable} = Clipboard.copy("answer", executable: nil)
    assert {:error, :clipboard_too_large} = Clipboard.copy(String.duplicate("a", 10_000_001))
    assert {:error, :clipboard_failed} = Clipboard.copy("answer", executable: "/usr/bin/false")
  end

  @tag :tmp_dir
  test "a stalled clipboard utility times out without crashing its caller", %{tmp_dir: dir} do
    executable = Path.join(dir, "stalled-clipboard")
    File.write!(executable, "#!/bin/sh\nexec /bin/sleep 10\n")
    File.chmod!(executable, 0o700)
    assert {:error, :clipboard_timeout} = Clipboard.copy("answer", executable: executable)
  end

  test "stale or foreign answers are not copied and clipboard failures do not report success" do
    message = %{
      role: :assistant,
      status: :completed,
      body: "Answer",
      turn_id: nil,
      invocation_id: nil
    }

    term = %Breeze.Term{
      assigns: %{
        selected_session_id: "s",
        projection: %{
          sessions: %{"s" => %{message_order: ["own"]}},
          messages: %{"own" => message, "foreign" => message},
          turns: %{},
          invocations: %{}
        },
        answer_copy: fn _text -> {:error, :clipboard_unavailable} end
      }
    }

    {:noreply, stale} = AnswerCopy.run(term, "missing")
    assert stale.assigns.notice.severity == :warning
    {:noreply, foreign} = AnswerCopy.run(term, "foreign")
    assert foreign.assigns.notice.severity == :warning
    {:noreply, failed} = AnswerCopy.run(term, "own")
    assert failed.assigns.notice.severity == :error
    assert failed.assigns.notice.message =~ "clipboard_unavailable"
  end
end
