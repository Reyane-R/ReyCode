defmodule ReyCode.CredoChecks.RequireHttpTimeoutTest do
  use Credo.Test.Case

  alias ReyCode.CredoChecks.RequireHttpTimeout

  test "does not report :httpc.request that sets timeout" do
    """
    defmodule MyHttp do
      def get(url) do
        :httpc.request(:get, {url, []}, [timeout: 10_000], [])
      end
    end
    """
    |> to_source_file()
    |> run_check(RequireHttpTimeout)
    |> refute_issues()
  end

  test "does not report when http_opts is a variable (timeout may come from config)" do
    """
    defmodule MyHttp do
      def get(url, opts) do
        :httpc.request(:get, {url, []}, opts, [])
      end
    end
    """
    |> to_source_file()
    |> run_check(RequireHttpTimeout)
    |> refute_issues()
  end

  test "reports :httpc.request with inline options but no timeout" do
    """
    defmodule MyHttp do
      def get(url) do
        :httpc.request(:get, {url, []}, [ssl: [verify: :verify_peer]], [])
      end
    end
    """
    |> to_source_file()
    |> run_check(RequireHttpTimeout)
    |> assert_issue()
  end
end
