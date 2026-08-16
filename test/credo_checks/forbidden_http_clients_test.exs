defmodule ReyCode.CredoChecks.ForbiddenHttpClientsTest do
  use Credo.Test.Case

  alias ReyCode.CredoChecks.ForbiddenHttpClients

  test "should NOT report clean code using :httpc" do
    """
    defmodule MyHttp do
      def get(url), do: :httpc.request(:get, {url, []}, [], [])
    end
    """
    |> to_source_file()
    |> run_check(ForbiddenHttpClients)
    |> refute_issues()
  end

  test "should report HTTPoison usage" do
    """
    defmodule MyHttp do
      def get(url), do: HTTPoison.get(url)
    end
    """
    |> to_source_file()
    |> run_check(ForbiddenHttpClients)
    |> assert_issue(fn issue -> assert issue.trigger == "HTTPoison" end)
  end

  test "should report Tesla usage" do
    """
    defmodule MyHttp do
      def get(url), do: Tesla.get(url)
    end
    """
    |> to_source_file()
    |> run_check(ForbiddenHttpClients)
    |> assert_issue(fn issue -> assert issue.trigger == "Tesla" end)
  end

  test "should report Finch usage" do
    """
    defmodule MyHttp do
      def get(url), do: Finch.request(%{method: :get, url: url}, MyFinch)
    end
    """
    |> to_source_file()
    |> run_check(ForbiddenHttpClients)
    |> assert_issue(fn issue -> assert issue.trigger == "Finch" end)
  end
end
