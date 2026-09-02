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
  alias Gralkor.Reflection.Registry
  alias Gralkor.Replace
  alias Gralkor.Search
  alias JidoGralkor.Actions.MemoryAdd
  alias JidoGralkor.Actions.MemorySearch

  @moduletag :journey
  @moduletag timeout: 600_000

  @operator_one "memory_adventure_operator_one"
  @operator_two "memory_adventure_operator_two"

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
      tools: [JidoGralkor.Actions.MemorySearch],
      max_iterations: 3,
      tool_timeout_ms: 90_000,
      stream_timeout_ms: 180_000,
      observability: %{redact_tool_args?: false},
      system_prompt: """
      Search long-term memory exactly once before answering, using a focused
      query without Destination or Lens selectors. Apply the relevant evolved
      generalisation in light of its preceding history and related observations.
      Follow the requested answer format exactly.
      """,
      request_transformer: Gralkor.MemoryAdventureJourneyTest.JourneyRequestTransformer
  end

  defmodule JourneyReturnHandler do
    @behaviour Gralkor.Artefact.ReturnHandler

    use Agent

    def start_link(_opts), do: Agent.start_link(fn -> [] end, name: __MODULE__)

    def artefacts, do: Agent.get(__MODULE__, & &1)

    @impl true
    def return(_operator_id, _invocation_id, %Gralkor.Artefact{} = artefact) do
      Agent.update(__MODULE__, &[artefact | &1])
    end
  end

  setup_all do
    keys = [
      :client,
      :destinations,
      :destination_storage,
      :lenses,
      :lens_storage,
      :recall_deadline_ms,
      :reflections
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

    Application.put_env(:jido_gralkor, :destinations, [])

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
        write: :replace_graph,
        graph_format: :property_graph
      ],
      [
        name: "published",
        destination: "global",
        ontology: JourneyOntology,
        ingestion: Gralkor.Lens.Ingestion.Store
      ]
    ])

    packaged_reflections =
      Registry.load!(
        [
          [
            name: "generalisations",
            triggers: [{:lens_ingestion, :any}],
            chain_of_thought: "priv/reflections/generalisations.yaml",
            outputs: [
              [kind: :destination, destination: "global", ontology: Gralkor.DefaultOntology]
            ]
          ],
          [
            name: "erl",
            triggers: [{:lens_ingestion, :any}],
            chain_of_thought: "priv/reflections/erl.yaml",
            outputs: [
              [
                kind: :destination,
                destination: "operator",
                ontology: Gralkor.Reflection.ERLOntology
              ]
            ]
          ]
        ],
        root: Application.app_dir(:jido_gralkor)
      )

    consumer_reflections =
      Registry.load!(
        [
          [
            name: "published-policy-review",
            triggers: [{:lens_ingestion, ["published"]}],
            chain_of_thought: "test/journey/consumer_reflection.yaml",
            outputs: [
              [kind: :destination, destination: "global"],
              [kind: :return, handler: JourneyReturnHandler]
            ]
          ]
        ],
        root: File.cwd!()
      )

    Application.put_env(
      :jido_gralkor,
      :reflections,
      packaged_reflections ++ consumer_reflections
    )

    {:ok, _return_handler} = start_supervised(JourneyReturnHandler)

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

    {:ok, _reflection_supervisor} =
      start_supervised(
        {Gralkor.Reflection.Supervisor,
         scheduler_opts: [
           journal_path: Path.join(data_dir, "reflection_scheduler.dets")
         ]}
      )

    {:ok, _buffer} =
      start_supervised(
        {CaptureBuffer,
         [
           flush_callback: GralkorApplication.build_flush_callback({:embedded, data_dir}),
           lens_flush_callback: GralkorApplication.build_lens_flush_callback(),
           reflections: Registry.configured!()
         ]}
      )

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

  describe "when two operators use implicit memory, Lenses, ERL, and shared-Destination replacement" do
    test "then ontology-free implicit operator memory remains recallable", %{adventure: adventure} do
      assert adventure.implicit_memory
    end

    test "and captured appending-Lens information remains searchable", %{adventure: adventure} do
      assert adventure.appended_information
    end

    test "and ERL stores a structured Learning artefact", %{adventure: adventure} do
      assert adventure.erl_learning
    end

    test "and the global graph is visible to both operators", %{adventure: adventure} do
      assert adventure.global_for_first_operator
      assert adventure.global_for_second_operator
    end

    test "and one operator's operator graph is unavailable to another operator", %{
      adventure: adventure
    } do
      refute adventure.second_operator_local_information
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

  describe "when the Journey ingests related information through successive completed ingestions" do
    test "then the first resulting generalisation has evolution-depth level one and an empty `evolves_from`",
         %{adventure: adventure} do
      assert %{
               "content" => content,
               "level" => 1,
               "evolves_from" => []
             } = adventure.first_generalisation

      assert is_binary(content) and content != ""
    end

    test "and the later generalisation that evolves from the first has evolution-depth level two",
         %{
           adventure: adventure
         } do
      assert %{"level" => 2} = adventure.later_generalisation
    end

    test "and the later generalisation's `evolves_from` records the first generalisation's content and level",
         %{adventure: adventure} do
      assert %{"content" => first_content, "level" => 1} = adventure.first_generalisation

      assert %{"evolves_from" => preceding_generalisations} =
               adventure.later_generalisation

      assert %{"content" => first_content, "level" => 1} in preceding_generalisations
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

    test "and each stable ingestion identifier resolves a completed `generalisations` artefact",
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

  describe "when a completed ingestion triggers a consumer-defined Reflection with Destination and return outputs" do
    test "then its artefact is searchable through its Destination", %{adventure: adventure} do
      assert %Artefact{id: artefact_id} = adventure.consumer_destination_artefact

      assert artefact_id ==
               Artefact.id_for(
                 @operator_one,
                 "journey-published-policy",
                 "published-policy-review"
               )
    end

    test "and its consumer return handler receives that exact artefact", %{adventure: adventure} do
      assert adventure.consumer_returned_artefact == adventure.consumer_destination_artefact
    end
  end

  describe "when a fresh agent handles a request related to an evolved generalisation" do
    test "then one MemorySearch call is made without selectors", %{adventure: adventure} do
      assert adventure.memory_search_completion_count == 1
      assert adventure.memory_search_arguments[:destinations] in [nil, []]
      assert adventure.memory_search_arguments[:lenses] in [nil, []]
    end

    test "and every accessible registered Destination is searched", %{adventure: adventure} do
      searched = Enum.map(adventure.default_memory_search, & &1["destination"])

      assert MapSet.new(searched) == MapSet.new(["operator", "global"])
    end

    test "and its results include relevant lensed information and relevant stored generalisations",
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

      assert has_evolved_generalisation?(
               adventure.default_memory_search,
               adventure.later_generalisation
             )
    end

    test "and every result identifies its Destination and any originating Lens",
         %{adventure: adventure} do
      assert every_episode_has_provenance?(adventure.default_memory_search)
    end

    test "and the answer identifies the retrieved level-one deployment predecessor and level-two newly covered feature-release scope",
         %{adventure: adventure} do
      predecessor = answer_field!(adventure.agent_answer, "PREDECESSOR")
      evolved = answer_field!(adventure.agent_answer, "EVOLVED")

      assert Regex.match?(~r/\blevel\s*(?:1|one)\b/i, predecessor)
      assert Regex.match?(~r/\bdeploy\w*\b/i, predecessor)
      assert Regex.match?(~r/\blevel\s*(?:2|two)\b/i, evolved)
      assert Regex.match?(~r/\bfeatures?(?:[-\s]+(?:releases?|rollouts?))?\b/i, evolved)
    end

    test "and the recommendation applies their reversible limited-scope lesson to the requested migration",
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

  describe "when one search selects a Destination and Lens" do
    test "then results match the intersection", %{adventure: adventure} do
      assert adventure.selected_memory_search != []

      assert Enum.all?(adventure.selected_memory_search, fn result ->
               has_originating_lens?([result], "operator", "work-notes")
             end)
    end

    test "and later ingestion retains its Lens",
         %{adventure: adventure} do
      assert has_originating_lens?(
               adventure.post_selector_published_episodes,
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

    test "and every retrieved document fact identifies its deployment-policy source description",
         %{
           adventure: adventure
         } do
      assert every_fact_has_source_description?(adventure.document_facts, "deployment policy"),
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

    appended_fact =
      "The Backup job overlaps the Vacuum job at 02:00. Moving the Vacuum job to 04:00 prevents the Backup job from failing."

    global_fact =
      "The Atlas Deployment requires the Rollback Checkpoint before the Atlas release."

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
               %{agent_id: @operator_one}
             )

    {first_generalisation, later_generalisation, work_notes_generalisation_artefact} =
      evolve_global_generalisation()

    agent_request = agent_request(agent)
    default_memory_search = agent_request.memory_search_results

    selected_memory_search =
      memory_search(%{
        query: "reversible canary configuration faults deployments",
        destinations: ["operator"],
        lenses: ["work-notes"]
      })

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
      Native.capture(
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
        [],
        %{tools: [], tool_context: %{session_id: session_id}}
      )

    :ok = Native.flush_and_await(session_id, 90_000)

    :ok =
      Client.ingest(%Ingest{
        id: "journey-published-policy",
        operator_id: @operator_one,
        lens: "published",
        source_kind: :document,
        content: global_fact,
        source_description: "deployment policy"
      })

    consumer_artefact_id =
      Artefact.id_for(@operator_one, "journey-published-policy", "published-policy-review")

    consumer_destination_artefact =
      destination_artefact_until(@operator_one, "global", consumer_artefact_id)

    consumer_returned_artefact = return_artefact_until(consumer_artefact_id)

    published_generalisation_artefact =
      generalisation_artefact_until("journey-published-policy")

    :ok =
      Client.ingest(%Ingest{
        id: "journey-work-notes-registry",
        operator_id: @operator_one,
        lens: "work-notes",
        source_kind: :structured_record,
        content: structured_fact,
        source_description: "system dependency registry"
      })

    :ok = Client.replace(replacement("Ledger", "old"))
    :ok = Client.replace(replacement("Clearing", "current"))

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

    work_notes_input =
      search_until(
        @operator_one,
        ["operator"],
        :episodes,
        "Aurora Borealis Cygnus reversible canary",
        &contains_episode?(&1, "aurora")
      )

    local_for_second = search(@operator_two, ["operator"], :episodes, "backup vacuum")

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
        &(String.contains?(&1.fact, "Susu") or String.contains?(&1.fact, "Eli")),
        "conversation",
        "captured"
      )

    document_facts =
      attributed_facts(
        @operator_two,
        "global",
        "Atlas Deployment requires Rollback Checkpoint",
        &String.contains?(&1.fact, "Rollback Checkpoint"),
        "document",
        "deployment policy"
      )

    structured_record_facts =
      attributed_facts(
        @operator_one,
        "operator",
        "payments ledger dependency",
        &String.contains?(&1.fact, "depends on Ledger"),
        "structured_record",
        "system dependency registry"
      )

    %{
      implicit_memory: contains_all?(implicit_memory, ["juniper", "muscat"]),
      appended_information: contains_episode?(shared_episodes, "backup"),
      erl_learning: learning_artefact?(erl_artefacts),
      global_for_first_operator: contains_episode?(global_for_first, "rollback"),
      global_for_second_operator: contains_episode?(global_for_second, "rollback"),
      second_operator_local_information: contains_episode?(local_for_second, "backup"),
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
      default_memory_search: default_memory_search,
      memory_search_arguments: agent_request.memory_search_arguments,
      memory_search_completion_count: agent_request.memory_search_completion_count,
      agent_answer: agent_request.answer,
      selected_memory_search: selected_memory_search,
      post_selector_published_episodes: global_for_first,
      conversation_facts: conversation_facts,
      document_facts: document_facts,
      structured_record_facts: structured_record_facts
    }
  end

  defp evolve_global_generalisation do
    first_ingestion_id = "journey-generalisation-level-one"

    first_report = """
    Three independently operated services reached the same result. Aurora,
    Borealis, and Cygnus each detected configuration faults before customers
    were affected when a reversible canary ran before the full deployment.
    The cross-team review concluded that starting deployments with reversible
    canaries exposes configuration faults before broad customer impact.
    """

    :ok =
      Client.ingest(%Ingest{
        id: first_ingestion_id,
        operator_id: @operator_one,
        lens: "work-notes",
        source_kind: :document,
        content: first_report,
        source_description: "cross-team canary deployment review"
      })

    first_generalisation_artefact = generalisation_artefact_until(first_ingestion_id)

    first_generalisation =
      first_generalisation_artefact
      |> find_generalisation(fn generalisation ->
        generalisation["level"] == 1 and generalisation["evolves_from"] == []
      end)

    first_content =
      case first_generalisation do
        %{"content" => content} when is_binary(content) and content != "" -> content
        _ -> "Deployments that begin with reversible canaries expose faults before broad impact."
      end

    later_ingestion_id = "journey-generalisation-level-two"

    later_report = """
    A later operational review extends this preceding stored generalisation:
    #{first_content}

    The same result now recurs beyond deployments. Database migrations and
    feature releases also avoided customer-impacting failures when they began
    with reversible limited-scope trials. Across deployments, migrations, and
    feature releases, beginning a change with a reversible limited-scope trial
    exposes faults before broad impact.
    """

    :ok =
      Client.ingest(%Ingest{
        id: later_ingestion_id,
        operator_id: @operator_one,
        lens: "work-notes",
        source_kind: :document,
        content: later_report,
        source_description: "cross-domain reversible change review"
      })

    later_generalisation =
      later_ingestion_id
      |> generalisation_artefact_until()
      |> find_generalisation(fn generalisation ->
        generalisation["level"] == 2 and
          %{"content" => first_content, "level" => 1} in generalisation["evolves_from"]
      end)

    {first_generalisation, later_generalisation, first_generalisation_artefact}
  end

  defp generalisation_artefact_until(ingestion_id, attempts \\ 120) do
    artefact_id = Artefact.id_for(@operator_one, ingestion_id, "generalisations")
    generalisation_artefact_until(artefact_id, attempts, nil)
  end

  defp generalisation_artefact_until(_artefact_id, 0, last_results), do: last_results

  defp generalisation_artefact_until(artefact_id, attempts, _last_results) do
    assert {:ok, results} =
             Client.search(%Search{
               operator_id: @operator_one,
               query: artefact_id,
               destinations: ["global"],
               result_type: :artefacts,
               artefact_id: artefact_id,
               max_results: 1
             })

    case Enum.find(results, fn
           %{artefact: %{id: ^artefact_id}} -> true
           _ -> false
         end) do
      nil ->
        Process.sleep(1_000)
        generalisation_artefact_until(artefact_id, attempts - 1, results)

      %{artefact: artefact} ->
        artefact
    end
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

  defp return_artefact_until(artefact_id, attempts \\ 120)

  defp return_artefact_until(_artefact_id, 0), do: nil

  defp return_artefact_until(artefact_id, attempts) do
    case Enum.find(JourneyReturnHandler.artefacts(), &(&1.id == artefact_id)) do
      %Artefact{} = artefact ->
        artefact

      nil ->
        Process.sleep(1_000)
        return_artefact_until(artefact_id, attempts - 1)
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
        format: :property_graph,
        data: %{
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

  defp memory_search(params) do
    assert {:ok, %{result: result}} =
             MemorySearch.run(params, %{agent_id: @operator_one})

    decoded = Jason.decode!(result)
    assert is_list(decoded)
    decoded
  end

  defp agent_request(agent) do
    prompt = """
    A Payments database migration needs a rollout recommendation.
    Search related memory first. Base the recommendation on the most relevant
    evolved generalisation, its evolves_from history, and the related observations;
    do not rely on generic rollout advice alone.

    Answer with exactly these fields:
    RECOMMENDATION: <the rollout approach>
    PREDECESSOR: level <integer>; scope <the predecessor's scope>
    EVOLVED: level <integer>; newly covered scope <a scope other than this migration>
    RATIONALE: <how the observations and evolution history support the recommendation>
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

    results = decode_memory_search_result(completed)

    %{
      answer: answer,
      memory_search_arguments: %{
        destinations: Map.get(arguments, :destinations, Map.get(arguments, "destinations")),
        lenses: Map.get(arguments, :lenses, Map.get(arguments, "lenses"))
      },
      memory_search_completion_count: length(memory_search_completed),
      memory_search_results: results
    }
  end

  defp decode_memory_search_result(%{
         data: %{result: {:ok, %{result: encoded_results}, _effects}}
       }) do
    decoded = Jason.decode!(encoded_results)
    assert is_list(decoded)
    decoded
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
    Enum.any?(results, fn
      %{destination: ^destination, episode: %{lens: ^lens}} -> true
      %{"destination" => ^destination, "episode" => %{"lens" => ^lens}} -> true
      _ -> false
    end)
  end

  defp has_declaring_reflection?(results, destination, reflection) do
    Enum.any?(results, fn
      %{
        "destination" => ^destination,
        "episode" => %{"reflection" => ^reflection}
      } ->
        true

      _ ->
        false
    end)
  end

  defp has_evolved_generalisation?(results, %{
         "content" => expected_content,
         "level" => expected_level
       }) do
    Enum.any?(results, fn
      %{
        "episode" => %{
          "content" => content,
          "reflection" => "generalisations"
        }
      } ->
        case Jason.decode(content) do
          {:ok, %{"payload" => %{"generalisations" => generalisations}}}
          when is_list(generalisations) ->
            Enum.any?(generalisations, fn
              %{
                "content" => ^expected_content,
                "level" => ^expected_level,
                "evolves_from" => [_ | _]
              } ->
                true

              _ ->
                false
            end)

          _ ->
            false
        end

      _ ->
        false
    end)
  end

  defp has_evolved_generalisation?(_results, _generalisation), do: false

  defp answer_field!(answer, label) do
    labels = "RECOMMENDATION|PREDECESSOR|EVOLVED|RATIONALE"

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

  defp every_episode_has_provenance?([]), do: false

  defp every_episode_has_provenance?(results) do
    Enum.all?(results, fn
      %{"destination" => destination, "episode" => episode} when is_binary(destination) ->
        is_binary(episode["lens"]) or is_binary(episode["reflection"])

      _ ->
        false
    end)
  end

  defp episode_content(%{content: content}), do: content
  defp episode_content(%{"content" => content}), do: content
  defp episode_content(content) when is_binary(content), do: content

  defp contains_fact?(results, text) do
    Enum.any?(results, fn %{fact: fact} -> String.contains?(fact, text) end)
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
    Enum.all?(results, fn %{fact: fact} -> Regex.match?(~r/episode: [^)]+\)/, fact) end)
  end

  defp every_fact_has_source_kind?([], _source_kind), do: false

  defp every_fact_has_source_kind?(results, source_kind) do
    Enum.all?(results, fn %{fact: fact} ->
      String.contains?(fact, "source: #{source_kind} —")
    end)
  end

  defp every_fact_has_source_description?([], _source_description), do: false

  defp every_fact_has_source_description?(results, source_description) do
    Enum.all?(results, fn %{fact: fact} -> String.contains?(fact, source_description) end)
  end

  defp contains_all?(text, expected) do
    text = String.downcase(text)
    Enum.all?(expected, &String.contains?(text, &1))
  end

  defp contains_any?(text, expected) do
    Enum.any?(expected, &String.contains?(text, &1))
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
