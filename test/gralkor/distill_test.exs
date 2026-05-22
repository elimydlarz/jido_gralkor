defmodule Gralkor.DistillTest do
  use ExUnit.Case, async: true

  alias Gralkor.Distill
  alias Gralkor.Message

  describe "ex-format-transcript > per turn > when a turn contains a behaviour message" do
    test "all messages are rendered with role labels and passed to the LLM as the thinking prompt" do
      ref = make_ref()
      test_pid = self()

      distill_fn = fn prompt ->
        send(test_pid, {ref, prompt})
        {:ok, "did stuff"}
      end

      turns = [
        [
          Message.new("user", "hi"),
          Message.new("behaviour", "thinking out loud"),
          Message.new("assistant", "hello")
        ]
      ]

      _ = Distill.format_transcript(turns, distill_fn, "TestAgent", "Eli")

      assert_receive {^ref, prompt}
      assert prompt =~ "Eli: hi"
      assert prompt =~ "TestAgent: (behaviour: thinking out loud)"
      assert prompt =~ "TestAgent: hello"
    end
  end

  describe "ex-format-transcript > per turn > when a turn has no behaviour messages" do
    test "distillation is skipped for that turn (no LLM call)" do
      counter = :counters.new(1, [])

      distill_fn = fn _ ->
        :counters.add(counter, 1, 1)
        {:ok, "x"}
      end

      _ =
        Distill.format_transcript(
          [[Message.new("user", "hi"), Message.new("assistant", "hello")]],
          distill_fn,
          "TestAgent",
          "Eli"
        )

      assert :counters.get(counter, 1) == 0
    end
  end

  describe "ex-format-transcript > transcript rendering > when a turn has behaviour and the LLM call succeeds" do
    test "rendered as \"{agent_name}: (behaviour: {summary})\" before the assistant text for that turn" do
      distill_fn = fn _ -> {:ok, "thought through the problem"} end

      result =
        Distill.format_transcript(
          [
            [
              Message.new("user", "Q?"),
              Message.new("behaviour", "x"),
              Message.new("assistant", "A")
            ]
          ],
          distill_fn,
          "Susu",
          "Eli"
        )

      assert result ==
               "Eli: Q?\nSusu: (behaviour: thought through the problem)\nSusu: A"
    end
  end

  describe "ex-format-transcript > transcript rendering > when distillation fails for a turn (safe_distill/1)" do
    test "the behaviour line is silently dropped, user/assistant text preserved" do
      distill_fn = fn _ -> {:error, :upstream} end

      result =
        Distill.format_transcript(
          [
            [
              Message.new("user", "Q"),
              Message.new("behaviour", "x"),
              Message.new("assistant", "A")
            ]
          ],
          distill_fn,
          "Susu",
          "Eli"
        )

      assert result == "Eli: Q\nSusu: A"
    end

    test "exceptions raised by the distill_fn are also caught (safe_distill semantics)" do
      distill_fn = fn _ -> raise "boom" end

      result =
        Distill.format_transcript(
          [
            [
              Message.new("user", "Q"),
              Message.new("behaviour", "x"),
              Message.new("assistant", "A")
            ]
          ],
          distill_fn,
          "Susu",
          "Eli"
        )

      assert result == "Eli: Q\nSusu: A"
    end
  end

  describe "ex-format-transcript > transcript rendering > when no LLM is configured" do
    test "behaviour lines are silently omitted, user/assistant text preserved" do
      result =
        Distill.format_transcript(
          [
            [
              Message.new("user", "Q"),
              Message.new("behaviour", "x"),
              Message.new("assistant", "A")
            ]
          ],
          nil,
          "Susu",
          "Eli"
        )

      assert result == "Eli: Q\nSusu: A"
    end
  end

  describe "ex-format-transcript > transcript rendering > when a turn has no behaviour" do
    test "rendered as \"User: …\\n{agent_name}: …\" with no behaviour line, no LLM call" do
      counter = :counters.new(1, [])

      distill_fn = fn _ ->
        :counters.add(counter, 1, 1)
        {:ok, "x"}
      end

      result =
        Distill.format_transcript(
          [[Message.new("user", "Q"), Message.new("assistant", "A")]],
          distill_fn,
          "Susu",
          "Eli"
        )

      assert result == "Eli: Q\nSusu: A"
      assert :counters.get(counter, 1) == 0
    end
  end

  describe "ex-format-transcript > parallel distillation across turns with behaviour via Task.async_stream" do
    test "total time is closer to single-turn time than serial sum" do
      distill_fn = fn _ ->
        Process.sleep(100)
        {:ok, "ok"}
      end

      turns =
        for _ <- 1..4 do
          [
            Message.new("user", "Q"),
            Message.new("behaviour", "b"),
            Message.new("assistant", "A")
          ]
        end

      {us, _result} =
        :timer.tc(fn -> Distill.format_transcript(turns, distill_fn, "TestAgent", "Eli") end)

      ms = div(us, 1000)
      assert ms < 250, "expected parallel (~100ms + overhead), got #{ms}ms"
    end
  end

  describe "ex-format-transcript > if agent_name is missing or blank" do
    test "raises ArgumentError on blank agent_name" do
      assert_raise ArgumentError, ~r/agent_name/, fn ->
        Distill.format_transcript(
          [[Message.new("user", "Q"), Message.new("assistant", "A")]],
          nil,
          "",
          "Eli"
        )
      end
    end

    test "raises ArgumentError on whitespace-only agent_name" do
      assert_raise ArgumentError, ~r/agent_name/, fn ->
        Distill.format_transcript(
          [[Message.new("user", "Q"), Message.new("assistant", "A")]],
          nil,
          "   ",
          "Eli"
        )
      end
    end

    test "raises ArgumentError on nil agent_name" do
      assert_raise ArgumentError, ~r/agent_name/, fn ->
        Distill.format_transcript(
          [[Message.new("user", "Q"), Message.new("assistant", "A")]],
          nil,
          nil,
          "Eli"
        )
      end
    end
  end

  describe "ex-format-transcript > if user_name is missing or blank" do
    test "raises ArgumentError on blank user_name" do
      assert_raise ArgumentError, ~r/user_name/, fn ->
        Distill.format_transcript(
          [[Message.new("user", "Q"), Message.new("assistant", "A")]],
          nil,
          "Susu",
          ""
        )
      end
    end

    test "raises ArgumentError on whitespace-only user_name" do
      assert_raise ArgumentError, ~r/user_name/, fn ->
        Distill.format_transcript(
          [[Message.new("user", "Q"), Message.new("assistant", "A")]],
          nil,
          "Susu",
          "   "
        )
      end
    end

    test "raises ArgumentError on nil user_name" do
      assert_raise ArgumentError, ~r/user_name/, fn ->
        Distill.format_transcript(
          [[Message.new("user", "Q"), Message.new("assistant", "A")]],
          nil,
          "Susu",
          nil
        )
      end
    end
  end

  describe "ex-format-transcript > the LLM call uses a structured-output schema with a single behaviour field" do
    test "Distill.distill_schema/0 returns a single-key NimbleOptions schema" do
      schema = Distill.distill_schema()

      assert Keyword.has_key?(schema, :behaviour)
      assert schema[:behaviour][:type] == :string
      assert schema[:behaviour][:required] == true
    end
  end
end
