defmodule ReyCode.RetryTest do
  use ExUnit.Case, async: true

  alias ReyCode.Retry

  test "accepts only a literal true retryable flag" do
    assert Retry.retryable?(%{"retryable" => true})

    refute Retry.retryable?(%{"retryable" => false})
    refute Retry.retryable?(%{})
    refute Retry.retryable?(%{"retryable" => nil})
    refute Retry.retryable?(%{"retryable" => "true"})
    refute Retry.retryable?(%{retryable: true})
    refute Retry.retryable?(nil)
    refute Retry.retryable?(true)
  end
end
