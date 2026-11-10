defmodule JidoGralkor.LensAwareAgentMemoryFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  alias Gralkor.Client
  alias Gralkor.Client.InMemory
  alias Gralkor.Ingest
  alias JidoGralkor.Actions.MemoryAdd
  alias JidoGralkor.Actions.MemorySearch
  alias JidoGralkor.Plugin

  @plugin_jido JidoGralkor.LensAwareAgentMemoryFunctionalTest.PluginJido

  defmodule MemoryOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open

    entity Memory do
      field(:content, :string, required: true)
    end
  end

  defmodule StoreIngestion do
    @behaviour Gralkor.Lens.Ingestion

    @impl true
    def ingest(request, store) do
      Gralkor.Lens.Store.add(store, request.content, request.source_description)
    end
  end

  defmodule SourceFactFixture do
    @behaviour Gralkor.Destination.Storage
    def search(%{name: "observations"}, _, _, _opts),
      do: facts([%{fact: "observed fact", sources: [%{lens: "observations"}]}])

    def search(%{name: "personal"}, _, _, _opts),
      do:
        facts([
          %{fact: "direct fact", sources: [%{writer: :direct, source_kind: "conversation"}]}
        ])

    def search(%{name: "generalisations"}, _, _, _opts),
      do: facts([%{fact: "reflected fact", sources: [%{reflection: "generalisations"}]}])

    defp facts(facts), do: {:ok, %{facts: facts, nodes: [], episodes: []}}
  end

  setup do
    previous_client = Application.get_env(:jido_gralkor, :client)
    previous_destinations = Application.get_env(:jido_gralkor, :destinations)
    previous_destination_storage = Application.get_env(:jido_gralkor, :destination_storage)
    previous_lenses = Application.get_env(:jido_gralkor, :lenses)
    previous_storage = Application.get_env(:jido_gralkor, :lens_storage)

    start_supervised!(Gralkor.Lens.Storage.InMemory)
    start_supervised!(Gralkor.Destination.Storage.InMemory)

    Application.put_env(:jido_gralkor, :client, InMemory)

    Application.put_env(:jido_gralkor, :destinations, [
      [name: "observations"],
      [name: "decisions"]
    ])

    Application.put_env(
      :jido_gralkor,
      :destination_storage,
      Gralkor.Destination.Storage.InMemory
    )

    Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)
    Application.delete_env(:jido_gralkor, :lenses)

    start_supervised!(
      {JidoGralkor.Runtime, owner: self(), configuration: runtime_configuration()}
    )

    start_supervised!({Registry, keys: :unique, name: Jido.registry_name(@plugin_jido)})
    {:ok, _owner} = Registry.register(Jido.registry_name(@plugin_jido), "operator-one", %{})

    InMemory.reset()

    on_exit(fn ->
      restore_env(:client, previous_client)
      restore_env(:destinations, previous_destinations)
      restore_env(:destination_storage, previous_destination_storage)
      restore_env(:lenses, previous_lenses)
      restore_env(:lens_storage, previous_storage)
    end)

    :ok
  end

  describe "when an agent with a mounted memory plugin invokes memory search" do
    test "then the tool context identifies that consuming agent's Gralkor runtime" do
      assert {:ok, plugin_state} =
               mount(agent_name: "Susu", ingestion_lens: "observations")

      assert {:ok, {:continue, %{data: %{tool_context: tool_context}}}} =
               plugin_state |> agent() |> query()

      assert tool_context.gralkor_runtime == self()
    end

    test "and directly written conversation facts identify their conversation origin" do
      Application.put_env(:jido_gralkor, :destination_storage, SourceFactFixture)

      assert {:ok, %{result: "Source: direct conversation\n- direct fact"}} =
               search_text(%{query: "direct", destinations: ["personal"]}, %{
                 agent_id: "operator-one",
                 gralkor_runtime: self()
               })
    end

    test "and the optional Destination selector belongs only to that search invocation" do
      for {lens, content} <- [
            {"observations", "selected observation memory"},
            {"decisions", "selected decision memory"}
          ] do
        assert :ok =
                 Client.ingest(self(), %Ingest{
                   id: "search-selector-#{lens}",
                   operator_id: "operator-one",
                   lens: lens,
                   source_kind: :document,
                   content: content,
                   source_description: "functional"
                 })
      end

      assert {:ok, plugin_state} =
               mount(agent_name: "Susu", ingestion_lens: "observations")

      mounted_agent = agent(plugin_state)
      assert {:ok, {:continue, %{data: %{tool_context: tool_context}}}} = query(mounted_agent)
      search_context = Map.put(tool_context, :agent_id, mounted_agent.id)

      assert {:ok, %{result: result}} =
               search_text(
                 %{query: "selected", destinations: ["decisions"]},
                 search_context
               )

      assert result ==
               "Lens: decisions\n- selected decision memory (source: functional)"

      assert {:ok, %{result: unselected}} =
               search_text(%{query: "selected"}, search_context)

      assert unselected =~ "Lens: observations\n- selected observation memory"

      assert search_context.lens == "observations"
    end

    test "and search selectors neither default from nor change the configured ingestion Lens" do
      assert {:ok, plugin_state} =
               mount(agent_name: "Susu", ingestion_lens: "observations")

      mounted_agent = agent(plugin_state)
      assert {:ok, {:continue, %{data: %{tool_context: tool_context}}}} = query(mounted_agent)
      memory_context = Map.put(tool_context, :agent_id, mounted_agent.id)

      assert {:ok, %{result: "Memory\nNo matching memory."}} =
               search_text(
                 %{query: "decision", destinations: ["decisions"]},
                 memory_context
               )

      assert {:ok, %{result: "Ingesting."}} =
               MemoryAdd.run(
                 %{
                   content: "observation retained after selected search",
                   source_kind: :document,
                   source_description: "functional"
                 },
                 memory_context
               )

      assert eventually(fn ->
               Enum.any?(destination_episodes("observations"), fn episode ->
                 episode.content == "observation retained after selected search"
               end)
             end)

      assert destination_episodes("decisions") == []
    end

    test "and a turn-selected ingestion Lens neither defaults nor restricts memory search" do
      assert :ok =
               Client.ingest(self(), %Ingest{
                 id: "turn-lens-independent-search",
                 operator_id: "operator-one",
                 lens: "observations",
                 source_kind: :document,
                 content: "observation visible from a decision turn",
                 source_description: "functional"
               })

      assert {:ok, plugin_state} =
               mount(agent_name: "Susu", ingestion_lens: "observations")

      mounted_agent = agent(plugin_state)

      assert {:ok, {:continue, %{data: %{tool_context: tool_context}}}} =
               query(mounted_agent, "decisions")

      assert tool_context.lens == "decisions"

      assert {:ok, %{result: result}} =
               search_text(
                 %{query: "observation", destinations: ["observations"]},
                 Map.put(tool_context, :agent_id, mounted_agent.id)
               )

      assert result ==
               "Lens: observations\n- observation visible from a decision turn (source: functional)"
    end

    test "and returned facts are grouped under their named originating Lens or Reflection" do
      Application.put_env(:jido_gralkor, :destination_storage, SourceFactFixture)

      assert {:ok, %{result: text}} =
               search_text(
                 %{query: "provenance", destinations: ["observations", "generalisations"]},
                 mounted_search_context()
               )

      assert text ==
               "Lens: observations\n- observed fact\n\nReflection: generalisations\n- reflected fact"
    end
  end

  describe "when an agent with a mounted memory plugin invokes memory search > where no conversation thread has been committed" do
    test "then memory search still runs for the current operator" do
      assert :ok =
               Client.ingest(self(), %Ingest{
                 id: "first-turn-search",
                 operator_id: "operator-one",
                 lens: "observations",
                 source_kind: :document,
                 content: "first-turn searchable memory",
                 source_description: "functional"
               })

      assert {:ok, plugin_state} =
               mount(agent_name: "Susu", ingestion_lens: "observations")

      fresh_agent = %{
        agent(plugin_state)
        | state: Map.delete(agent(plugin_state).state, :__thread__)
      }

      assert {:ok, {:continue, %{data: %{tool_context: tool_context}}}} = query(fresh_agent)
      refute Map.has_key?(tool_context, :session_id)

      assert {:ok, %{result: result}} =
               search_text(
                 %{query: "first-turn", destinations: ["observations"]},
                 Map.put(tool_context, :agent_id, fresh_agent.id)
               )

      assert result ==
               "Lens: observations\n- first-turn searchable memory (source: functional)"
    end
  end

  describe "when an agent with a mounted memory plugin invokes memory search > where the Destination selector is omitted or empty" do
    test "then memory search uses every accessible registered Destination" do
      for {lens, content} <- [
            {"personal-chat", "operator memory"},
            {"shared-generalisations", "global memory"},
            {"observations", "observation memory"},
            {"decisions", "decision memory"}
          ] do
        assert :ok =
                 Client.ingest(self(), %Ingest{
                   id: "default-all-#{lens}",
                   operator_id: "operator-one",
                   lens: lens,
                   source_kind: :document,
                   content: content,
                   source_description: "functional"
                 })
      end

      assert {:ok, %{result: result}} =
               search_text(%{query: "memory"}, mounted_search_context())

      assert result ==
               "Lens: personal-chat\n- operator memory (source: functional)\n\nLens: shared-generalisations\n- global memory (source: functional)\n\nLens: observations\n- observation memory (source: functional)\n\nLens: decisions\n- decision memory (source: functional)"
    end
  end

  describe "when a mounted memory plugin has an ingestion Lens declared by its consuming agent's runtime configuration" do
    test "then memory addition uses that runtime-owned Lens" do
      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "observations",
          destination: "decisions",
          ontology: MemoryOntology,
          ingestion: StoreIngestion
        ]
      ])

      assert {:ok, plugin_state} =
               mount(
                 agent_name: "Susu",
                 ingestion_lens: "observations"
               )

      agent = agent(plugin_state)
      assert {:ok, {:continue, %{data: %{tool_context: tool_context}}}} = query(agent)

      assert {:ok, %{result: "Ingesting."}} =
               MemoryAdd.run(
                 %{
                   content: "remembered observation",
                   source_kind: :conversation,
                   source_description: "agent"
                 },
                 Map.put(tool_context, :agent_id, agent.id)
               )

      assert eventually(fn ->
               destination_episodes("observations") != []
             end)

      assert destination_episodes("decisions") == []
    end

    test "and the plugin does not redefine the selected Lens's Destination or ingestion process" do
      assert {:ok, plugin_state} =
               mount(
                 agent_name: "Susu",
                 ingestion_lens: "observations"
               )

      assert plugin_state == %{
               agent_name: "Susu",
               ingestion_lens: "observations"
             }

      assert {:ok, {:continue, %{data: %{tool_context: tool_context}}}} =
               query(agent(plugin_state))

      assert tool_context.lens == "observations"
    end
  end

  describe "where an agent turn selects another registered Lens" do
    test "then memory addition uses the turn-selected Lens" do
      assert {:ok, plugin_state} =
               mount(
                 agent_name: "Susu",
                 ingestion_lens: "observations"
               )

      agent = agent(plugin_state)

      assert {:ok, {:continue, %{data: %{tool_context: tool_context}}}} =
               query(agent, "decisions")

      assert {:ok, %{result: "Ingesting."}} =
               MemoryAdd.run(
                 %{
                   content: "Friday decision",
                   source_kind: :conversation,
                   source_description: "agent"
                 },
                 Map.put(tool_context, :agent_id, agent.id)
               )

      assert eventually(fn ->
               destination_episodes("decisions") != []
             end)
    end
  end

  describe "if an agent turn selects an unknown or non-binary Lens" do
    test "then handling the turn fails before memory addition" do
      assert {:ok, plugin_state} =
               mount(agent_name: "Susu", ingestion_lens: "observations")

      for invalid <- ["missing", 42] do
        signal = %Jido.Signal{
          id: "invalid-lens",
          source: "/functional",
          type: "ai.react.query",
          data: %{query: "Remember this", tool_context: %{lens: invalid}}
        }

        assert_raise ArgumentError, ~r/unknown.*lenses|unknown Lens|invalid Lens/, fn ->
          Plugin.handle_signal(signal, %{
            jido_instance: @plugin_jido,
            partition: nil,
            agent: agent(plugin_state)
          })
        end
      end

      assert InMemory.adds() == []
    end

    test "and the invalid Lens is identified" do
      assert {:ok, plugin_state} =
               mount(agent_name: "Susu", ingestion_lens: "observations")

      for invalid <- ["missing", 42] do
        signal = %Jido.Signal{
          id: "invalid-lens",
          source: "/functional",
          type: "ai.react.query",
          data: %{query: "Remember this", tool_context: %{lens: invalid}}
        }

        error =
          assert_raise ArgumentError, fn ->
            Plugin.handle_signal(signal, %{
              jido_instance: @plugin_jido,
              partition: nil,
              agent: agent(plugin_state)
            })
          end

        assert Exception.message(error) =~ inspect(invalid)
      end
    end
  end

  describe "if a mounted plugin receives invalid ingestion Lens configuration" do
    test "then mounting fails before the plugin handles an agent signal" do
      assert_raise ArgumentError, fn ->
        mount(agent_name: "Susu", ingestion_lens: "missing")
      end
    end

    test "and an unknown ingestion Lens is identified" do
      assert_raise ArgumentError, ~r/unknown Lens "missing"/, fn ->
        mount(agent_name: "Susu", ingestion_lens: "missing")
      end
    end

    test "and the removed `:default_lens` option identifies `:ingestion_lens` as its replacement" do
      assert_raise ArgumentError, ~r/default_lens.*ingestion_lens/, fn ->
        mount(agent_name: "Susu", default_lens: "observations")
      end
    end
  end

  describe "if a mounted plugin receives the removed `:search_destinations` option" do
    test "then mounting fails before the plugin handles an agent signal" do
      assert_raise ArgumentError, ~r/search_destinations.*MemorySearch.*destinations/s, fn ->
        mount(
          agent_name: "Susu",
          ingestion_lens: "observations",
          search_destinations: ["observations"]
        )
      end
    end

    test "and the error identifies MemorySearch's per-search `destinations` selector as its replacement" do
      assert_raise ArgumentError, ~r/search_destinations.*MemorySearch.*destinations/s, fn ->
        mount(
          agent_name: "Susu",
          ingestion_lens: "observations",
          search_destinations: ["observations"]
        )
      end
    end
  end

  defp mounted_search_context do
    assert {:ok, plugin_state} = mount(agent_name: "Susu", ingestion_lens: "observations")
    mounted_agent = agent(plugin_state)
    assert {:ok, {:continue, %{data: %{tool_context: tool_context}}}} = query(mounted_agent)
    assert tool_context.gralkor_runtime == self()
    Map.put(tool_context, :agent_id, mounted_agent.id)
  end

  defp agent(plugin_state) do
    %{
      id: "operator-one",
      state: %{
        __memory__: plugin_state,
        __thread__: %{id: "session-one"}
      }
    }
  end

  defp mount(opts) do
    Plugin.mount(
      %{},
      Keyword.put_new(opts, :runtime_config, runtime_configuration())
    )
  end

  defp runtime_configuration do
    %{
      destinations: [
        %{name: "observations"},
        %{name: "decisions"},
        %{name: "generalisations"}
      ],
      lenses: [
        %{
          name: "observations",
          destination: "observations",
          ontology: MemoryOntology,
          ingestion: StoreIngestion
        },
        %{
          name: "decisions",
          destination: "decisions",
          ontology: MemoryOntology,
          ingestion: StoreIngestion
        },
        %{
          name: "shared-generalisations",
          destination: "global",
          ontology: Gralkor.DefaultOntology,
          ingestion: StoreIngestion
        }
      ],
      reflections: []
    }
  end

  defp query(agent, lens \\ nil, request_id \\ "query-request") do
    tool_context = if lens, do: %{lens: lens}, else: %{}

    signal = %Jido.Signal{
      id: "query-signal-#{request_id}",
      source: "/functional",
      type: "ai.react.query",
      data: %{
        request_id: request_id,
        query: "Remember this",
        tool_context: tool_context
      }
    }

    Plugin.handle_signal(signal, %{jido_instance: @plugin_jido, partition: nil, agent: agent})
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp destination_episodes(name) do
    name
    |> Gralkor.Destination.Registry.fetch!()
    |> Gralkor.Destination.graph_id("operator-one")
    |> Gralkor.Lens.Storage.InMemory.episodes()
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)

  defp search_text(params, context) do
    with {:ok, %{sections: sections}} <- MemorySearch.run(params, context),
         do: {:ok, %{result: JidoGralkor.MemorySearchPresentation.text(sections)}}
  end
end
