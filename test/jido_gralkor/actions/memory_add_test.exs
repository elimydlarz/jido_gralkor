defmodule JidoGralkor.Actions.MemoryAddTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Gralkor.Client.InMemory
  alias JidoGralkor.Actions.MemoryAdd

  defmodule LensOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open
  end

  defmodule RecordingIngestion do
    def ingest(request, store) do
      send(Process.whereis(:memory_add_lens_test), {:lens_ingest, request, store})
      :ok
    end
  end

  setup do
    InMemory.reset()

    previous_destinations = Application.get_env(:jido_gralkor, :destinations)
    previous_lenses = Application.get_env(:jido_gralkor, :lenses)

    on_exit(fn ->
      if previous_destinations do
        Application.put_env(:jido_gralkor, :destinations, previous_destinations)
      else
        Application.delete_env(:jido_gralkor, :destinations)
      end

      if previous_lenses do
        Application.put_env(:jido_gralkor, :lenses, previous_lenses)
      else
        Application.delete_env(:jido_gralkor, :lenses)
      end
    end)

    :ok
  end

  describe "when the memory add tool runs with content and a source description" do
    test "then it returns an acknowledgement immediately, without waiting on the write" do
      InMemory.set_memory_add(:ok)

      assert {:ok, %{result: "Ingesting."}} =
               MemoryAdd.run(
                 %{
                   content: "Eli prefers tea",
                   source_kind: :conversation,
                   source_description: "user preference"
                 },
                 %{agent_id: "01USER"}
               )
    end

    test "and the write is carried out in the background under the operator's sanitised group id, carrying the content and source description as given" do
      InMemory.set_memory_add(:ok)

      MemoryAdd.run(
        %{
          content: "reflection",
          source_kind: :conversation,
          source_description: "agent thought"
        },
        %{agent_id: "user-id"}
      )

      assert eventually(fn ->
               InMemory.adds() == [["user_id", "reflection", "agent thought"]]
             end)
    end
  end

  describe "when the memory add tool runs with content and a source description > where the tool context selects a Lens" do
    test "then the background write is routed to that Lens's ingestion for the operator, carrying the content and source description" do
      Process.register(self(), :memory_add_lens_test)

      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "decisions",
          destination: "decisions",
          ingestion: RecordingIngestion
        ]
      ])

      Application.put_env(:jido_gralkor, :destinations, [
        [name: "decisions", address: "operator/decisions", ontology: LensOntology]
      ])

      assert {:ok, %{result: "Ingesting."}} =
               MemoryAdd.run(
                 %{
                   content: "We chose Friday.",
                   source_kind: :conversation,
                   source_description: "agent decision"
                 },
                 %{agent_id: "operator-one", lens: "decisions"}
               )

      assert_receive {:lens_ingest,
                      %Gralkor.Ingest{
                        operator_id: "operator-one",
                        lens: "decisions",
                        content: "We chose Friday.",
                        source_description: "agent decision"
                      }, %{lens: %{name: "decisions"}}}
    end
  end

  describe "when the memory add tool runs with content and a source description > if the background write fails" do
    test "then the failure is logged" do
      InMemory.set_memory_add({:error, :boom})

      log =
        capture_log(fn ->
          assert {:ok, %{result: "Ingesting."}} =
                   MemoryAdd.run(
                     %{
                       content: "something",
                       source_kind: :conversation,
                       source_description: "agent thought"
                     },
                     %{agent_id: "01USER"}
                   )

          assert eventually(fn ->
                   InMemory.adds() == [["01USER", "something", "agent thought"]]
                 end)

          Process.sleep(50)
        end)

      assert log =~ "[gralkor] memory_add failed"
      assert log =~ ":boom"
    end

    test "and the caller's acknowledgement is unaffected" do
      InMemory.set_memory_add({:error, :boom})

      assert {:ok, %{result: "Ingesting."}} =
               MemoryAdd.run(
                 %{
                   content: "something",
                   source_kind: :conversation,
                   source_description: "agent thought"
                 },
                 %{agent_id: "01USER"}
               )
    end
  end

  defp eventually(fun, timeout_ms \\ 500, interval_ms \\ 10) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline, interval_ms)
  end

  defp do_eventually(fun, deadline, interval_ms) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(interval_ms)
        do_eventually(fun, deadline, interval_ms)
      end
    end
  end
end
