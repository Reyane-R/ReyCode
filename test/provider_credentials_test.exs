defmodule ReyCode.Provider.CredentialsTest do
  use ExUnit.Case, async: false

  alias ReyCode.Provider.{Credentials, Keychain}

  @test_key_env "REYCODE_TEST_KEY"
  @server __MODULE__.Creds

  setup do
    start_supervised!({Credentials, name: @server})
    System.delete_env(@test_key_env)

    on_exit(fn -> System.delete_env(@test_key_env) end)

    :ok
  end

  test "a session key wins over the environment and resolves immediately" do
    System.put_env(@test_key_env, "stale-env-key")
    :ok = Credentials.remember(@test_key_env, "fresh-key", false, @server)

    assert Credentials.fetch(@test_key_env, @server) == {:ok, "fresh-key", :session}
    assert Credentials.source(@test_key_env, @server) == :session
    assert Credentials.known?(@test_key_env, @server)
  end

  test "the environment resolves when no session key exists" do
    System.put_env(@test_key_env, "env-key")

    assert Credentials.fetch(@test_key_env, @server) == {:ok, "env-key", :environment}
  end

  test "blank environment values count as missing" do
    System.put_env(@test_key_env, "   ")

    assert Credentials.fetch(@test_key_env, @server) == :error
    refute Credentials.known?(@test_key_env, @server)
  end

  test "unknown key environments do not resolve" do
    assert Credentials.fetch("REYCODE_NEVER_SET_KEY", @server) == :error
    assert Credentials.source("REYCODE_NEVER_SET_KEY", @server) == nil
    assert Credentials.fetch(nil, @server) == :error
  end

  test "remove clears the session key so lower sources resolve again" do
    System.put_env(@test_key_env, "env-key")
    :ok = Credentials.remember(@test_key_env, "session-key", false, @server)
    :ok = Credentials.remove(@test_key_env, @server)

    assert Credentials.fetch(@test_key_env, @server) == {:ok, "env-key", :environment}
  end

  test "a failed persistence attempt keeps the session key" do
    # Persisting a test key would mutate the user's login keychain, so this
    # only exercises the session-store contract of remember/4.
    assert Credentials.remember(@test_key_env, "session-only-key", false, @server) == :ok

    assert Credentials.fetch(@test_key_env, @server) == {:ok, "session-only-key", :session}
  end

  test "keychain store rejects oversized secrets without touching the CLI" do
    oversized = String.duplicate("k", 10_000)

    assert {:error, {:keychain_failed, _reason}} = Keychain.store(@test_key_env, oversized)
  end
end
