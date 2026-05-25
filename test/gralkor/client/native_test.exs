defmodule Gralkor.Client.NativeTest do
  use ExUnit.Case, async: false

  require Logger

  alias Gralkor.Client.Native
  alias Gralkor.Message

  describe "ex-client-native > if capture is called with a blank string session_id" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/session_id/, fn ->
        Native.capture("", "g", "TestAgent", "Eli", nil, [Message.new("user", "x")])
      end
    end
  end

  describe "ex-client-native > if capture is called with a nil session_id" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/session_id/, fn ->
        Native.capture(nil, "g", "TestAgent", "Eli", nil, [Message.new("user", "x")])
      end
    end
  end

  describe "ex-client-native > if capture is called with a blank agent_name" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/agent_name/, fn ->
        Native.capture("s1", "g", "", "Eli", nil, [Message.new("user", "x")])
      end
    end
  end

  describe "ex-client-native > if capture is called with a nil agent_name" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/agent_name/, fn ->
        Native.capture("s1", "g", nil, "Eli", nil, [Message.new("user", "x")])
      end
    end
  end

  describe "ex-client-native > if capture is called with a blank user_name" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/user_name/, fn ->
        Native.capture("s1", "g", "TestAgent", "", nil, [Message.new("user", "x")])
      end
    end
  end

  describe "ex-client-native > if capture is called with a nil user_name" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/user_name/, fn ->
        Native.capture("s1", "g", "TestAgent", nil, nil, [Message.new("user", "x")])
      end
    end
  end

  describe "ex-client-native > interpret output budget > if :interpret_max_output_tokens is set to a non-positive or non-integer value" do
    setup do
      original = Application.get_env(:jido_gralkor, :interpret_max_output_tokens)

      on_exit(fn ->
        if original == nil do
          Application.delete_env(:jido_gralkor, :interpret_max_output_tokens)
        else
          Application.put_env(:jido_gralkor, :interpret_max_output_tokens, original)
        end
      end)

      :ok
    end

    test "raises ArgumentError on zero" do
      Application.put_env(:jido_gralkor, :interpret_max_output_tokens, 0)

      assert_raise ArgumentError, ~r/interpret_max_output_tokens/, fn ->
        Native.recall("g", "TestAgent", "s1", "q")
      end
    end

    test "raises ArgumentError on negative" do
      Application.put_env(:jido_gralkor, :interpret_max_output_tokens, -1)

      assert_raise ArgumentError, ~r/interpret_max_output_tokens/, fn ->
        Native.recall("g", "TestAgent", "s1", "q")
      end
    end

    test "raises ArgumentError on non-integer" do
      Application.put_env(:jido_gralkor, :interpret_max_output_tokens, "lots")

      assert_raise ArgumentError, ~r/interpret_max_output_tokens/, fn ->
        Native.recall("g", "TestAgent", "s1", "q")
      end
    end
  end

  describe "ex-client-native > if recall is called with a blank agent_name" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/agent_name/, fn ->
        Native.recall("g", "", "s1", "q")
      end
    end
  end

  describe "ex-client-native > if recall is called with a nil agent_name" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/agent_name/, fn ->
        Native.recall("g", nil, "s1", "q")
      end
    end
  end

  describe "ex-client-native > if flush is called with a blank string session_id" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/session_id/, fn ->
        Native.flush("")
      end
    end
  end

  describe "ex-client-native > if flush is called with a nil session_id" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/session_id/, fn ->
        Native.flush(nil)
      end
    end
  end

  describe "ex-client-native > if flush_and_await is called with a blank string session_id" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/session_id/, fn ->
        Native.flush_and_await("", 1_000)
      end
    end
  end

  describe "ex-client-native > if flush_and_await is called with a nil session_id" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/session_id/, fn ->
        Native.flush_and_await(nil, 1_000)
      end
    end
  end

  describe "ex-client-native > if flush_and_await is called with a non-positive timeout_ms" do
    test "raises ArgumentError when timeout_ms is zero" do
      assert_raise ArgumentError, ~r/timeout_ms/, fn ->
        Native.flush_and_await("s1", 0)
      end
    end

    test "raises ArgumentError when timeout_ms is negative" do
      assert_raise ArgumentError, ~r/timeout_ms/, fn ->
        Native.flush_and_await("s1", -1)
      end
    end

    test "raises ArgumentError when timeout_ms is missing" do
      assert_raise ArgumentError, ~r/timeout_ms/, fn ->
        Native.flush_and_await("s1", nil)
      end
    end
  end
end
