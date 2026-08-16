defmodule ReyCode.CredoChecks.StringToAtomTest do
  use Credo.Test.Case

  alias ReyCode.CredoChecks.StringToAtom

  test "should NOT report clean code using to_existing_atom" do
    """
    defmodule MyMod do
      def parse(s), do: String.to_existing_atom(s)
    end
    """
    |> to_source_file()
    |> run_check(StringToAtom)
    |> refute_issues()
  end

  test "should report String.to_atom usage" do
    """
    defmodule MyMod do
      def parse(s), do: String.to_atom(s)
    end
    """
    |> to_source_file()
    |> run_check(StringToAtom)
    |> assert_issue(fn issue -> assert issue.trigger == "String.to_atom" end)
  end
end
