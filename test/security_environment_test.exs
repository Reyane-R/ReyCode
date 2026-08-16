defmodule ReyCode.Security.EnvironmentTest do
  use ExUnit.Case, async: true

  alias ReyCode.Security.Environment

  test "builds an allowlist from injected names without retaining denied values" do
    source = %{
      "HOME" => "/safe/home",
      "LC_ALL" => "C",
      "PATH" => "/safe/bin",
      "PROVIDER_TOKEN" => "configured",
      "SECRET_TOKEN" => "denied",
      "NO_COLOR" => "0"
    }

    assert Environment.allowlisted(source: source, additional_names: ["PROVIDER_TOKEN"]) == %{
             "HOME" => "/safe/home",
             "LC_ALL" => "C",
             "PATH" => "/safe/bin",
             "PROVIDER_TOKEN" => "configured",
             "NO_COLOR" => "1"
           }

    launch_env = Environment.launch_env(source: source, additional_names: ["PROVIDER_TOKEN"])
    assert launch_env["SECRET_TOKEN"] == ""
    refute inspect(launch_env) =~ "denied"

    {_wrapper, wrapped_args, _env} =
      Environment.wrap("/safe/opencode", ["models"],
        source: source,
        additional_names: ["PROVIDER_TOKEN"]
      )

    refute inspect(wrapped_args) =~ "configured"
    refute inspect(wrapped_args) =~ "denied"
  end
end
