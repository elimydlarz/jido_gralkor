defmodule Gralkor.ReflectionCompletionFunctionalTest do
  use ExUnit.Case, async: false

  alias Gralkor.Client
  alias Gralkor.Ingest
  alias Gralkor.Reflection
  alias Gralkor.Reflection.ChainOfThought
  alias Gralkor.Reflection.Scheduler
  alias Gralkor.Search

  @moduletag :functional

  defmodule StoredDocument do
    @behaviour Gralkor.Lens.Ingestion

    @impl true
    def ingest(request, store) do
      Gralkor.Lens.Store.add(store, request.content, request.source_description)
    end
  end

  setup do
    previous =
      for key <- [
            :destinations,
            :destination_storage,
            :lenses,
            :lens_storage,
            :reflections,
            :reflection_storage
          ],
          into: %{} do
        {key, Application.get_env(:jido_gralkor, key)}
      end

    on_exit(fn -> Enum.each(previous, fn {key, value} -> restore_env(key, value) end) end)

    start_supervised!(Gralkor.Lens.Storage.InMemory)
    start_supervised!(Gralkor.Reflection.Storage.InMemory)

    Application.put_env(:jido_gralkor, :destinations, [[name: "observations"]])

    Application.put_env(:jido_gralkor, :lenses, [
      [name: "observations", destination: "observations", ingestion: StoredDocument]
    ])

    Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)
    Application.put_env(
      :jido_gralkor,
      :destination_storage,
      Gralkor.Destination.Storage.InMemory
    )

    Application.put_env(:jido_gralkor, :reflection_storage, Gralkor.Reflection.Storage.InMemory)

    reflection = %Reflection{
      name: "review",
      destination: %Gralkor.Destination{name: "observations"},
      ontology: Gralkor.DefaultOntology,
      chain_of_thought: %ChainOfThought{
        path: "reflection-completion.yaml",
        steps: [
          %ChainOfThought.Step{
            label: "review",
            directions: "Review the ingested information.",
            output: %{"summary" => "string"}
          }
        ]
      }
    }

    Application.put_env(:jido_gralkor, :reflections, [reflection])

    test_pid = self()

    start_supervised!(
      {Scheduler,
       runner: fn reflected, ingestion, opts ->
         send(test_pid, {:runner_started, reflected.name, ingestion.id, self()})

         receive do
           :finish_reflection ->
             Gralkor.Reflection.Runner.run(
               reflected,
               ingestion,
               Keyword.put(opts, :inference, fn _ ->
                 {:ok, %{output: %{"summary" => "stored"}}}
               end)
             )
         end
       end,
       notify: test_pid}
    )

    :ok
  end

  describe "when an application ingests information under a stable ingestion identifier while Reflections are declared" do
    test "then ingestion returns without waiting for Reflection completion" do
      started = System.monotonic_time(:millisecond)

      assert :ok =
               Client.ingest(ingestion())

      assert System.monotonic_time(:millisecond) - started < 100
      assert_receive {:runner_started, "review", "ingestion-one", _runner}
    end

    test "then replay after a Scheduler restart retains one stable searchable artefact" do
      assert :ok = Client.ingest(ingestion())
      assert_receive {:runner_started, "review", "ingestion-one", first_runner}
      send(first_runner, :finish_reflection)
      assert_receive {:reflection_completed, "review", {:ok, first_artefact}}

      first_scheduler = Process.whereis(Scheduler)
      GenServer.stop(first_scheduler)
      assert eventually(fn -> Process.whereis(Scheduler) not in [nil, first_scheduler] end)

      assert :ok = Client.ingest(ingestion())
      assert_receive {:runner_started, "review", "ingestion-one", second_runner}
      send(second_runner, :finish_reflection)
      assert_receive {:reflection_completed, "review", {:ok, second_artefact}}

      assert second_artefact.id == first_artefact.id

      assert {:ok, [%{destination: "observations", artefact: searchable}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "stored",
                 destinations: ["observations"],
                 result_type: :artefacts
               })

      assert searchable.id == first_artefact.id
    end
  end

  defp ingestion do
    %Ingest{
      id: "ingestion-one",
      operator_id: "operator-one",
      lens: "observations",
      source_kind: :document,
      content: "The deployment succeeded.",
      source_description: "deployment",
      evidence_id: "evidence-one"
    }
  end

  defp eventually(assertion, attempts \\ 100)

  defp eventually(assertion, attempts) when attempts > 0 do
    if assertion.() do
      true
    else
      Process.sleep(10)
      eventually(assertion, attempts - 1)
    end
  end

  defp eventually(_assertion, 0), do: false

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
