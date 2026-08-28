defmodule ReyCode.TUI.MermaidASCIITest do
  use ExUnit.Case, async: true

  alias ReyCode.TUI.MermaidASCII

  test "renders flowchart edges with resolved labels" do
    markdown = """
    Before

    ```mermaid
    flowchart TD
      A[Inspect] --> B[Implement]
      B -->|passes| C[Test]
    ```

    After
    """

    rendered = MermaidASCII.expand(markdown)
    assert rendered =~ "Before"
    assert rendered =~ "┌─ Diagram · flowchart"
    assert rendered =~ "Inspect ──▶ Implement"
    assert rendered =~ "Implement ── passes ─▶ Test"
    assert rendered =~ "└─"
    refute rendered =~ "```mermaid"
  end

  test "renders sequence messages and bounds unsupported diagrams" do
    rendered =
      MermaidASCII.expand("""
      ```mermaid
      sequenceDiagram
        Operator->>Engine: Start turn
        Engine-->>Operator: Completed
      ```
      """)

    assert rendered =~ "Operator ── Start turn ──▶ Engine"
    assert rendered =~ "Engine ── Completed ──▶ Operator"

    fallback =
      MermaidASCII.expand("```mermaid\nunknownDiagram\n#{String.duplicate("x", 2_000)}\n```")

    assert byte_size(fallback) < 3_000
    assert String.valid?(fallback)
  end
end
