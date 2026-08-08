defmodule Gralkor.LegacyFlushGeneralisationFunctionalTest do
  use ExUnit.Case, async: false

  alias Gralkor.Application, as: GralkorApplication
  alias Gralkor.Message

  @moduletag :functional

  setup do
    turns = [
      [Message.new("user", "The build is slow"), Message.new("assistant", "Use the cache")]
    ]

    %{turns: turns}
  end

  describe "where legacy generalisation on flush is enabled > when an implicit-operator captured transcript is flushed successfully" do
    test "then generalisation is started with that transcript under the capture's group without delaying the flush result",
         %{turns: turns} do
      test_pid = self()

      generalise_fn = fn group_id, transcript ->
        send(test_pid, {:generalised, group_id, transcript})
        Process.sleep(200)
        :ok
      end

      callback = successful_callback(generalise_fn)
      started_at = System.monotonic_time(:millisecond)

      assert :ok = callback.("operator_one", "Susu", "Eli", nil, turns)
      assert System.monotonic_time(:millisecond) - started_at < 150

      assert_receive {:generalised, "operator_one", transcript}
      assert transcript =~ "The build is slow"
      assert transcript =~ "Use the cache"
    end

    test "and a generalisation failure does not change the successful flush result", %{
      turns: turns
    } do
      callback =
        successful_callback(fn _group_id, _transcript -> {:error, :generalise_failed} end)

      assert :ok = callback.("operator_one", "Susu", "Eli", nil, turns)
    end
  end

  describe "where legacy generalisation on flush is disabled > when an implicit-operator captured transcript is flushed successfully" do
    test "then no generalisation is started", %{turns: turns} do
      callback = successful_callback(nil)

      assert :ok = callback.("operator_one", "Susu", "Eli", nil, turns)
      refute_receive {:generalised, _, _}
    end
  end

  defp successful_callback(generalise_fn) do
    GralkorApplication.build_flush_callback(:embedded,
      add_episode_fn: fn _group_id, _body, _source, _ontology, _options -> :ok end,
      generalise_fn: generalise_fn
    )
  end
end
