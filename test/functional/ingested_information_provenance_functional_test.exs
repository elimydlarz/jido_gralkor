defmodule Gralkor.IngestedInformationProvenanceFunctionalTest do
  use ExUnit.Case, async: false

  alias Gralkor.Client
  alias Gralkor.GraphitiPool
  alias Gralkor.Ingest
  alias Gralkor.Search

  @moduletag :functional

  defmodule RecordingStorage do
    @behaviour Gralkor.Lens.Storage

    @impl true
    def add_episode(store, content, source_description) do
      send(
        Process.whereis(:ingested_information_provenance_functional),
        {:episode_added, store, content, source_description}
      )

      :ok
    end

    @impl true
    def search(_store, _query, _max_results), do: {:ok, []}

    @impl true
    def replace_graph(_store, _graph), do: :ok
  end

  defmodule NativeBoundaryStorage do
    @behaviour Gralkor.Lens.Storage

    @impl true
    def add_episode(store, content, source_description) do
      Gralkor.Lens.Storage.Graphiti.add_episode(store, content, source_description,
        add_episode_fn: fn group_id, body, description, ontology, opts ->
          Gralkor.GraphitiPool.add_episode(
            Process.whereis(Gralkor.GraphitiPool),
            group_id,
            body,
            description,
            ontology,
            opts
          )
        end
      )
    end

    @impl true
    def search(_store, _query, _max_results), do: {:ok, []}

    @impl true
    def replace_graph(_store, _graph), do: :ok
  end

  setup do
    Process.register(self(), :ingested_information_provenance_functional)

    previous_destinations = Application.get_env(:jido_gralkor, :destinations)
    previous_lenses = Application.get_env(:jido_gralkor, :lenses)
    previous_storage = Application.get_env(:jido_gralkor, :lens_storage)
    previous_destination_storage = Application.get_env(:jido_gralkor, :destination_storage)

    Application.put_env(:jido_gralkor, :destinations, [
      [name: "observations"]
    ])

    Application.put_env(:jido_gralkor, :lenses, [
      [
        name: "observations",
        destination: "observations",
        ingestion: Gralkor.Lens.Ingestion.Store
      ]
    ])

    Application.put_env(:jido_gralkor, :lens_storage, RecordingStorage)

    Application.put_env(
      :jido_gralkor,
      :destination_storage,
      Gralkor.Destination.Storage.Graphiti
    )

    on_exit(fn ->
      restore_env(:destinations, previous_destinations)
      restore_env(:lenses, previous_lenses)
      restore_env(:lens_storage, previous_storage)
      restore_env(:destination_storage, previous_destination_storage)
    end)

    :ok
  end

  describe "when information is submitted through public ingestion with a supported source kind" do
    test "then its stored episode retains the declared source kind" do
      assert :ok =
               Client.ingest(%Ingest{
                 operator_id: "operator-one",
                 lens: "observations",
                 source_kind: :conversation,
                 content: "Mina: Atlas might launch Friday.",
                 source_description: "planning conversation"
               })

      assert_receive {:episode_added, %Gralkor.Lens.Store{source_kind: :conversation},
                      "Mina: Atlas might launch Friday.", "planning conversation"}
    end

    test "and its stored episode retains the reported source description" do
      assert :ok = Client.ingest(request(:document, "Draft launch plan", "Q3 Roadmap — Draft"))

      assert_receive {:episode_added, %Gralkor.Lens.Store{}, "Draft launch plan",
                      "Q3 Roadmap — Draft"}
    end

    test "and every returned fact identifies each originating episode by identifier, source kind, and source description" do
      graphiti = use_native_boundary()

      set_search_fixture(graphiti, [
        %{
          fact: "Mina speculated that Atlas might launch Friday.",
          episodes: [
            %{
              id: "episode-document-1",
              source_kind: "text",
              source_description: "Q3 Roadmap — Draft"
            }
          ]
        }
      ])

      assert {:ok, [%{fact: recalled_fact}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "Atlas launch",
                 destinations: ["observations"]
               })

      assert recalled_fact =~ "Mina speculated that Atlas might launch Friday."
      assert recalled_fact =~ "episode-document-1"
      assert recalled_fact =~ "document"
      assert recalled_fact =~ "Q3 Roadmap — Draft"
    end

    test "and recall presents the extracted fact wording and its source attribution without rewriting either" do
      graphiti = use_native_boundary()
      fact = "Mina speculated that Atlas might launch Friday."

      set_search_fixture(graphiti, [
        %{
          fact: fact,
          episodes: [
            %{
              id: "episode-conversation-1",
              source_kind: "message",
              source_description: "planning conversation"
            }
          ]
        }
      ])

      assert {:ok, memory} =
               Gralkor.Client.Native.recall(
                 "observations",
                 "Gralkor",
                 "session-one",
                 "Atlas launch"
               )

      assert memory =~ fact

      assert memory =~
               "source: conversation — planning conversation; episode: episode-conversation-1"
    end

    test "then Graphiti's existing episode extraction is instructed to preserve source attribution and epistemic wording in extracted facts" do
      graphiti = use_native_boundary()

      assert :ok =
               Client.ingest(
                 request(:document, "Atlas might launch Friday.", "Q3 Roadmap — Draft")
               )

      assert [%{"custom_extraction_instructions" => instructions}] = added_episodes(graphiti)
      assert instructions =~ "source attribution"
      assert instructions =~ "uncertainty"
      assert instructions =~ "speculation"
    end

    test "and Gralkor initiates no separate presentation-classification inference" do
      graphiti = use_native_boundary()

      assert :ok =
               Client.ingest(
                 request(:conversation, "Mina: Atlas might launch Friday.", "planning chat")
               )

      assert [_single_existing_extraction] = added_episodes(graphiti)
    end
  end

  describe "where the source kind is conversation" do
    test "while the supplied content is speaker-attributed text then Graphiti receives a conversational-message episode containing that text" do
      graphiti = use_native_boundary()

      assert :ok =
               Client.ingest(
                 request(
                   :conversation,
                   "Mina: Atlas might launch Friday.",
                   "planning conversation"
                 )
               )

      assert [%{"body" => "Mina: Atlas might launch Friday.", "source" => "message"}] =
               added_episodes(graphiti)
    end
  end

  describe "where the source kind is document" do
    test "while the supplied content is text then Graphiti receives a document-text episode containing that text" do
      graphiti = use_native_boundary()

      assert :ok =
               Client.ingest(request(:document, "Atlas launch proposal", "Q3 Roadmap — Draft"))

      assert [%{"body" => "Atlas launch proposal", "source" => "text"}] =
               added_episodes(graphiti)
    end
  end

  describe "where the source kind is structured record" do
    test "while the supplied content is a JSON-compatible map or list then Graphiti receives a structured-data episode containing its JSON encoding" do
      graphiti = use_native_boundary()

      assert :ok =
               Client.ingest(
                 request(
                   :structured_record,
                   %{"project" => "Atlas", "status" => "proposed"},
                   "project registry"
                 )
               )

      assert [%{"body" => body, "source" => "json"}] = added_episodes(graphiti)
      assert Jason.decode!(body) == %{"project" => "Atlas", "status" => "proposed"}
    end
  end

  describe "when captured conversation turns are ingested automatically" do
    test "then Gralkor supplies conversation as their source kind" do
      test_pid = self()

      callback =
        Gralkor.Application.build_lens_flush_callback(
          ingest_fn: fn request ->
            send(test_pid, {:captured_ingest, request})
            {:ok, []}
          end
        )

      assert {:ok, []} =
               callback.(
                 "operator-one",
                 "Gralkor",
                 "Mina",
                 "observations",
                 [[Gralkor.Message.new("user", "Atlas might launch Friday.")]],
                 "evidence-1"
               )

      assert_receive {:captured_ingest, %Ingest{source_kind: :conversation}}
    end

    test "and their rendered speaker-attributed transcript is submitted as a conversational-message episode" do
      test_pid = self()

      callback =
        Gralkor.Application.build_flush_callback(nil,
          add_episode_fn: fn group_id, body, description, ontology, opts ->
            send(test_pid, {:captured_episode, group_id, body, description, ontology, opts})
            :ok
          end
        )

      assert :ok =
               callback.(
                 "operator-one",
                 "Gralkor",
                 "Mina",
                 nil,
                 [[Gralkor.Message.new("user", "Atlas might launch Friday.")]]
               )

      assert_receive {:captured_episode, "operator-one", "Mina: Atlas might launch Friday.",
                      "captured", nil, [source_kind: :conversation]}
    end
  end

  describe "if public ingestion omits or supplies an unsupported source kind" do
    test "then ingestion raises an argument error identifying the rejected source kind" do
      for source_kind <- [nil, :rumour] do
        assert_raise ArgumentError, ~r/source kind.*#{inspect(source_kind)}/i, fn ->
          Client.ingest(request(source_kind, "Atlas launches Friday.", "planning notes"))
        end
      end
    end

    test "and no Lens ingestion process or Graphiti operation begins" do
      assert_raise ArgumentError, fn ->
        Client.ingest(request(:rumour, "Atlas launches Friday.", "planning notes"))
      end

      refute_receive {:episode_added, _, _, _}
    end
  end

  describe "if public ingestion supplies content whose shape does not correspond to its source kind" do
    test "then ingestion raises an argument error identifying the rejected source content" do
      invalid_sources = [
        {:conversation, %{"speaker" => "Mina"}},
        {:document, ["draft"]},
        {:structured_record, "already encoded JSON"},
        {:structured_record, %{"pid" => self()}}
      ]

      for {source_kind, content} <- invalid_sources do
        assert_raise ArgumentError, ~r/source content.*#{source_kind}/i, fn ->
          Client.ingest(request(source_kind, content, "invalid fixture"))
        end
      end
    end

    test "and no Lens ingestion process or Graphiti operation begins" do
      assert_raise ArgumentError, fn ->
        Client.ingest(request(:document, ["not document text"], "invalid fixture"))
      end

      refute_receive {:episode_added, _, _, _}
    end
  end

  defp request(source_kind, content, source_description) do
    %Ingest{
      operator_id: "operator-one",
      lens: "observations",
      source_kind: source_kind,
      content: content,
      source_description: source_description
    }
  end

  defp use_native_boundary do
    Application.put_env(:jido_gralkor, :lens_storage, NativeBoundaryStorage)

    {graphiti, _} =
      Pythonx.eval(
        """
        class _Graphiti:
            def __init__(self):
                self.added = []
                self.facts = []
                self.episodes = {}
                self.driver = _Driver(self)

            async def add_episode(self, **kwargs):
                self.added.append({
                    "body": kwargs.get("episode_body"),
                    "source": kwargs.get("source").value,
                    "source_description": kwargs.get("source_description"),
                    "custom_extraction_instructions": kwargs.get("custom_extraction_instructions"),
                })

            async def search(self, query, num_results=10, search_filter=None):
                return self.facts[:num_results]

        class _Edge:
            def __init__(self, fact, episodes):
                self.fact = fact
                self.episodes = episodes
                self.created_at = None
                self.valid_at = None
                self.invalid_at = None
                self.expired_at = None

        class _Episode:
            def __init__(self, uuid, source, source_description):
                from graphiti_core.nodes import EpisodeType
                self.uuid = uuid
                self.source = EpisodeType(source)
                self.source_description = source_description

        class _GraphOperations:
            def __init__(self, graphiti):
                self.graphiti = graphiti

            async def episodic_node_get_by_uuids(self, cls, driver, uuids):
                return [self.graphiti.episodes[uuid] for uuid in uuids]

        class _Driver:
            def __init__(self, graphiti):
                self.graph_operations_interface = _GraphOperations(graphiti)

        graphiti = _Graphiti()
        graphiti.Edge = _Edge
        graphiti.Episode = _Episode
        graphiti
        """,
        %{}
      )

    start_supervised!(
      {GraphitiPool,
       name: Gralkor.GraphitiPool,
       table: :gralkor_graphiti_instances,
       falkordb_spec: {:embedded, "/tmp/never_used"},
       construct_falkor_db: fn _spec -> :stub_falkor_db end,
       construct_shared_clients: fn _llm, _embedder ->
         %{llm_client: nil, embedder: nil, cross_encoder: nil}
       end,
       construct_instance: fn _db, _shared, _group_id -> graphiti end,
       initialise_instance: fn _instance -> :ok end,
       warmup: false,
       install_loop_fn: &Gralkor.Python.install_async_runtime/0}
    )

    graphiti
  end

  defp added_episodes(graphiti) do
    {episodes, _} = Pythonx.eval("g.added", %{"g" => graphiti})
    Pythonx.decode(episodes)
  end

  defp set_search_fixture(graphiti, facts) do
    Pythonx.eval(
      """
      g.facts = []
      g.episodes = {}
      def _dec(value):
          return value.decode('utf-8') if isinstance(value, (bytes, bytearray)) else value
      for item in facts:
          episode_ids = []
          for source in item['episodes']:
              episode = g.Episode(
                  _dec(source['id']),
                  _dec(source['source_kind']),
                  _dec(source['source_description']),
              )
              g.episodes[episode.uuid] = episode
              episode_ids.append(episode.uuid)
          g.facts.append(g.Edge(_dec(item['fact']), episode_ids))
      """,
      %{"g" => graphiti, "facts" => facts}
    )
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
