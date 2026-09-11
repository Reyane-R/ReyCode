defmodule ReyCode.TUI.StateTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.{Participant, Session}
  alias ReyCode.TUI.State

  @workspace "/workspace"

  test "a retired runtime names itself instead of a generic unavailability" do
    for {provider, label} <- [
          {:opencode, "OpenCode (retired) — /connect"},
          {:open_code, "OpenCode (retired) — /connect"},
          {:omp, "OMP (retired) — /connect"}
        ] do
      session = session(provider: provider, model: "gpt-5.6-luna")

      assert State.composer_status(session, %{}) == %{
               label: label,
               class: "text-warning"
             }
    end
  end

  test "unknown live-shaped providers keep the generic unavailability label" do
    session = session(provider: :mystery, model: "mystery-model")

    assert State.composer_status(session, %{}) == %{
             label: "Provider unavailable — /connect",
             class: "text-warning"
           }
  end

  test "checking, ready, unconfigured, and missing-primary states label themselves" do
    checking = session(provider: :deepseek, model: "deepseek-chat")

    assert State.composer_status(checking, %{deepseek: %{id: :deepseek, status: :checking}}) == %{
             label: "Checking providers…",
             class: "text-muted"
           }

    ready = session(provider: :deepseek, model: "deepseek-chat")

    assert State.composer_status(ready, %{
             deepseek: %{id: :deepseek, status: :configured, models: ["deepseek-chat"]}
           }) == %{label: "Ready", class: "text-muted"}

    unconfigured = session(provider: :unconfigured, model: nil)
    assert State.composer_status(unconfigured, %{}).label == "Connect a model — /connect"

    assert State.composer_status(nil, %{}).label == "Connect a model — /connect"
  end

  defp session(provider: provider, model: model) do
    participant = %Participant{
      id: "primary",
      name: "Assistant",
      kind: :primary,
      provider: provider,
      model: model
    }

    %Session{id: "session", workspace: @workspace, participants: [participant]}
  end
end
