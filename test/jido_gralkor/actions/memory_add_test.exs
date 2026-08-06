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

    previous_lenses = Application.get_env(:jido_gralkor, :lenses)

    on_exit(fn ->
      if previous_lenses do
        Application.put_env(:jido_gralkor, :lenses, previous_lenses)
      else
        Application.delete_env(:jido_gralkor, :lenses)
      end
    end)

    :ok
  end

  test "returns immediately without waiting on the client" do
    InMemory.set_memory_add(:ok)

    assert {:ok, %{result: "Ingesting."}} =
             MemoryAdd.run(
               %{content: "Eli prefers tea", source_description: "user preference"},
               %{agent_id: "01USER"}
             )
  end

  test "spawns a background Task that calls the client with sanitized group_id, content, and source_description" do
    InMemory.set_memory_add(:ok)

    MemoryAdd.run(
      %{content: "reflection", source_description: "agent thought"},
      %{agent_id: "user-id"}
    )

    assert eventually(fn ->
             InMemory.adds() == [["user_id", "reflection", "agent thought"]]
           end)
  end

  test "when context selects a Lens then Gralkor.Client.ingest/1 is called in a background Task with the operator, Lens, content, and source description" do
    Process.register(self(), :memory_add_lens_test)

    Application.put_env(:jido_gralkor, :lenses, [
      [
        name: "decisions",
        ontology: LensOntology,
        scope: :operator,
        ingestion: RecordingIngestion
      ]
    ])

    assert {:ok, %{result: "Ingesting."}} =
             MemoryAdd.run(
               %{content: "We chose Friday.", source_description: "agent decision"},
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

  test "if the background Task's client call fails, the failure is logged" do
    InMemory.set_memory_add({:error, :boom})

    log =
      capture_log(fn ->
        assert {:ok, %{result: "Ingesting."}} =
                 MemoryAdd.run(
                   %{content: "something", source_description: "agent thought"},
                   %{agent_id: "01USER"}
                 )

        assert eventually(fn ->
                 InMemory.adds() == [["01USER", "something", "agent thought"]]
               end)

        # Give Logger.error time to flush after the Task's client call.
        Process.sleep(50)
      end)

    assert log =~ "[gralkor] memory_add failed"
    assert log =~ ":boom"
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
