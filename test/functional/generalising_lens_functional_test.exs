defmodule Gralkor.GeneralisingLensFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  alias Gralkor.Client
  alias Gralkor.Generalisation
  alias Gralkor.Ingest
  alias Gralkor.Lens.Store
  alias Gralkor.Search
  alias JidoGralkor.Plugin

  defmodule GeneralisationOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open

    entity Generalisation do
      field(:content, :string, required: true)
    end
  end

  defmodule FailingStorage do
    @behaviour Gralkor.Lens.Storage

    @impl true
    def add_episode(_store, _content, _source_description), do: {:error, :unavailable}

    @impl true
    def add_episode(_store, _content, _source_description, _opts), do: {:error, :unavailable}

    @impl true
    def remove_episode(_store, _episode_id), do: raise("alternative persistence attempted")

    @impl true
    def search(_store, _query, _max_results), do: raise("alternative persistence attempted")
  end

  setup do
    keys = [
      :lenses,
      :lens_storage,
      :generalise_hypothesise_fn,
      :generalise_evaluate_fn,
      :generalise_min_confidence
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:jido_gralkor, &1)})

    start_supervised!(Gralkor.Lens.Storage.InMemory)

    Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)
    Application.put_env(:jido_gralkor, :lenses, [lens(:operator)])
    Application.put_env(:jido_gralkor, :generalise_min_confidence, 0.3)

    on_exit(fn -> Enum.each(previous, fn {key, value} -> restore_env(key, value) end) end)

    :ok
  end

  describe "when a transcript is submitted through Gralkor's generalising ingestion process" do
    test "then the process distils zero or more durable generalisation episodes" do
      Application.put_env(:jido_gralkor, :generalise_hypothesise_fn, fn _prompt ->
        {:ok,
         [
           %{content: "Eli prefers Friday launches.", confidence: 0.9},
           %{content: "Eli communicates launch changes early.", confidence: 0.8}
         ]}
      end)

      assert :ok = ingest("operator-one", "A Friday launch was communicated early.")

      assert [
               %{content: "Eli prefers Friday launches."},
               %{content: "Eli communicates launch changes early."}
             ] = episodes({"operator-one", "generalisations"})
    end

    test "and each resulting episode is added through the selected Lens with its ontology and memory destination" do
      Application.put_env(:jido_gralkor, :generalise_hypothesise_fn, fn _prompt ->
        {:ok, [%{content: "Eli prefers Friday launches.", confidence: 0.9}]}
      end)

      assert :ok = ingest("operator-one", "A Friday launch was chosen.")

      assert [%{content: "Eli prefers Friday launches.", lens: "generalisations"}] =
               episodes({"operator-one", "generalisations"})

      assert %Gralkor.Lens{
               ontology: GeneralisationOntology,
               scope: :operator,
               ingestion: Gralkor.Lens.Ingestion.Generalise
             } = Client.lens!("generalisations")
    end

    test "and repeated or contradicted facts are reconciled while their source episodes remain as provenance" do
      store = %Store{
        operator_id: "operator-one",
        lens: Client.lens!("generalisations")
      }

      existing = %Generalisation{
        id: "existing-one",
        content: "Eli avoids Friday launches.",
        level: 0,
        confidence: 0.7
      }

      assert :ok =
               Store.add(
                 store,
                 Generalisation.encode(existing),
                 "earlier transcript",
                 uuid: existing.id
               )

      Application.put_env(:jido_gralkor, :generalise_hypothesise_fn, fn _prompt ->
        {:ok, [%{content: "Eli prefers Friday launches.", confidence: 0.9}]}
      end)

      Application.put_env(:jido_gralkor, :generalise_evaluate_fn, fn _prompt ->
        {:ok,
         [
           %{
             action: "contradicts",
             hypothesis_index: 0,
             confidence: 0.9,
             content: "Eli prefers Friday launches.",
             existing_id: "existing-one"
           }
         ]}
      end)

      assert :ok =
               Client.ingest(%Ingest{
                 operator_id: "operator-one",
                 lens: "generalisations",
                 content: "Eli now schedules launches on Friday.",
                 source_description: "new transcript"
               })

      assert [
               %{id: "existing-one"},
               %{content: new_episode, lens: "generalisations"}
             ] = Gralkor.Lens.Storage.InMemory.episodes({"operator-one", "generalisations"})

      assert new_episode =~ "Eli prefers Friday launches."
    end

    test "and the caller observes whether ingestion succeeded or failed" do
      Application.put_env(:jido_gralkor, :generalise_hypothesise_fn, fn _prompt -> {:ok, []} end)
      assert :ok = ingest("operator-one", "No durable pattern.")

      Application.put_env(:jido_gralkor, :generalise_hypothesise_fn, fn _prompt ->
        {:error, :unavailable}
      end)

      assert {:error, :unavailable} = ingest("operator-one", "Unavailable distillation.")
    end
  end

  describe "where the generalising Lens is operator-local" do
    test "then its resulting memory is available only to that operator through that Lens" do
      Application.put_env(:jido_gralkor, :generalise_hypothesise_fn, fn _prompt ->
        {:ok, [%{content: "Eli prefers Friday launches.", confidence: 0.9}]}
      end)

      assert :ok = ingest("operator-one", "A Friday launch was chosen.")

      assert {:ok, ["Eli prefers Friday launches."]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "Friday",
                 targets: ["generalisations"]
               })

      assert {:ok, []} =
               Client.search(%Search{
                 operator_id: "operator-two",
                 query: "Friday",
                 targets: ["generalisations"]
               })
    end
  end

  describe "where the generalising Lens is global" do
    test "then its resulting memory enters shared global memory" do
      Application.put_env(:jido_gralkor, :lenses, [lens(:global)])
      set_hypothesis("Eli prefers Friday launches.")

      assert :ok = ingest("operator-one", "A Friday launch was chosen.")

      assert {:ok, ["Eli prefers Friday launches."]} =
               Client.search(%Search{
                 operator_id: "operator-two",
                 query: "Friday",
                 targets: ["global"]
               })
    end

    test "and every resulting episode records the generalising Lens as its origin" do
      Application.put_env(:jido_gralkor, :lenses, [lens(:global)])
      set_hypothesis("Eli prefers Friday launches.")

      assert :ok = ingest("operator-one", "A Friday launch was chosen.")

      assert [%{lens: "generalisations"}] = episodes(:global)
    end
  end

  describe "where capture is configured to generalise a flushed transcript through another Lens" do
    test "then the generalising Lens receives the transcript independently of the Lens that captured it" do
      Application.put_env(:jido_gralkor, :client, Gralkor.Client.Native)

      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "observations",
          ontology: GeneralisationOntology,
          scope: :operator,
          ingestion: Gralkor.Lens.Ingestion.Store
        ],
        lens(:global)
      ])

      set_hypothesis("Eli prefers Friday launches.")

      start_supervised!(
        {Gralkor.CaptureBuffer,
         flush_callback: fn _, _, _, _, _ -> :ok end,
         lens_flush_callback: Gralkor.Application.build_lens_flush_callback(),
         retries: []}
      )

      assert {:ok, plugin_state} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 default_lens: "observations",
                 generalise_lens: "generalisations"
               )

      request_id = "generalising-request"

      agent = %{
        id: "operator-one",
        state: %{
          __memory__: plugin_state,
          __thread__: %{id: "session-one"},
          __strategy__: %{
            request_traces: %{
              request_id => %{events: [%{kind: :llm_completed, data: %{}}]}
            }
          },
          requests: %{
            request_id => %{query: "Let's launch Friday.", status: :pending, result: nil}
          },
          user_name: "Eli"
        }
      }

      signal = %Jido.Signal{
        id: "completion-signal",
        source: "/functional",
        type: "ai.request.completed",
        data: %{request_id: request_id, result: "Agreed."}
      }

      assert {:ok, :continue} = Plugin.handle_signal(signal, %{agent: agent})
      assert :ok = Gralkor.Client.Native.flush_and_await("session-one", 1_000)

      assert [_observation] = episodes({"operator-one", "observations"})
      assert [%{content: "Eli prefers Friday launches."}] = episodes(:global)
    end

    test "and each Lens retains its own ontology, scope, and ingestion process" do
      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "observations",
          ontology: GeneralisationOntology,
          scope: :operator,
          ingestion: Gralkor.Lens.Ingestion.Store
        ],
        lens(:global)
      ])

      assert %Gralkor.Lens{scope: :operator, ingestion: Gralkor.Lens.Ingestion.Store} =
               Client.lens!("observations")

      assert %Gralkor.Lens{scope: :global, ingestion: Gralkor.Lens.Ingestion.Generalise} =
               Client.lens!("generalisations")
    end
  end

  describe "if distillation produces no durable generalisation" do
    test "then no episode is submitted to Graphiti" do
      Application.put_env(:jido_gralkor, :generalise_hypothesise_fn, fn _prompt ->
        {:ok, [%{content: "weak", confidence: 0.1}]}
      end)

      assert :ok = ingest("operator-one", "No durable pattern.")
      assert episodes({"operator-one", "generalisations"}) == []
    end

    test "and ingestion completes successfully" do
      Application.put_env(:jido_gralkor, :generalise_hypothesise_fn, fn _prompt -> {:ok, []} end)

      assert :ok = ingest("operator-one", "No durable pattern.")
    end
  end

  describe "if distillation or memory ingestion fails" do
    test "then ingestion returns the failure without performing an alternative persistence write" do
      Application.put_env(:jido_gralkor, :lens_storage, FailingStorage)
      set_hypothesis("Eli prefers Friday launches.")

      assert {:error, :unavailable} = ingest("operator-one", "A Friday launch was chosen.")
    end
  end

  defp lens(scope) do
    [
      name: "generalisations",
      ontology: GeneralisationOntology,
      scope: scope,
      ingestion: Gralkor.Lens.Ingestion.Generalise
    ]
  end

  defp ingest(operator_id, content) do
    Client.ingest(%Ingest{
      operator_id: operator_id,
      lens: "generalisations",
      content: content,
      source_description: "functional"
    })
  end

  defp episodes(key), do: Gralkor.Lens.Storage.InMemory.episodes(key)

  defp set_hypothesis(content) do
    Application.put_env(:jido_gralkor, :generalise_hypothesise_fn, fn _prompt ->
      {:ok, [%{content: content, confidence: 0.9}]}
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
