defmodule Gralkor.MemoryAdventureJourneyTest do
  @moduledoc """
  One production-like memory adventure through the real PythonX, Graphiti, and
  embedded FalkorDB runtime.

  Reifies the `memory-adventure` Journey tree.
  """

  use ExUnit.Case, async: false

  alias Gralkor.Application, as: GralkorApplication
  alias Gralkor.CaptureBuffer
  alias Gralkor.Client
  alias Gralkor.Client.Native
  alias Gralkor.Graph
  alias Gralkor.GraphitiPool
  alias Gralkor.Ingest
  alias Gralkor.Message
  alias Gralkor.Artefact
  alias Gralkor.Replace
  alias Gralkor.Search
  alias JidoGralkor.Actions.MemoryAdd
  alias JidoGralkor.Actions.MemorySearch

  @moduletag :journey
  @moduletag timeout: 600_000

  @operator_one "memory_adventure_operator_one"
  @operator_two "memory_adventure_operator_two"
  @reflection_callback_timeout_ms 300_000

  defmodule JourneyOntology do
    use Gralkor.Ontology, entities: :open, relationships: :scoped

    entity Job, "A scheduled background job such as backup or vacuum." do
    end

    entity Deployment, "A software deployment governed by an operational policy." do
    end

    entity Checkpoint, "A checkpoint that a deployment must verify." do
    end

    entity System, "A software system participating in a dependency." do
    end

    from Job do
      overlaps(Job)
    end

    from Deployment do
      requires(Checkpoint)
    end

    from System do
      depends_on(System)
    end
  end

  defmodule JourneyRequestTransformer do
    @behaviour Jido.AI.Reasoning.ReAct.RequestTransformer

    @impl true
    def transform_request(_request, state, _config, _runtime_context) do
      overrides = %{model: Gralkor.Config.llm_model()}

      overrides =
        if state.iteration == 1 do
          JidoGralkor.ReAct.maybe_force_memory_search(overrides, state)
        else
          Map.put(overrides, :tools, %{})
        end

      {:ok, overrides}
    end
  end

  defmodule JourneyAgent do
    use Jido.AI.Agent,
      name: "memory_adventure_agent",
      default_plugins: %{__memory__: false},
      plugins: [
        {JidoGralkor.Plugin,
         %{
           agent_name: "Memory Adventure Agent",
           runtime_config: %{
             destinations: [%{name: "operations"}],
             lenses: [
               %{
                 name: "work-notes",
                 destination: "operator",
                 write: :append,
                 ontology: Gralkor.MemoryAdventureJourneyTest.JourneyOntology,
                 ingestion: Gralkor.Lens.Ingestion.Store
               },
               %{name: "systems", destination: "operator", write: :replace_graph},
               %{
                 name: "published",
                 destination: "global",
                 write: :append,
                 ontology: Gralkor.MemoryAdventureJourneyTest.JourneyOntology,
                 ingestion: Gralkor.Lens.Ingestion.Store
               }
             ],
             reflections: [
               %{
                 name: "published-policy-review",
                 outputs: [%{kind: :destination, destination: "global"}],
                 chain_of_thought: %{
                   steps: [
                     %{
                       label: "summarise-published-policy",
                       directions:
                         "Summarise the completed published-policy representation supplied to this Reflection as one concise operational statement.",
                       output: %{"summary" => "string"}
                     }
                   ]
                 }
               }
             ]
           }
         }}
      ],
      tools: [JidoGralkor.Actions.MemorySearch],
      max_iterations: 3,
      tool_timeout_ms: 90_000,
      stream_timeout_ms: 180_000,
      observability: %{redact_tool_args?: false},
      system_prompt: """
      Search long-term memory exactly once before answering, using a focused
      query without Destination or Lens selectors. Apply the relevant retrieved
      facts grouped under their Lens or Reflection source.
      Follow the requested answer format exactly.
      """,
      request_transformer: Gralkor.MemoryAdventureJourneyTest.JourneyRequestTransformer

    def on_before_cmd(agent, action) do
      super(%{agent | state: Map.put(agent.state, :user_name, "Eli")}, action)
    end
  end

  setup_all do
    keys = [
      :client,
      :destinations,
      :destination_storage,
      :lenses,
      :lens_storage,
      :recall_deadline_ms
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:jido_gralkor, &1)})
    previous_data_dir = System.get_env("GRALKOR_DATA_DIR")

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "gralkor_memory_adventure_#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}"
      )

    File.mkdir_p!(data_dir)
    System.put_env("GRALKOR_DATA_DIR", data_dir)

    Application.put_env(:jido_gralkor, :client, Native)
    Application.put_env(:jido_gralkor, :destination_storage, Gralkor.Destination.Storage.Graphiti)
    Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.Graphiti)
    Application.put_env(:jido_gralkor, :recall_deadline_ms, 90_000)

    Application.put_env(:jido_gralkor, :destinations, [[name: "operations"]])

    Application.put_env(:jido_gralkor, :lenses, [
      [
        name: "work-notes",
        destination: "operator",
        ontology: JourneyOntology,
        ingestion: Gralkor.Lens.Ingestion.Store
      ],
      [
        name: "systems",
        destination: "operator",
        write: :replace_graph
      ],
      [
        name: "published",
        destination: "global",
        ontology: JourneyOntology,
        ingestion: Gralkor.Lens.Ingestion.Store
      ]
    ])

    {:ok, _python} = start_supervised(Gralkor.Python)

    {:ok, _pool} =
      start_supervised(
        {GraphitiPool,
         [
           falkordb_spec: {:embedded, data_dir},
           llm_model: Gralkor.Config.llm_model(),
           embedder_model: Gralkor.Config.embedder_model(),
           warmup: false
         ]}
      )

    {:ok, _buffer} =
      start_supervised(
        {CaptureBuffer,
         [
           flush_callback: GralkorApplication.build_flush_callback({:embedded, data_dir}),
           lens_flush_callback: GralkorApplication.build_lens_flush_callback()
         ]}
      )

    {:ok, _jido} = start_supervised({Jido, name: Jido})

    {:ok, agent} =
      start_supervised(
        {Jido.AgentServer,
         [
           agent: JourneyAgent,
           id: @operator_one
         ]}
      )

    on_exit(fn ->
      File.rm_rf!(data_dir)

      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:jido_gralkor, key)
        {key, value} -> Application.put_env(:jido_gralkor, key, value)
      end)

      case previous_data_dir do
        nil -> System.delete_env("GRALKOR_DATA_DIR")
        value -> System.put_env("GRALKOR_DATA_DIR", value)
      end
    end)

    {:ok, adventure: run_adventure(agent)}
  end

  describe "when two operators use implicit memory, Lenses, asynchronously triggered Reflections, and shared-Destination replacement" do
    test "then ontology-free implicit operator memory remains recallable", %{adventure: adventure} do
      assert adventure.implicit_memory
    end

    test "and captured appending-Lens information remains searchable", %{adventure: adventure} do
      assert adventure.appended_information
    end

    test "and ERL writes a structured Learning artefact through its Destination output", %{
      adventure: adventure
    } do
      assert adventure.erl_learning
    end

    test "and the global graph is visible to both operators", %{adventure: adventure} do
      assert adventure.global_for_first_operator
      assert adventure.global_for_second_operator
    end

    test "and each operator's selector-free search returns that operator's operator-local memory",
         %{
           adventure: adventure
         } do
      assert adventure.first_operator_own_local_information
      assert adventure.second_operator_own_local_information
    end

    test "and each operator's selector-free search excludes the other operator's operator-local memory",
         %{
           adventure: adventure
         } do
      refute adventure.first_operator_other_local_information
      refute adventure.second_operator_other_local_information
    end

    test "and implicit-default memory uses the graph named `operator/<operator id>`", %{
      adventure: adventure
    } do
      assert adventure.implicit_default_operator_graph
    end

    test "and appending Lenses use that same graph", %{adventure: adventure} do
      assert adventure.appending_operator_graph
    end

    test "and replaceable Lenses use that same graph", %{adventure: adventure} do
      assert adventure.replaceable_operator_graph
    end

    test "and replacing one Lens's graph preserves information written by another Lens", %{
      adventure: adventure
    } do
      assert adventure.preserved_shared_information
    end

    test "and fresh retrieval returns the current replacement graph", %{adventure: adventure} do
      assert adventure.current_replacement
    end

    test "and fresh retrieval omits the superseded replacement graph", %{adventure: adventure} do
      refute adventure.superseded_replacement
    end
  end

  describe "when the Journey consumer triggers generalisation after successive ingestions containing related observations" do
    test "then the first resulting generalisation exposes non-blank content, an integer level, and a lineage list",
         %{adventure: adventure} do
      assert %{
               "content" => content,
               "level" => level,
               "evolves_from" => lineage
             } = adventure.first_generalisation

      assert is_binary(content) and content != ""
      assert is_integer(level)
      assert is_list(lineage)
    end

    test "and a later resulting generalisation exposes non-blank content, an integer level, and non-empty lineage",
         %{
           adventure: adventure
         } do
      assert %{
               "content" => content,
               "level" => level,
               "evolves_from" => [_ | _]
             } = adventure.later_generalisation

      assert is_binary(content) and content != ""
      assert is_integer(level)
    end

    test "and every later lineage snapshot exposes non-blank content and an integer level",
         %{adventure: adventure} do
      assert %{"evolves_from" => preceding_generalisations} =
               adventure.later_generalisation

      assert preceding_generalisations != []

      assert Enum.all?(preceding_generalisations, fn
               %{"content" => content, "level" => level} ->
                 is_binary(content) and content != "" and is_integer(level)

               _ ->
                 false
             end)
    end
  end

  describe "when distinct ingestions use Lenses backed by different Destinations" do
    test "then the `work-notes` input is searchable through the `operator` Destination", %{
      adventure: adventure
    } do
      assert adventure.work_notes_input_at_operator
    end

    test "and the `published` input is searchable through the `global` Destination", %{
      adventure: adventure
    } do
      assert adventure.published_input_at_global
    end

    test "and each consumer-supplied invocation identifier resolves a completed `generalisations` artefact",
         %{
           adventure: adventure
         } do
      assert %Artefact{id: work_notes_artefact_id} = adventure.work_notes_generalisation_artefact
      assert %Artefact{id: published_artefact_id} = adventure.published_generalisation_artefact

      assert work_notes_artefact_id ==
               Artefact.id_for(
                 @operator_one,
                 "journey-generalisation-level-one",
                 "generalisations"
               )

      assert published_artefact_id ==
               Artefact.id_for(@operator_one, "journey-published-policy", "generalisations")
    end
  end

  describe "when the Journey consumer triggers a consumer-defined Reflection with a Destination output" do
    test "then its artefact is searchable through its Destination", %{adventure: adventure} do
      assert %Artefact{id: artefact_id} = adventure.consumer_destination_artefact

      assert artefact_id ==
               Artefact.id_for(
                 @operator_one,
                 "journey-published-policy",
                 "published-policy-review"
               )
    end

    test "and its invocation callback eventually receives that exact artefact and successful delivery outcome",
         %{
           adventure: adventure
         } do
      assert adventure.consumer_returned_artefact == adventure.consumer_destination_artefact
      assert adventure.consumer_reflection_outcome == :delivered
    end
  end

  describe "when a fresh agent handles a request related to an evolved generalisation" do
    test "then one MemorySearch call is made without selectors", %{adventure: adventure} do
      assert adventure.memory_search_completion_count == 1
      assert adventure.memory_search_arguments[:destinations] in [nil, []]
      assert adventure.memory_search_arguments[:lenses] in [nil, []]
    end

    test "and every accessible registered Destination is searched", %{adventure: adventure} do
      searched = Enum.map(adventure.default_memory_search, & &1.destination)

      assert MapSet.new(searched) == MapSet.new(["operator", "global", "operations"])
    end

    test "and its results include relevant memory from the `operator`, `global`, and an application Destination",
         %{adventure: adventure} do
      assert has_originating_lens?(
               adventure.default_memory_search,
               "operator",
               "work-notes"
             )

      assert has_declaring_reflection?(
               adventure.default_memory_search,
               "global",
               "generalisations"
             )

      operations_results =
        Enum.filter(
          adventure.default_memory_search,
          &(&1.destination == "operations")
        )

      assert has_declaring_reflection?(operations_results, "operations", "generalisations")
    end

    test "and its results include relevant Lens-authored memory and relevant stored generalisations",
         %{adventure: adventure} do
      assert has_originating_lens?(
               adventure.default_memory_search,
               "operator",
               "work-notes"
             )

      assert has_declaring_reflection?(
               adventure.default_memory_search,
               "global",
               "generalisations"
             )

      assert has_declaring_reflection?(
               adventure.default_memory_search,
               "global",
               "generalisations"
             )
    end

    test "and its readable fact bullets are grouped under the named originating Lens or Reflection",
         %{adventure: adventure} do
      assert adventure.memory_search_text =~ "Lens: work-notes\n- "
      assert adventure.memory_search_text =~ "Reflection: generalisations\n- "
    end

    test "and the answer uses retrieved facts relevant to the requested migration",
         %{adventure: adventure} do
      recommendation = answer_field!(adventure.agent_answer, "RECOMMENDATION")
      assert Regex.match?(~r/\b(?:Payments|migration)\b/i, recommendation)
    end

    test "and the recommendation applies the retrieved reversible limited-scope lesson to the requested migration",
         %{adventure: adventure} do
      recommendation = answer_field!(adventure.agent_answer, "RECOMMENDATION")
      rationale = answer_field!(adventure.agent_answer, "RATIONALE")
      application = recommendation <> " " <> rationale

      assert Regex.match?(~r/\breversib\w*\b/i, application)

      assert Regex.match?(
               ~r/\b(?:limited[-\s]+scope|trial|pilot|canar(?:y|ies)|staged|phased|incremental|progressive)\b/i,
               application
             )

      assert Regex.match?(~r/\b(?:fault|fail|risk|impact)\w*\b/i, rationale)
    end
  end

  describe "when the agent searches with both Destination and Lens selectors" do
    test "then relevant memory whose Destination and originating Lens both match the selectors is returned",
         %{adventure: adventure} do
      assert adventure.selected_memory_search != [],
             inspect(adventure.post_selector_memory_search, limit: :infinity)

      assert Enum.all?(adventure.selected_memory_search, fn result ->
               has_originating_lens?([result], "operator", "work-notes")
             end)
    end

    test "and a selected Lens does not contribute its memory from an unselected Destination",
         %{adventure: adventure} do
      assert adventure.cross_product_memory_search == []

      assert has_originating_lens?(
               adventure.post_selector_memory_search,
               "global",
               "published"
             )
    end

    test "and a subsequent selector-free search returns relevant memory from a Destination omitted by the earlier Destination selector",
         %{adventure: adventure} do
      assert Enum.any?(
               adventure.post_selector_memory_search,
               &(&1.destination == "global")
             )
    end

    test "and that search returns relevant memory from a Lens omitted by the earlier Lens selector",
         %{adventure: adventure} do
      assert has_originating_lens?(
               adventure.post_selector_memory_search,
               "global",
               "published"
             )
    end
  end

  describe "when the Journey ingests conversation, document, and structured-record episodes" do
    test "then every retrieved conversation fact identifies every originating episode", %{
      adventure: adventure
    } do
      assert every_fact_has_episode_id?(adventure.conversation_facts),
             inspect(adventure.conversation_facts)
    end

    test "and every retrieved conversation fact identifies its conversation source kind", %{
      adventure: adventure
    } do
      assert every_fact_has_source_kind?(adventure.conversation_facts, "conversation"),
             inspect(adventure.conversation_facts)
    end

    test "and every retrieved conversation fact identifies its captured-turn source description",
         %{
           adventure: adventure
         } do
      assert every_fact_has_source_description?(adventure.conversation_facts, "captured"),
             inspect(adventure.conversation_facts)
    end

    test "and every retrieved document fact identifies every originating episode", %{
      adventure: adventure
    } do
      assert every_fact_has_episode_id?(adventure.document_facts),
             inspect(adventure.document_facts)
    end

    test "and every retrieved document fact identifies its document source kind", %{
      adventure: adventure
    } do
      assert every_fact_has_source_kind?(adventure.document_facts, "document"),
             inspect(adventure.document_facts)
    end

    test "and a retrieved document fact identifies its deployment-policy source description",
         %{
           adventure: adventure
         } do
      assert any_fact_has_source_description?(adventure.document_facts, "deployment policy"),
             inspect(adventure.document_facts)
    end

    test "and every retrieved structured-record fact identifies every originating episode", %{
      adventure: adventure
    } do
      assert every_fact_has_episode_id?(adventure.structured_record_facts),
             inspect(adventure.structured_record_facts)
    end

    test "and every retrieved structured-record fact identifies its structured-record source kind",
         %{
           adventure: adventure
         } do
      assert every_fact_has_source_kind?(adventure.structured_record_facts, "structured_record"),
             inspect(adventure.structured_record_facts)
    end

    test "and every retrieved structured-record fact identifies its dependency-registry source description",
         %{adventure: adventure} do
      assert every_fact_has_source_description?(
               adventure.structured_record_facts,
               "system dependency registry"
             ),
             inspect(adventure.structured_record_facts)
    end
  end

  defp run_adventure(agent) do
    implicit_fact =
      "The private deployment codename is Juniper and the launch city is Muscat."

    second_operator_fact =
      "The private incident codename is Kestrel and the review city is Quito."

    appended_fact =
      "The Backup job overlaps the Vacuum job at 02:00. Moving the Vacuum job to 04:00 prevents the Backup job from failing."

    global_fact =
      "The Atlas Deployment requires the Rollback Checkpoint and a reversible canary to expose configuration faults before the Atlas release."

    structured_fact = %{
      "source_system" => "Payments",
      "relationship" => "depends_on",
      "target_system" => "Ledger",
      "statement" => "Payments depends on Ledger for settlement records."
    }

    assert {:ok, %{result: "Ingesting."}} =
             MemoryAdd.run(
               %{
                 content: implicit_fact,
                 source_kind: :document,
                 source_description: "manual"
               },
               %{agent_id: @operator_one, gralkor_runtime: agent}
             )

    assert {:ok, %{result: "Ingesting."}} =
             MemoryAdd.run(
               %{
                 content: second_operator_fact,
                 source_kind: :document,
                 source_description: "manual"
               },
               %{agent_id: @operator_two, gralkor_runtime: agent}
             )

    {first_generalisation, later_generalisation, work_notes_generalisation_artefact} =
      evolve_global_generalisation(agent)

    assert %Artefact{} =
             destination_artefact_until(
               @operator_one,
               "operations",
               Artefact.id_for(
                 @operator_one,
                 "journey-generalisation-level-two",
                 "generalisations"
               )
             )

    IO.inspect(
      %{
        first: first_generalisation,
        later: later_generalisation,
        operator_facts:
          search(@operator_one, ["operator"], :facts, "reversible deployment migration trial"),
        global_facts:
          search(@operator_one, ["global"], :facts, "reversible deployment migration trial"),
        operations_facts:
          search(@operator_one, ["operations"], :facts, "reversible deployment migration trial")
      },
      label: "JOURNEY_FACT_DIAGNOSTIC",
      limit: :infinity
    )

    for group <- ["operator/#{@operator_one}", "global", "operations"] do
      graph = GraphitiPool.for(GraphitiPool, group)

      {raw, _} =
        Pythonx.eval(
          """
          import asyncio
          asyncio._gralkor_run(g.driver.execute_query('MATCH (n)-[e:RELATES_TO]->(m) RETURN n.name AS source, m.name AS target, e.fact AS fact, e.group_id AS group_id, e.episodes AS episodes'))[0]
          """,
          %{"g" => graph}
        )

      IO.inspect(Pythonx.decode(raw), label: "JOURNEY_GRAPH_#{group}", limit: :infinity)
    end

    agent_request = agent_request(agent)
    default_memory_search = agent_request.memory_search_results

    implicit_episodes =
      search_until(
        @operator_one,
        ["operator"],
        :episodes,
        "private deployment codename Juniper Muscat",
        &contains_episode?(&1, "juniper")
      )

    session_id = "memory_adventure_#{System.unique_integer([:positive])}"

    :ok =
      Client.capture(
        agent,
        session_id,
        @operator_one,
        "Susu",
        "Eli",
        [
          Message.new("user", "The nightly Backup job conflicts with the Vacuum job."),
          Message.new("behaviour", "thought: both jobs overlap at 02:00"),
          Message.new("assistant", appended_fact)
        ],
        "work-notes",
        []
      )

    :ok = Native.flush_and_await(session_id, 90_000)

    _erl_artefact =
      invoke_reflection!(
        agent,
        "erl",
        @operator_one,
        "journey-erl-learning",
        [
          %{
            id: "journey-erl-learning-representation",
            lens: "work-notes",
            content: appended_fact,
            result: :ok
          }
        ]
      )

    published_request = %Ingest{
      id: "journey-published-policy",
      operator_id: @operator_one,
      lens: "published",
      source_kind: :document,
      content: global_fact,
      source_description: "deployment policy"
    }

    assert {:ok, published_representations} =
             Client.ingest_with_representation(agent, published_request)

    published_generalisation_artefact =
      invoke_reflection!(
        agent,
        "generalisations",
        @operator_one,
        "journey-published-policy",
        published_representations
      )

    store_artefact!(
      published_generalisation_artefact,
      "generalisations",
      @operator_one,
      "operations"
    )

    consumer_reflection_result =
      invoke_reflection_result!(
        agent,
        "published-policy-review",
        @operator_one,
        "journey-published-policy",
        published_representations
      )

    consumer_artefact_id =
      Artefact.id_for(@operator_one, "journey-published-policy", "published-policy-review")

    consumer_destination_artefact =
      destination_artefact_until(
        @operator_one,
        "global",
        consumer_artefact_id
      )

    assert consumer_destination_artefact.id == consumer_artefact_id

    consumer_returned_artefact = consumer_reflection_result.artefact

    :ok =
      Client.ingest(agent, %Ingest{
        id: "journey-work-notes-registry",
        operator_id: @operator_one,
        lens: "work-notes",
        source_kind: :structured_record,
        content: structured_fact,
        source_description: "system dependency registry"
      })

    :ok = Client.replace(agent, replacement("Ledger", "old"))
    :ok = Client.replace(agent, replacement("Clearing", "current"))

    {:ok, implicit_memory} =
      Native.recall(
        Client.operator_graph_id(@operator_one),
        "Susu",
        "fresh_recall_#{System.unique_integer([:positive])}",
        "What is the private deployment codename and launch city?"
      )

    shared_episodes =
      search_until(
        @operator_one,
        ["operator"],
        :episodes,
        "backup vacuum 02:00 04:00",
        &(&1 != [])
      )

    global_for_first =
      search_until(
        @operator_one,
        ["global"],
        :episodes,
        "Atlas Deployment requires Rollback Checkpoint",
        &(&1 != [])
      )

    global_for_second =
      search_until(
        @operator_two,
        ["global"],
        :episodes,
        "Atlas Deployment requires Rollback Checkpoint",
        &(&1 != [])
      )

    selector_query = "reversible canary configuration faults deployments"

    cross_product_memory_search =
      memory_search(agent, @operator_one, %{
        query: selector_query,
        destinations: ["operator"],
        lenses: ["published"]
      })

    selected_memory_search =
      memory_search(agent, @operator_one, %{
        query: selector_query,
        destinations: ["operator"],
        lenses: ["work-notes"]
      })

    post_selector_memory_search =
      memory_search(agent, @operator_one, %{query: selector_query})

    work_notes_input =
      search_until(
        @operator_one,
        ["operator"],
        :episodes,
        "Aurora reversible canary deployment",
        &contains_episode?(&1, "aurora")
      )

    private_memory_query = "private codename Juniper Muscat Kestrel Quito"

    private_for_first =
      search_until(
        @operator_one,
        [],
        :episodes,
        private_memory_query,
        &contains_episode?(&1, "juniper")
      )

    private_for_second =
      search_until(
        @operator_two,
        [],
        :episodes,
        private_memory_query,
        &contains_episode?(&1, "kestrel")
      )

    erl_artefacts =
      search_until(
        @operator_one,
        ["operator"],
        :artefacts,
        "backup vacuum scheduling conflict",
        &(&1 != []),
        120
      )

    current_graph =
      search_until(
        @operator_one,
        ["operator"],
        :facts,
        "settlement clearing",
        &contains_fact?(&1, "Clearing")
      )

    superseded_graph = search(@operator_one, ["operator"], :facts, "settlement ledger")

    conversation_facts =
      attributed_facts(
        @operator_one,
        "operator",
        "backup vacuum overlap",
        &(String.contains?(&1.fact.fact, "Susu") or String.contains?(&1.fact.fact, "Eli")),
        "conversation",
        "captured"
      )

    document_facts =
      search_until(
        @operator_two,
        ["global"],
        :facts,
        "Atlas Deployment requires Rollback Checkpoint",
        fn facts ->
          selected =
            Enum.filter(facts, &String.contains?(&1.fact.fact, "Rollback Checkpoint"))

          every_fact_has_episode_id?(selected) and
            every_fact_has_source_kind?(selected, "document") and
            any_fact_has_source_description?(selected, "deployment policy")
        end
      )
      |> Enum.filter(&String.contains?(&1.fact.fact, "Rollback Checkpoint"))

    structured_record_facts =
      attributed_facts(
        @operator_one,
        "operator",
        "payments ledger dependency",
        &String.contains?(&1.fact.fact, "depends on Ledger"),
        "structured_record",
        "system dependency registry"
      )

    %{
      implicit_memory: contains_all?(implicit_memory, ["juniper", "muscat"]),
      appended_information: contains_episode?(shared_episodes, "backup"),
      erl_learning: learning_artefact?(erl_artefacts),
      global_for_first_operator: contains_episode?(global_for_first, "rollback"),
      global_for_second_operator: contains_episode?(global_for_second, "rollback"),
      first_operator_own_local_information: contains_episode?(private_for_first, "juniper"),
      second_operator_own_local_information: contains_episode?(private_for_second, "kestrel"),
      first_operator_other_local_information: contains_episode?(private_for_first, "kestrel"),
      second_operator_other_local_information: contains_episode?(private_for_second, "juniper"),
      implicit_default_operator_graph: contains_episode?(implicit_episodes, "juniper"),
      appending_operator_graph: contains_episode?(shared_episodes, "backup"),
      replaceable_operator_graph: contains_fact?(current_graph, "Clearing"),
      preserved_shared_information: contains_episode?(shared_episodes, "vacuum"),
      current_replacement: contains_fact?(current_graph, "Payments settles through Clearing."),
      superseded_replacement:
        contains_fact?(superseded_graph, "Payments settles through Ledger."),
      first_generalisation: first_generalisation,
      later_generalisation: later_generalisation,
      work_notes_input_at_operator: contains_episode?(work_notes_input, "aurora"),
      published_input_at_global: contains_episode?(global_for_first, "rollback"),
      work_notes_generalisation_artefact: work_notes_generalisation_artefact,
      published_generalisation_artefact: published_generalisation_artefact,
      consumer_destination_artefact: consumer_destination_artefact,
      consumer_returned_artefact: consumer_returned_artefact,
      consumer_reflection_outcome: consumer_reflection_result.outcome,
      default_memory_search: default_memory_search,
      memory_search_text: agent_request.memory_search_text,
      memory_search_arguments: agent_request.memory_search_arguments,
      memory_search_completion_count: agent_request.memory_search_completion_count,
      agent_answer: agent_request.answer,
      selected_memory_search: selected_memory_search,
      cross_product_memory_search: cross_product_memory_search,
      post_selector_memory_search: post_selector_memory_search,
      conversation_facts: conversation_facts,
      document_facts: document_facts,
      structured_record_facts: structured_record_facts
    }
  end

  defp evolve_global_generalisation(agent) do
    first_ingestion_id = "journey-generalisation-level-one"

    first_report = """
    The Payments Deployment requires the Rollback Checkpoint before release.
    Aurora's incident review found that the Rollback Checkpoint caught a Payments
    configuration fault in a reversible limited-scope canary before customers
    were affected. Payments deployments therefore require the Rollback Checkpoint:
    begin with a reversible limited-scope trial and check for faults before broad
    rollout. This is the observed Payments deployment policy.
    """

    assert {:ok, first_representations} =
             Client.ingest_with_representation(agent, %Ingest{
               id: first_ingestion_id,
               operator_id: @operator_one,
               lens: "work-notes",
               source_kind: :document,
               content: first_report,
               source_description: "Aurora canary deployment review"
             })

    first_generalisation_artefact =
      invoke_reflection!(
        agent,
        "generalisations",
        @operator_one,
        first_ingestion_id,
        first_representations
      )

    store_artefact!(
      first_generalisation_artefact,
      "generalisations",
      @operator_one,
      "operations"
    )

    first_generalisation =
      first_generalisation_artefact
      |> find_generalisation(fn generalisation ->
        is_binary(generalisation["content"]) and generalisation["content"] != "" and
          is_integer(generalisation["level"]) and is_list(generalisation["evolves_from"])
      end)

    assert %{"content" => first_content} = first_generalisation
    assert is_binary(first_content) and first_content != ""

    later_ingestion_id = "journey-generalisation-level-two"

    later_report = """
    A later operational review extends this preceding stored generalisation:
    #{first_content}

    The same Payments policy now extends beyond deployments. The Payments Database
    Migration and Payments Feature Release also require the Rollback Checkpoint.
    Both avoided customer-impacting failures by starting with reversible limited-scope
    trials at that checkpoint. The observed policy now applies to Payments deployments,
    database migrations, and feature releases: each requires the Rollback Checkpoint
    to expose faults in a reversible limited-scope trial before broad impact.
    """

    assert first_generalisation_artefact ==
             destination_artefact_until(
               @operator_one,
               "operations",
               first_generalisation_artefact.id
             )

    assert {:ok, later_representations} =
             Client.ingest_with_representation(agent, %Ingest{
               id: later_ingestion_id,
               operator_id: @operator_one,
               lens: "work-notes",
               source_kind: :document,
               content: later_report,
               source_description: "cross-domain reversible change review"
             })

    later_generalisation_artefact =
      invoke_reflection!(
        agent,
        "generalisations",
        @operator_one,
        later_ingestion_id,
        later_representations
      )

    store_artefact!(
      later_generalisation_artefact,
      "generalisations",
      @operator_one,
      "operations"
    )

    later_generalisation =
      find_generalisation(later_generalisation_artefact, fn generalisation ->
        is_binary(generalisation["content"]) and generalisation["content"] != "" and
          is_integer(generalisation["level"]) and
          match?([_ | _], generalisation["evolves_from"])
      end)

    {first_generalisation, later_generalisation, first_generalisation_artefact}
  end

  defp invoke_reflection!(
         agent,
         reflection_name,
         operator_id,
         invocation_id,
         representations
       ) do
    invoke_reflection_result!(
      agent,
      reflection_name,
      operator_id,
      invocation_id,
      representations
    ).artefact
  end

  defp invoke_reflection_result!(
         agent,
         reflection_name,
         operator_id,
         invocation_id,
         representations
       ) do
    test_pid = self()
    callback_ref = make_ref()

    invocation = %{
      id: invocation_id,
      operator_id: operator_id,
      invocation_context: %{},
      representations: representations
    }

    callback = fn result -> send(test_pid, {callback_ref, result}) end

    assert {:ok, ^invocation_id} =
             Client.reflect(agent, reflection_name, invocation, callback)

    receive do
      {^callback_ref,
       %{invocation_id: ^invocation_id, artefact: %Artefact{}, outcome: :delivered} = result} ->
        result
    after
      @reflection_callback_timeout_ms ->
        flunk("Reflection #{inspect(reflection_name)} did not deliver its callback")
    end
  end

  defp store_artefact!(artefact, reflection_name, operator_id, destination_name) do
    output = %{
      kind: :destination,
      destination: Gralkor.Destination.Registry.fetch!(destination_name),
      ontology: Gralkor.DefaultOntology
    }

    :ok =
      Gralkor.Destination.Storage.put_artefact(
        output,
        reflection_name,
        operator_id,
        artefact
      )
  end

  defp destination_artefact_until(operator_id, destination, artefact_id, attempts \\ 120)

  defp destination_artefact_until(_operator_id, _destination, _artefact_id, 0), do: nil

  defp destination_artefact_until(operator_id, destination, artefact_id, attempts) do
    assert {:ok, results} =
             Client.search(%Search{
               operator_id: operator_id,
               query: artefact_id,
               destinations: [destination],
               result_type: :artefacts,
               artefact_id: artefact_id,
               max_results: 1
             })

    case Enum.find(results, &match?(%{artefact: %{id: ^artefact_id}}, &1)) do
      %{artefact: artefact} ->
        artefact

      nil ->
        Process.sleep(1_000)
        destination_artefact_until(operator_id, destination, artefact_id, attempts - 1)
    end
  end

  defp find_generalisation(%{payload: %{"generalisations" => generalisations}}, predicate)
       when is_list(generalisations) do
    Enum.find(generalisations, predicate)
  end

  defp find_generalisation(_artefact, _predicate), do: nil

  defp replacement(target, suffix) do
    %Replace{
      operator_id: @operator_one,
      lens: "systems",
      graph: %Graph{
        nodes: [
          replacement_entity("payments-#{suffix}", "Payments"),
          replacement_entity("target-#{suffix}", target)
        ],
        relationships: [
          %{
            from: "payments-#{suffix}",
            to: "target-#{suffix}",
            type: "RELATES_TO",
            properties: %{
              uuid: "memory-adventure-settlement-#{suffix}",
              group_id: "operator/#{@operator_one}",
              name: "SETTLES_THROUGH",
              fact: "Payments settles through #{target}.",
              episodes: [],
              created_at: "2026-08-11T00:00:00Z"
            }
          }
        ]
      }
    }
  end

  defp replacement_entity(id, name) do
    %{
      id: id,
      labels: ["Entity"],
      properties: %{
        uuid: "memory-adventure-#{id}",
        group_id: "operator/#{@operator_one}",
        name: name,
        summary: name,
        created_at: "2026-08-11T00:00:00Z"
      }
    }
  end

  defp search(operator_id, destinations, result_type, query) do
    assert {:ok, results} =
             Client.search(%Search{
               operator_id: operator_id,
               query: query,
               destinations: destinations,
               result_type: result_type,
               max_results: 20
             })

    results
  end

  defp memory_search(agent, operator_id, params) do
    assert {:ok, %{result: result}} =
             MemorySearch.run(params, %{agent_id: operator_id, gralkor_runtime: agent})

    assert is_binary(result)
    facts_matching_text(agent, operator_id, params, result)
  end

  defp agent_request(agent) do
    prompt = """
    A Payments database migration needs a rollout recommendation.
    Search related memory first. Base the recommendation on the most relevant
    facts grouped by Lens and Reflection source; do not rely on generic rollout advice alone.

    Answer with exactly these fields:
    RECOMMENDATION: <the rollout approach>
    RATIONALE: <how the retrieved facts support the recommendation>
    """

    assert {:ok, %{request: request, events: event_stream}} =
             JourneyAgent.ask_stream(agent, prompt,
               stream_event_timeout_ms: 180_000,
               tool_heartbeat_ms: 5_000
             )

    events = Enum.to_list(event_stream)
    assert {:ok, answer} = JourneyAgent.await(request, timeout: 180_000)

    memory_search_started =
      Enum.filter(events, &match?(%{kind: :tool_started, tool_name: "memory_search"}, &1))

    memory_search_completed =
      Enum.filter(events, &match?(%{kind: :tool_completed, tool_name: "memory_search"}, &1))

    assert [%{data: %{arguments: arguments}}] = memory_search_started
    assert [completed] = memory_search_completed

    text = decode_memory_search_result(completed)

    params = %{
      query: Map.get(arguments, :query, Map.get(arguments, "query")),
      destinations: Map.get(arguments, :destinations, Map.get(arguments, "destinations", [])),
      lenses: Map.get(arguments, :lenses, Map.get(arguments, "lenses", []))
    }

    results = facts_matching_text(agent, @operator_one, params, text)

    %{
      answer: answer,
      memory_search_arguments: %{
        destinations: Map.get(arguments, :destinations, Map.get(arguments, "destinations")),
        lenses: Map.get(arguments, :lenses, Map.get(arguments, "lenses"))
      },
      memory_search_completion_count: length(memory_search_completed),
      memory_search_results: results,
      memory_search_text: text
    }
  end

  defp decode_memory_search_result(%{
         data: %{result: {:ok, %{result: results}, _effects}}
       }) do
    assert is_binary(results)
    results
  end

  defp search_until(operator_id, destinations, result_type, query, predicate, attempts \\ 60)

  defp search_until(operator_id, destinations, result_type, query, predicate, attempts) do
    results = search(operator_id, destinations, result_type, query)

    cond do
      predicate.(results) ->
        results

      attempts <= 1 ->
        results

      true ->
        Process.sleep(1_000)
        search_until(operator_id, destinations, result_type, query, predicate, attempts - 1)
    end
  end

  defp contains_episode?(results, text) do
    sought = String.downcase(text)

    Enum.any?(results, fn %{episode: episode} ->
      episode
      |> episode_content()
      |> String.downcase()
      |> String.contains?(sought)
    end)
  end

  defp has_originating_lens?(results, destination, lens) do
    Enum.any?(results, fn %{destination: selected, fact: fact} ->
      selected == destination and
        Enum.any?(Map.get(fact, :sources, []), &(Map.get(&1, :lens) == lens))
    end)
  end

  defp has_declaring_reflection?(results, destination, reflection) do
    Enum.any?(results, fn %{destination: selected, fact: fact} ->
      selected == destination and
        Enum.any?(Map.get(fact, :sources, []), &(Map.get(&1, :reflection) == reflection))
    end)
  end

  defp facts_matching_text(agent, operator, params, text) do
    assert {:ok, facts} =
             Client.search(agent, %Search{
               operator_id: operator,
               query: params.query,
               destinations: Map.get(params, :destinations, []),
               lenses: Map.get(params, :lenses, []),
               result_type: :facts
             })

    assert {:ok, %{result: ^text}} = JidoGralkor.MemorySearchPresentation.for_model(facts, 65_536)
    facts
  end

  defp answer_field!(answer, label) do
    labels = "RECOMMENDATION|RATIONALE"

    pattern =
      Regex.compile!("(?ims)^#{Regex.escape(label)}:\\s*(.*?)(?=^(?:#{labels}):|\\z)")

    case Regex.run(pattern, answer, capture: :all_but_first) do
      [value] ->
        case String.trim(value) do
          "" -> flunk("expected #{label} to contain a value, got: #{inspect(answer)}")
          value -> value
        end

      _ ->
        flunk("expected answer field #{label}, got: #{inspect(answer)}")
    end
  end

  defp episode_content(%{artefact: artefact}), do: Jason.encode!(artefact.payload)
  defp episode_content(%{content: content}), do: content
  defp episode_content(%{"content" => content}), do: content
  defp episode_content(content) when is_binary(content), do: content

  defp contains_fact?(results, text) do
    Enum.any?(results, fn %{fact: fact} -> String.contains?(fact.fact, text) end)
  end

  defp attributed_facts(
         operator_id,
         destination,
         query,
         fact_from_episode?,
         source_kind,
         source_description,
         attempts \\ 10
       ) do
    facts =
      operator_id
      |> search([destination], :facts, query)
      |> Enum.filter(fact_from_episode?)

    cond do
      every_fact_attributed?(facts, source_kind, source_description) ->
        facts

      attempts <= 1 ->
        facts

      true ->
        Process.sleep(1_000)

        attributed_facts(
          operator_id,
          destination,
          query,
          fact_from_episode?,
          source_kind,
          source_description,
          attempts - 1
        )
    end
  end

  defp every_fact_attributed?([], _source_kind, _source_description), do: false

  defp every_fact_attributed?(results, source_kind, source_description) do
    every_fact_has_episode_id?(results) and
      every_fact_has_source_kind?(results, source_kind) and
      every_fact_has_source_description?(results, source_description)
  end

  defp every_fact_has_episode_id?([]), do: false

  defp every_fact_has_episode_id?(results) do
    Enum.all?(results, fn %{fact: fact} ->
      fact.sources != [] and Enum.all?(fact.sources, &is_binary(&1.id))
    end)
  end

  defp every_fact_has_source_kind?([], _source_kind), do: false

  defp every_fact_has_source_kind?(results, source_kind) do
    Enum.all?(results, fn %{fact: fact} ->
      Enum.any?(fact.sources, &(&1.source_kind == source_kind))
    end)
  end

  defp every_fact_has_source_description?([], _source_description), do: false

  defp every_fact_has_source_description?(results, source_description) do
    Enum.all?(results, fn %{fact: fact} ->
      Enum.any?(fact.sources, &String.contains?(&1.source_description, source_description))
    end)
  end

  defp any_fact_has_source_description?(results, source_description) do
    Enum.any?(results, fn %{fact: fact} ->
      Enum.any?(fact.sources, &String.contains?(&1.source_description, source_description))
    end)
  end

  defp contains_all?(text, expected) do
    text = String.downcase(text)
    Enum.all?(expected, &String.contains?(text, &1))
  end

  defp learning_artefact?(results) do
    Enum.any?(results, fn
      %{artefact: %{payload: payload}} ->
        is_binary(payload["problem_kind"]) and
          is_binary(payload["approach"]) and
          is_boolean(payload["success"]) and
          is_binary(payload["lesson"])

      _ ->
        false
    end)
  end
end
