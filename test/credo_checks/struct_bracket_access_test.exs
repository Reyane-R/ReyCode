defmodule ReyCode.CredoChecks.StructBracketAccessTest do
  use Credo.Test.Case

  alias ReyCode.CredoChecks.StructBracketAccess

  test "should NOT report direct field access on structs" do
    """
    defmodule MyMod do
      def get_name(event), do: event.field
    end
    """
    |> to_source_file()
    |> run_check(StructBracketAccess)
    |> refute_issues()
  end

  test "should NOT report bracket access on generic maps" do
    """
    defmodule MyMod do
      def get(map), do: map[:key]
    end
    """
    |> to_source_file()
    |> run_check(StructBracketAccess)
    |> refute_issues()
  end

  test "should NOT report bracket access on projected maps like invocation" do
    """
    defmodule MyMod do
      def get(invocation), do: invocation[:phase]
    end
    """
    |> to_source_file()
    |> run_check(StructBracketAccess)
    |> refute_issues()
  end

  test "should report bracket access on event variable" do
    """
    defmodule MyMod do
      def get(event), do: event[:field]
    end
    """
    |> to_source_file()
    |> run_check(StructBracketAccess)
    |> assert_issue(fn issue -> assert issue.trigger == "event[" end)
  end

  test "should report bracket access on frame variable" do
    """
    defmodule MyMod do
      def get(frame), do: frame[:field]
    end
    """
    |> to_source_file()
    |> run_check(StructBracketAccess)
    |> assert_issue(fn issue -> assert issue.trigger == "frame[" end)
  end
end
