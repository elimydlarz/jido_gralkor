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
                 id: "provenance-conversation",
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

    test "and public episode search presents the originating Lens separately from episode content and source description" do
      graphiti = use_native_boundary()

      set_episode_search_fixture(graphiti, [
        %{
          content: "Draft launch plan",
          source_description: "Q3 Roadmap — Draft [lens: observations]"
        }
      ])

      assert {:ok,
              [
                %{
                  destination: "observations",
                  episode: %{
                    content: "Draft launch plan",
                    source_description: "Q3 Roadmap — Draft",
                    lens: "observations"
                  }
                }
              ]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "launch",
                 destinations: ["observations"],
                 result_type: :episodes
               })
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
                 destinations: ["observations"],
                 result_type: :facts
               })

      assert %{fact: "Mina speculated that Atlas might launch Friday.", sources: [source]} =
               recalled_fact

      assert source == %{
               id: "episode-document-1",
               source_kind: "document",
               source_description: "Q3 Roadmap — Draft"
             }
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

  describe "where the source kind is conversation > while the supplied content is speaker-attributed text" do
    test "then Graphiti receives a conversational-message episode containing that text" do
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

  describe "where the source kind is document > while the supplied content is text" do
    test "then Graphiti receives a document-text episode containing that text" do
      graphiti = use_native_boundary()

      assert :ok =
               Client.ingest(request(:document, "Atlas launch proposal", "Q3 Roadmap — Draft"))

      assert [%{"body" => "Atlas launch proposal", "source" => "text"}] =
               added_episodes(graphiti)
    end
  end

  describe "where the source kind is structured record > while the supplied content is a JSON-compatible map or list" do
    test "then Graphiti receives a structured-data episode containing its JSON encoding" do
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
                 "ingestion-1",
                 nil
               )

      assert_receive {:captured_ingest, %Ingest{id: "ingestion-1", source_kind: :conversation}}
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
                      "captured", nil, opts}

      assert opts[:source_kind] == :conversation
      assert opts[:writer] == :direct
      refute Keyword.has_key?(opts, :lens)
    end
  end

  describe "when information is added or captured directly without a selected Lens" do
    test "then its source kind and description remain unchanged without Lens or Reflection authorship" do
      graphiti = use_native_boundary()

      assert :ok =
               Gralkor.Client.Native.memory_add(
                 "personal/operator-one",
                 "Remember the launch plan.",
                 "manual",
                 :document
               )

      assert [
               %{
                 "source_description" => "manual [gralkor: direct]",
                 "source" => "text",
                 "writer" => "direct"
               }
             ] =
               added_episodes(graphiti)
    end

    test "and public episode and fact search include it without a Lens selector" do
      graphiti = use_native_boundary()

      set_episode_search_fixture(graphiti, [
        %{
          content: "Direct memory",
          source_description: "captured [gralkor: direct]",
          writer: "direct"
        }
      ])

      assert {:ok, [%{episode: episode}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "Direct",
                 destinations: ["personal"]
               })

      assert episode.content == "Direct memory"
      assert episode.source_description == "captured"
      assert episode.writer == :direct
      refute Map.has_key?(episode, :lens)
      refute Map.has_key?(episode, :reflection)

      set_search_fixture(graphiti, [
        %{
          fact: "Direct fact",
          episodes: [
            %{
              id: "direct-one",
              source_kind: "message",
              source_description: "captured [gralkor: direct]",
              writer: "direct"
            }
          ]
        }
      ])

      assert {:ok, [%{fact: %{sources: [source]}}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "Direct",
                 destinations: ["personal"],
                 result_type: :facts
               })

      assert source == %{
               id: "direct-one",
               source_kind: "conversation",
               source_description: "captured",
               writer: :direct
             }
    end

    test "and a historical direct-looking description remains unclassified without durable provenance" do
      graphiti = use_native_boundary()

      set_episode_search_fixture(graphiti, [
        %{content: "Historical memory", source_description: "captured [gralkor: direct]"}
      ])

      assert {:ok, [%{episode: episode}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "Historical",
                 destinations: ["personal"]
               })

      assert episode.source_description == "captured [gralkor: direct]"
      refute Map.has_key?(episode, :writer)
    end

    test "and storage-owned direct provenance prevents writer-like source descriptions from claiming Lens or Reflection authorship" do
      graphiti = use_native_boundary()

      descriptions = [
        "manual [lens: observations]",
        "reflection:generalisations",
        "manual [gralkor: direct] [lens: observations]",
        "reflection:generalisations [gralkor: direct]"
      ]

      for source <- descriptions do
        assert :ok =
                 Gralkor.Client.Native.memory_add(
                   "personal/operator-one",
                   "A caller cannot choose its writer.",
                   source,
                   :document
                 )
      end

      stored = Enum.map(added_episodes(graphiti), & &1["source_description"])
      assert stored == Enum.map(descriptions, &(&1 <> " [gralkor: direct]"))

      set_episode_search_fixture(
        graphiti,
        Enum.map(
          stored,
          &%{
            content: "A caller cannot choose its writer.",
            source_description: &1,
            extraction_complete: false
          }
        )
      )

      assert {:ok, []} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "caller",
                 destinations: ["personal"],
                 lenses: ["observations"]
               })

      assert {:ok, episodes} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "caller",
                 destinations: ["personal"]
               })

      assert Enum.map(episodes, & &1.episode.source_description) == descriptions

      assert Enum.all?(
               episodes,
               &(not Map.has_key?(&1.episode, :lens) and not Map.has_key?(&1.episode, :reflection))
             )
    end

    test "and writer-like source descriptions do not impose Reflection completion requirements" do
      graphiti = use_native_boundary()

      set_episode_search_fixture(graphiti, [
        %{
          content: "Direct memory",
          source_description: "reflection:generalisations [gralkor: direct]",
          writer: "direct",
          extraction_complete: false
        }
      ])

      assert {:ok, [%{episode: %{content: "Direct memory", writer: :direct}}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "Direct",
                 destinations: ["personal"]
               })
    end
  end

  describe "when public search reads historical operator-labelled episodes" do
    test "then their recorded operator Lens provenance remains visible without registering that Lens" do
      graphiti = use_native_boundary()

      set_episode_search_fixture(graphiti, [
        %{content: "Historical memory", source_description: "captured [lens: operator]"}
      ])

      assert {:ok, [%{episode: %{content: "Historical memory", lens: "operator"}}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "Historical",
                 destinations: ["personal"]
               })
    end

    test "and a personal-chat Lens selector does not match those historical episodes" do
      graphiti = use_native_boundary()

      set_episode_search_fixture(graphiti, [
        %{content: "Historical memory", source_description: "captured [lens: operator]"}
      ])

      assert {:ok, []} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "Historical",
                 destinations: ["personal"],
                 lenses: ["personal-chat"]
               })
    end
  end

  describe "when public episode search encounters an incomplete Reflection episode" do
    test "then the incomplete Reflection episode does not contribute" do
      graphiti = use_native_boundary()

      set_episode_search_fixture(graphiti, [
        %{
          id: "incomplete-generalisation",
          content: ~s({"id":"incomplete-generalisation"}),
          source_description: "reflection:generalisations",
          extraction_complete: false
        },
        %{
          id: "complete-observation",
          content: "A complete Lens observation.",
          source_description: "field notes [lens: observations]",
          extraction_complete: true
        }
      ])

      assert {:ok,
              [
                %{
                  destination: "observations",
                  episode: %{
                    content: "A complete Lens observation.",
                    source_description: "field notes",
                    lens: "observations"
                  }
                }
              ]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "complete",
                 destinations: ["observations"],
                 max_results: 1
               })
    end

    test "and completion filtering occurs before the per-Destination result limit" do
      graphiti = use_native_boundary()

      set_episode_search_fixture(graphiti, [
        %{
          id: "incomplete-generalisation",
          content: ~s({"id":"incomplete-generalisation"}),
          source_description: "reflection:generalisations",
          extraction_complete: false
        },
        %{
          id: "complete-observation",
          content: "A complete Lens observation.",
          source_description: "field notes [lens: observations]",
          extraction_complete: true
        }
      ])

      assert {:ok, [%{episode: %{content: "A complete Lens observation."}}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "complete",
                 destinations: ["observations"],
                 max_results: 1
               })
    end
  end

  describe "when public episode search encounters historical episodes without a named writer" do
    test "then the episodes remain available without invented Lens or Reflection authorship" do
      graphiti = use_native_boundary()

      set_episode_search_fixture(graphiti, [
        %{content: "An older episode.", source_description: "legacy source"}
      ])

      assert {:ok, [%{episode: episode}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "episode",
                 destinations: ["observations"]
               })

      assert episode.content == "An older episode."
      assert episode.source_description == "legacy source"
      refute Map.has_key?(episode, :lens)
      refute Map.has_key?(episode, :reflection)
    end

    test "and historical fact sources retain their original source descriptions" do
      graphiti = use_native_boundary()

      set_search_fixture(graphiti, [
        %{
          fact: "Historical fact",
          episodes: [%{id: "old-one", source_kind: "text", source_description: "legacy source"}]
        }
      ])

      assert {:ok, [%{fact: %{sources: [source]}}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "Historical",
                 destinations: ["personal"],
                 result_type: :facts
               })

      assert source == %{
               id: "old-one",
               source_kind: "document",
               source_description: "legacy source"
             }
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

  describe "when public episode search reads completed Reflection output" do
    test "then the episode exposes the exact artefact identifier and structured payload with its Reflection source description" do
      graphiti = use_native_boundary()

      artefact = %{
        id: "reflection-one",
        payload: %{
          "generalisations" => [
            %{
              "content" => "small rollouts",
              "level" => 2,
              "evolves_from" => [%{"content" => "prior", "level" => 1}]
            }
          ]
        }
      }

      set_episode_search_fixture(graphiti, [
        %{content: Jason.encode!(artefact), source_description: "reflection:generalisations"}
      ])

      assert {:ok, [%{destination: "observations", episode: episode}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "rollout",
                 destinations: ["observations"]
               })

      assert episode == %{
               artefact: artefact,
               reflection: "generalisations",
               source_description: "reflection:generalisations"
             }
    end
  end

  describe "when public episode search reads completed Reflection output > if the stored Reflection body is not a valid artefact" do
    test "then search returns an explicit invalid artefact error" do
      graphiti = use_native_boundary()

      set_episode_search_fixture(graphiti, [
        %{content: ~s({"id":"broken"}), source_description: "reflection:generalisations"}
      ])

      assert {:error, {:invalid_reflection_artefact, "generalisations"}} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "rollout",
                 destinations: ["observations"]
               })
    end
  end

  describe "when public artefact search reads stored Reflection output" do
    test "then only records with a non-blank identifier and structured payload become canonical artefacts" do
      graphiti = use_native_boundary()
      valid = %{id: "valid", payload: %{"summary" => "retained"}}

      set_episode_search_fixture(
        graphiti,
        Enum.map(
          [
            valid,
            %{id: "scalar", payload: "not structured"},
            %{id: "null-payload", payload: nil},
            %{id: "", payload: %{}},
            %{id: "  ", payload: %{}},
            %{id: 42, payload: %{}}
          ],
          fn artefact ->
            %{content: Jason.encode!(artefact), source_description: "reflection:generalisations"}
          end
        )
      )

      assert {:ok, [%{destination: "observations", artefact: artefact}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "rollout",
                 destinations: ["observations"],
                 result_type: :artefacts
               })

      assert artefact == struct!(Gralkor.Artefact, valid)
    end
  end

  defp request(source_kind, content, source_description) do
    %Ingest{
      id: "provenance-#{System.unique_integer([:positive])}",
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
                self.episode_results = []
                self.episodes = {}
                self.driver = _Driver(self)

            async def add_episode(self, **kwargs):
                from graphiti_core.nodes import EpisodicNode
                self.added.append({
                    "body": kwargs.get("episode_body"),
                    "source": kwargs.get("source").value,
                    "source_description": kwargs.get("source_description"),
                    "writer": (EpisodicNode._gralkor_requested_uuid_guard.get() or {}).get("writer"),
                    "custom_extraction_instructions": kwargs.get("custom_extraction_instructions"),
                })

            async def search(self, query, num_results=10, search_filter=None):
                return self.facts[:num_results]

            async def search_(self, query, config=None, group_ids=None, search_filter=None):
                limit = config.limit if config is not None else len(self.episode_results)
                return _SearchResult(self.episode_results[:limit])

        class _SearchResult:
            def __init__(self, episodes):
                self.episodes = episodes

        class _StoredEpisode:
            def __init__(self, uuid, content, source_description, writer=None):
                self.uuid = uuid
                self.content = content
                self.source_description = source_description
                self._gralkor_writer = writer

        class _Edge:
            def __init__(self, fact, episodes):
                self.fact = fact
                self.episodes = episodes
                self.created_at = None
                self.valid_at = None
                self.invalid_at = None
                self.expired_at = None

        class _Episode:
            def __init__(self, uuid, source, source_description, writer=None):
                from graphiti_core.nodes import EpisodeType
                self.uuid = uuid
                self.source = EpisodeType(source)
                self.source_description = source_description
                self._gralkor_writer = writer

        class _GraphOperations:
            def __init__(self, graphiti):
                self.graphiti = graphiti

            async def episodic_node_get_by_uuids(self, cls, driver, uuids):
                return [self.graphiti.episodes[uuid] for uuid in uuids]

        class _Driver:
            def __init__(self, graphiti):
                self.graphiti = graphiti
                self.graph_operations_interface = _GraphOperations(graphiti)
                self._gralkor_completed_episode_uuids = set()

            @property
            def episodes(self):
                return {episode.uuid: episode for episode in self.graphiti.episode_results}

            @property
            def _gralkor_episode_count(self):
                return len(self.graphiti.episode_results)

        graphiti = _Graphiti()
        graphiti.Edge = _Edge
        graphiti.Episode = _Episode
        graphiti.StoredEpisode = _StoredEpisode
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
                  _dec(source.get('writer')),
              )
              g.episodes[episode.uuid] = episode
              episode_ids.append(episode.uuid)
          g.facts.append(g.Edge(_dec(item['fact']), episode_ids))
      """,
      %{"g" => graphiti, "facts" => facts}
    )
  end

  defp set_episode_search_fixture(graphiti, episodes) do
    Pythonx.eval(
      """
      def _dec(value):
          return value.decode('utf-8') if isinstance(value, (bytes, bytearray)) else value
      g.episode_results = [
          g.StoredEpisode(
              _dec(item.get('id', f'episode-{index}')),
              _dec(item['content']),
              _dec(item['source_description']),
              _dec(item.get('writer')),
          )
          for index, item in enumerate(episodes)
      ]
      g.driver._gralkor_completed_episode_uuids = {
          episode.uuid
          for episode, item in zip(g.episode_results, episodes)
          if item.get('extraction_complete', True)
      }
      """,
      %{"g" => graphiti, "episodes" => episodes}
    )
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
