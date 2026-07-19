defmodule Gralkor.Client.NativeTest do
  use ExUnit.Case, async: false

  require Logger

  alias Gralkor.CaptureBuffer
  alias Gralkor.Client
  alias Gralkor.Client.Native
  alias Gralkor.Message

  defp start_capture_buffer(_ctx) do
    test_pid = self()

    callback = fn group, agent, user, ontology, turns ->
      send(test_pid, {:flushed, group, agent, user, ontology, turns})
      :ok
    end

    start_supervised!(
      {CaptureBuffer,
       flush_callback: callback,
       lens_flush_callback: callback,
       retries: []}
    )
    :ok
  end

  describe "ex-client-native > if capture is called with a blank string session_id" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/session_id/, fn ->
        Native.capture("", "g", "TestAgent", "Eli", [Message.new("user", "x")])
      end
    end
  end

  describe "ex-client-native > if capture is called with a nil session_id" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/session_id/, fn ->
        Native.capture(nil, "g", "TestAgent", "Eli", [Message.new("user", "x")])
      end
    end
  end

  describe "ex-client-native > if capture is called with a blank agent_name" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/agent_name/, fn ->
        Native.capture("s1", "g", "", "Eli", [Message.new("user", "x")])
      end
    end
  end

  describe "ex-client-native > if capture is called with a nil agent_name" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/agent_name/, fn ->
        Native.capture("s1", "g", nil, "Eli", [Message.new("user", "x")])
      end
    end
  end

  describe "ex-client-native > if capture is called with a blank user_name" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/user_name/, fn ->
        Native.capture("s1", "g", "TestAgent", "", [Message.new("user", "x")])
      end
    end
  end

  describe "ex-client-native > if capture is called with a nil user_name" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/user_name/, fn ->
        Native.capture("s1", "g", "TestAgent", nil, [Message.new("user", "x")])
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

  describe "ex-memory-add > ontology validation" do
    test "raises ArgumentError when ontology is a module that does not export __ontology__/0" do
      assert_raise ArgumentError, ~r/NotAnOntology/, fn ->
        Native.memory_add("g", "content", "manual", Gralkor.TestOntologies.NotAnOntology)
      end
    end

    test "raises ArgumentError when ontology is a non-module value" do
      assert_raise ArgumentError, ~r/not-a-module/, fn ->
        Native.memory_add("g", "content", "manual", "not-a-module")
      end
    end
  end

  describe "ex-memory-add > arity" do
    test "memory_add/3 is exported" do
      assert function_exported?(Native, :memory_add, 3)
    end

    test "memory_add/4 is exported" do
      assert function_exported?(Native, :memory_add, 4)
    end
  end

  describe "ex-memory-add > memory_add/3 delegates to memory_add/4 with Config.ontology/0" do
    setup do
      original = Application.get_env(:jido_gralkor, :ontology)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:jido_gralkor, :ontology)
          v -> Application.put_env(:jido_gralkor, :ontology, v)
        end
      end)
    end

    test "when :ontology is unset, memory_add/3 passes the ontology guard and reaches GraphitiPool" do
      Application.delete_env(:jido_gralkor, :ontology)

      # memory_add/3 delegates to /4 with Config.ontology() → nil.
      # raise_unless_ontology_or_nil! accepts nil, so we reach GraphitiPool.
      # The crash is about ETS (no OTP stack), NOT about ontology — that
      # proves the guard passed.
      assert_raise ArgumentError, ~r/ETS/, fn ->
        Native.memory_add("g", "content", "manual")
      end
    end
  end

  describe "ex-sanitize-group-id > when the id contains hyphens" do
    test "hyphens are replaced with underscores" do
      assert Client.sanitize_group_id("a-b-c") == "a_b_c"
    end
  end

  describe "ex-sanitize-group-id > when the id has consecutive hyphens" do
    test "each hyphen is replaced independently" do
      assert Client.sanitize_group_id("a--b") == "a__b"
    end
  end

  describe "ex-sanitize-group-id > when the id has no hyphens" do
    test "it is returned unchanged" do
      assert Client.sanitize_group_id("abc") == "abc"
    end
  end

  describe "ex-impl-resolver > when :jido_gralkor/:client is unset in app env" do
    test "Gralkor.Client.Native is returned" do
      original = Application.get_env(:jido_gralkor, :client)
      Application.delete_env(:jido_gralkor, :client)

      try do
        assert Client.impl() == Native
      after
        case original do
          nil -> Application.delete_env(:jido_gralkor, :client)
          v -> Application.put_env(:jido_gralkor, :client, v)
        end
      end
    end
  end

  describe "ex-capture > request shape > capture/5" do
    setup :start_capture_buffer

    test "invokes CaptureBuffer.append/6 with sanitized group_id, names, ontology, and messages" do
      msgs = [Message.new("user", "hi")]

      assert :ok = Native.capture("s1", "with-hyphens", "Susu", "Eli", msgs)
      assert [^msgs] = CaptureBuffer.turns_for("s1")

      :ok = CaptureBuffer.flush("s1")
      assert_receive {:flushed, "with_hyphens", "Susu", "Eli", nil, [^msgs]}
    end
  end

  describe "ex-capture > request shape > capture/6 with a Lens" do
    setup :start_capture_buffer

    test "invokes CaptureBuffer.append_lens/6 with the operator id, names, Lens, and messages" do
      msgs = [Message.new("user", "hi")]

      assert :ok =
               Native.capture(
                 "s1",
                 "operator-with-hyphens",
                 "Susu",
                 "Eli",
                 msgs,
                 "observations"
               )

      assert [^msgs] = CaptureBuffer.turns_for("s1")
    end
  end

  describe "ex-capture > then returns :ok immediately (does not call distill synchronously)" do
    setup :start_capture_buffer

    test "returns :ok" do
      assert :ok = Native.capture("s1", "g", "Susu", "Eli", [Message.new("user", "x")])
    end
  end

  describe "ex-flush > when called with a session_id with buffered turns" do
    setup :start_capture_buffer

    test "the buffered turns are scheduled for flush and :ok is returned" do
      :ok = Native.capture("s1", "g", "Susu", "Eli", [Message.new("user", "x")])

      assert :ok = Native.flush("s1")
      assert_receive {:flushed, "g", "Susu", "Eli", nil, _turns}
    end
  end

  describe "ex-flush > when called with a session_id with no buffered turns" do
    setup :start_capture_buffer

    test ":ok is returned and no work is scheduled" do
      assert :ok = Native.flush("nope")
      refute_receive {:flushed, _, _, _, _, _}, 100
    end
  end

  describe "ex-flush-and-await > when called with a session_id with buffered turns and a positive timeout_ms" do
    setup :start_capture_buffer

    test ":ok is returned when the flush completes within the timeout" do
      :ok = Native.capture("s1", "g", "Susu", "Eli", [Message.new("user", "x")])

      assert :ok = Native.flush_and_await("s1", 1_000)
      assert_receive {:flushed, "g", "Susu", "Eli", nil, _turns}
    end
  end

  describe "ex-flush-and-await > when called with a session_id with no buffered turns" do
    setup :start_capture_buffer

    test ":ok is returned" do
      assert :ok = Native.flush_and_await("nope", 1_000)
    end
  end
end
