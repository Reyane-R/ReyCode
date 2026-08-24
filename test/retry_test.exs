defmodule ReyCode.RetryTest do
  use ExUnit.Case, async: true

  alias ReyCode.{Failure, Retry}

  test "accepts only an explicitly retryable typed Failure" do
    assert Retry.retryable?(Failure.new(:timeout, "timed out", true))

    refute Retry.retryable?(Failure.new(:timeout, "timed out"))
    refute Retry.retryable?(%{"retryable" => true})
    refute Retry.retryable?(nil)
    refute Retry.retryable?(true)
  end
end
