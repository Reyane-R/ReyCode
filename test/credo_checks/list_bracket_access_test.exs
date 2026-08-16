defmodule ReyCode.CredoChecks.ListBracketAccessTest do
  use Credo.Test.Case

  alias ReyCode.CredoChecks.ListBracketAccess

  test "should NOT report Enum.at or pattern matching" do
    """
    defmodule MyMod do
      def first(list), do: Enum.at(list, 0)
      def second(list) do
        [_, x | _] = list
        x
      end
    end
    """
    |> to_source_file()
    |> run_check(ListBracketAccess)
    |> refute_issues()
  end

  test "should NOT report map bracket access with atom keys" do
    """
    defmodule MyMod do
      def get(map), do: map[:field]
    end
    """
    |> to_source_file()
    |> run_check(ListBracketAccess)
    |> refute_issues()
  end

  test "should report list bracket access with integer index" do
    """
    defmodule MyMod do
      def first(list), do: list[0]
    end
    """
    |> to_source_file()
    |> run_check(ListBracketAccess)
    |> assert_issue()
  end

  test "should NOT report list bracket access with variable index (ambiguous)" do
    """
    defmodule MyMod do
      def at(list, i), do: list[i]
    end
    """
    |> to_source_file()
    |> run_check(ListBracketAccess)
    |> refute_issues()
  end
end
