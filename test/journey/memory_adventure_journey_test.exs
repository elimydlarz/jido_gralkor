defmodule Gralkor.MemoryAdventureJourneyTest do
  @moduledoc """
  One production-like memory adventure through the real PythonX, Graphiti, and
  embedded FalkorDB runtime.

  Set `GRALKOR_JOURNEY_FALKORDB=host:port` to run the same adventure against a
  remote FalkorDB instead. Use an empty, disposable server: the adventure's
  graphs persist there after the run.

  Reifies the `memory-adventure` Journey tree.
  """

  use ExUnit.Case, async: false

  alias Gralkor.Client
  alias Gralkor.Client.Native
  alias Gralkor.Distill
  alias Gralkor.GraphitiPool
  alias Gralkor.Ingest
  alias Gralkor.Message
  alias Gralkor.Artefact
  alias Gralkor.Search
  alias JidoGralkor.Actions.MemoryAdd
  alias JidoGralkor.Actions.MemorySearch

  @moduletag :journey
  @moduletag timeout: 600_000

  @operator_one "memory_adventure_operator_one"
  @operator_two "memory_adventure_operator_two"
  @reflection_callback_timeout_ms 300_000
  @memory_only_checkpoint ~r/\bRollback\s+Checkpoints?\b/i

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
      {:ok,
       JidoGralkor.ReAct.maybe_force_memory_search(
         %{model: Gralkor.Config.llm_model()},
         state
       )}
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
                 destination: "personal",
                 ontology: Gralkor.MemoryAdventureJourneyTest.JourneyOntology,
                 ingestion: Gralkor.Lens.Ingestion.Store
               },
               %{
                 name: "runbooks",
                 destination: "operations",
                 ingestion: Gralkor.Lens.Ingestion.Store
               },
               %{
                 name: "published",
                 destination: "global",
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
      query without a Destination selector. Apply the relevant retrieved
      facts grouped under their Lens or Reflection source.
      Follow the requested answer format exactly.
      """,
      request_transformer: Gralkor.MemoryAdventureJourneyTest.JourneyRequestTransformer
  end

  setup_all do
    keys = [
      :client,
      :destination_storage,
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
    falkordb_spec = journey_falkordb_spec(data_dir)

    case falkordb_spec do
      {:embedded, _} -> System.put_env("GRALKOR_DATA_DIR", data_dir)
      {:remote, _} -> System.delete_env("GRALKOR_DATA_DIR")
    end

    Application.put_env(:jido_gralkor, :client, Native)
    Application.put_env(:jido_gralkor, :destination_storage, Gralkor.Destination.Storage.Graphiti)
    Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.Graphiti)
    Application.put_env(:jido_gralkor, :recall_deadline_ms, 90_000)

    {:ok, _python} =
      start_supervised({Gralkor.Python, [reap_orphans: match?({:embedded, _}, falkordb_spec)]})

    {:ok, _pool} =
      start_supervised(
        {GraphitiPool,
         [
           falkordb_spec: falkordb_spec,
           llm_model: Gralkor.Config.llm_model(),
           embedder_model: Gralkor.Config.embedder_model(),
           warmup: false
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

    adventure = run_adventure(agent)

    {:ok, adventure: adventure}
  end

  describe "when two operators use direct personal memory, Lenses, and asynchronously triggered Reflections" do
    test "then default-ontology direct personal memory remains recallable", %{
      adventure: adventure
    } do
      assert adventure.implicit_memory
    end

    test "and recall presents that memory in the memory search format inside an untrusted memory block",
         %{adventure: adventure} do
      assert adventure.recall_text =~
               ~r/\A<gralkor-memory trust="untrusted">\n(?:Lens|Reflection|Source): [^\n]+\n- /

      assert adventure.recall_text =~
               ~r/\n- [^\n]*Juniper[^\n]*\(valid from \d{4}-\d{2}-\d{2}; source: [^)\n]+\)\n/

      assert String.ends_with?(adventure.recall_text, "\n</gralkor-memory>")
    end

    test "and a direct conversation remains searchable without Lens or Reflection authorship",
         %{adventure: adventure} do
      assert [%{episode: episode}] = adventure.direct_conversation_episodes
      assert episode.writer == :direct
      assert episode.source_kind == "conversation"
      assert episode.source_description == "chat transcript"
      refute Map.has_key?(episode, :lens)
      refute Map.has_key?(episode, :reflection)
    end

    test "and personal-chat processing records its actual Lens provenance", %{
      adventure: adventure
    } do
      assert [%{episode: %{lens: "personal-chat", source_kind: "conversation"}}] =
               adventure.personal_chat_episodes
    end

    test "and the direct conversation and the personal-chat transcript each write one episode",
         %{adventure: adventure} do
      assert length(adventure.direct_conversation_episodes) == 1
      assert length(adventure.personal_chat_episodes) == 1
    end

    test "and appending-Lens transcript information remains searchable", %{adventure: adventure} do
      assert adventure.appended_information
    end

    test "and the global graph is visible to both operators", %{adventure: adventure} do
      assert adventure.global_for_first_operator
      assert adventure.global_for_second_operator
    end

    test "and each operator's selector-free search returns that operator's personal memory",
         %{
           adventure: adventure
         } do
      assert adventure.first_operator_own_local_information
      assert adventure.second_operator_own_local_information
    end

    test "and each operator's selector-free search excludes the other operator's personal memory",
         %{
           adventure: adventure
         } do
      refute adventure.first_operator_other_local_information
      refute adventure.second_operator_other_local_information
    end

    test "and direct memory uses the graph named `personal/<operator id>`", %{
      adventure: adventure
    } do
      assert adventure.implicit_default_operator_graph
    end

    test "and appending Lenses use that same graph", %{adventure: adventure} do
      assert adventure.appending_operator_graph
    end
  end

  describe "when distinct ingestions use Lenses backed by different Destinations" do
    test "then the `work-notes` input is searchable through the `personal` Destination", %{
      adventure: adventure
    } do
      assert adventure.work_notes_input_at_operator
    end

    test "and the `published` input is searchable through the `global` Destination", %{
      adventure: adventure
    } do
      assert adventure.published_input_at_global
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

  describe "when the Journey consumer triggers a consumer-defined Reflection with a Destination output > when the Journey consumer searches for memory created at or after the moment it triggered that Reflection" do
    test "then that Reflection's artefact is returned", context do
      assert_since_reflection_artefact(context)
    end

    test "and no directly written memory is returned", context do
      refute_since_reflection_direct_memory(context)
    end
  end

  describe "when a fresh agent handles a request related to stored deployment lessons" do
    test "then one MemorySearch call is made without selectors", %{adventure: adventure} do
      assert adventure.memory_search_completion_count == 1
      assert adventure.memory_search_arguments[:destinations] in [nil, []]
    end

    test "and every accessible registered Destination is searched", %{adventure: adventure} do
      assert MapSet.new(adventure.default_memory_search_destinations) ==
               MapSet.new(["personal", "global", "operations"])
    end

    test "and its results include relevant memory from the `personal`, `global`, and an application Destination",
         %{adventure: adventure} do
      assert has_originating_lens?(
               adventure.default_memory_search,
               "personal",
               "work-notes"
             )

      assert has_originating_lens?(adventure.default_memory_search, "global", "published")

      assert has_originating_lens?(
               adventure.default_memory_search,
               "operations",
               "runbooks"
             )
    end

    test "and its readable memory names the originating Lens",
         %{adventure: adventure} do
      assert adventure.memory_search_text =~ "Lens: work-notes\n- "
    end

    test "and the answer uses retrieved facts relevant to the requested migration",
         %{adventure: adventure} do
      recommendation = answer_field!(adventure.agent_answer, "RECOMMENDATION")
      rationale = answer_field!(adventure.agent_answer, "RATIONALE")

      assert Regex.match?(@memory_only_checkpoint, recommendation <> " " <> rationale)
    end

    test "and the recommendation applies the retrieved reversible limited-scope lesson to the requested migration",
         %{adventure: adventure} do
      recommendation = answer_field!(adventure.agent_answer, "RECOMMENDATION")
      rationale = answer_field!(adventure.agent_answer, "RATIONALE")
      application = recommendation <> " " <> rationale

      assert Regex.match?(@memory_only_checkpoint, recommendation)
      assert Regex.match?(~r/\breversib\w*\b/i, application)

      assert Regex.match?(
               ~r/\b(?:limited[-\s]+scope|trial|pilot|canar(?:y|ies)|staged|phased|incremental|progressive)\b/i,
               application
             )

      assert Regex.match?(~r/\b(?:fault|fail|risk|impact)\w*\b/i, rationale)
    end
  end

  describe "when the agent searches with a Destination selector" do
    test "then relevant memory from the selected Destination is returned",
         %{adventure: adventure} do
      assert has_originating_lens?(adventure.selected_memory_search, "personal", "work-notes"),
             inspect(adventure.selected_memory_search, limit: :infinity)
    end

    test "and no memory from an unselected Destination is returned", %{adventure: adventure} do
      assert adventure.selected_memory_search != []
      assert Enum.all?(adventure.selected_memory_search, &(&1.destination == "personal"))
    end

    test "and a subsequent selector-free search returns relevant memory from a Destination omitted by the earlier Destination selector",
         %{adventure: adventure} do
      assert has_originating_lens?(
               adventure.post_selector_memory_search,
               "global",
               "published"
             )
    end
  end

  describe "when the Journey consumer searches including one Lens as a writer" do
    test "then only episodes written through that Lens are returned",
         %{adventure: adventure} do
      episodes = lens_episodes(adventure.work_notes_lens_search)

      assert episodes != []
      assert Enum.all?(episodes, &(Map.get(&1, :lens) == "work-notes"))
      assert Enum.any?(episodes, &(&1 |> episode_content() |> String.contains?("Vacuum")))
    end

    test "and no episode written directly, through another Lens, or by a Reflection is returned",
         %{adventure: adventure} do
      episodes = lens_episodes(adventure.work_notes_lens_search)

      refute Enum.any?(episodes, &(Map.get(&1, :writer) == :direct))
      refute Enum.any?(episodes, &Map.has_key?(&1, :artefact))
      refute Enum.any?(episodes, &(Map.get(&1, :lens) == "personal-chat"))

      for text <- ["Juniper", "Cedar", "Harbor"] do
        refute Enum.any?(episodes, &(&1 |> episode_content() |> String.contains?(text)))
      end
    end

    test "and a subsequent search including no writer returns the memory written directly or through the other Lenses",
         %{adventure: adventure} do
      episodes = lens_episodes(adventure.lens_free_search)

      assert Enum.any?(episodes, fn episode ->
               Map.get(episode, :writer) == :direct and
                 episode |> episode_content() |> String.contains?("Juniper")
             end)

      assert Enum.any?(episodes, fn episode ->
               Map.get(episode, :lens) == "personal-chat" and
                 episode |> episode_content() |> String.contains?("Harbor")
             end)
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

    test "and every retrieved conversation fact identifies its chat-transcript source description",
         %{
           adventure: adventure
         } do
      assert every_fact_has_source_description?(adventure.conversation_facts, "chat transcript"),
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

  defp journey_falkordb_spec(data_dir) do
    case System.get_env("GRALKOR_JOURNEY_FALKORDB") do
      value when value in [nil, ""] ->
        {:embedded, data_dir}

      value ->
        [host, port] = String.split(String.trim(value), ":", parts: 2)
        {:remote, [host: host, port: String.to_integer(port)]}
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

    operations_runbook =
      "The Payments Database Migration runbook assigns the Platform team as migration owner and schedules the cutover in the Sunday maintenance window."

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

    ingest_deployment_reviews(agent)

    implicit_episodes =
      search_until(
        agent,
        @operator_one,
        ["personal"],
        :episodes,
        "private deployment codename Juniper Muscat",
        &contains_episode?(&1, "juniper")
      )

    :ok =
      Native.memory_add(
        Client.personal_graph_id(@operator_one),
        transcript([
          Message.new(
            "user",
            "The private recovery codename is Cedar and the rehearsal city is Amman."
          )
        ]),
        "chat transcript",
        :conversation
      )

    :ok =
      Client.ingest(agent, %Ingest{
        id: "journey-personal-chat",
        operator_id: @operator_one,
        lens: "personal-chat",
        source_kind: :conversation,
        content:
          transcript([
            Message.new(
              "user",
              "The personal support channel is Harbor and its check-in day is Thursday."
            )
          ]),
        source_description: "chat transcript"
      })

    :ok =
      Client.ingest(agent, %Ingest{
        id: "journey-work-notes-chat",
        operator_id: @operator_one,
        lens: "work-notes",
        source_kind: :conversation,
        content:
          transcript([
            Message.new("user", "The nightly Backup job conflicts with the Vacuum job."),
            Message.new("behaviour", "thought: both jobs overlap at 02:00"),
            Message.new("assistant", appended_fact)
          ]),
        source_description: "chat transcript"
      })

    direct_conversation_episodes =
      search_until(
        agent,
        @operator_one,
        ["personal"],
        :episodes,
        "Cedar Amman",
        &contains_episode?(&1, "cedar")
      )
      |> Enum.filter(&contains_episode?([&1], "cedar"))

    personal_chat_episodes =
      search_until(
        agent,
        @operator_one,
        ["personal"],
        :episodes,
        "Harbor Thursday",
        &contains_episode?(&1, "harbor")
      )
      |> Enum.filter(&contains_episode?([&1], "harbor"))

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

    reflection_triggered_at = DateTime.utc_now()

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
        agent,
        @operator_one,
        "global",
        consumer_artefact_id
      )

    assert consumer_destination_artefact.id == consumer_artefact_id

    consumer_returned_artefact = consumer_reflection_result.artefact

    since_reflection_search =
      since_search_until(
        agent,
        reflection_triggered_at,
        "#{consumer_artefact_id} private deployment codename Juniper Muscat Kestrel Quito Cedar Amman",
        fn results ->
          Enum.any?(flatten(results, :artefacts), &(&1.artefact.id == consumer_artefact_id))
        end
      )

    :ok =
      Client.ingest(agent, %Ingest{
        id: "journey-work-notes-registry",
        operator_id: @operator_one,
        lens: "work-notes",
        source_kind: :structured_record,
        content: structured_fact,
        source_description: "system dependency registry"
      })

    :ok =
      Client.ingest(agent, %Ingest{
        id: "journey-operations-runbook",
        operator_id: @operator_one,
        lens: "runbooks",
        source_kind: :document,
        content: operations_runbook,
        source_description: "migration runbook"
      })

    agent_request = agent_request(agent)
    default_memory_search = agent_request.memory_search_results

    {:ok, implicit_memory} =
      Native.recall(
        Client.personal_graph_id(@operator_one),
        "Susu",
        "fresh_recall_#{System.unique_integer([:positive])}",
        "What is the private deployment codename and launch city?"
      )

    shared_episodes =
      search_until(
        agent,
        @operator_one,
        ["personal"],
        :episodes,
        "backup vacuum 02:00 04:00",
        &(&1 != [])
      )

    global_for_first =
      search_until(
        agent,
        @operator_one,
        ["global"],
        :episodes,
        "Atlas Deployment requires Rollback Checkpoint",
        &(&1 != [])
      )

    global_for_second =
      search_until(
        agent,
        @operator_two,
        ["global"],
        :episodes,
        "Atlas Deployment requires Rollback Checkpoint",
        &(&1 != [])
      )

    selector_query = "reversible canary configuration faults deployments"

    selected_memory_search =
      memory_search(agent, @operator_one, %{
        query: selector_query,
        destinations: ["personal"]
      })

    post_selector_memory_search =
      memory_search(agent, @operator_one, %{query: selector_query})

    work_notes_input =
      search_until(
        agent,
        @operator_one,
        ["personal"],
        :episodes,
        "Aurora reversible canary deployment",
        &contains_episode?(&1, "aurora")
      )

    private_memory_query = "private codename Juniper Muscat Kestrel Quito"

    private_for_first =
      search_until(
        agent,
        @operator_one,
        [],
        :episodes,
        private_memory_query,
        &contains_episode?(&1, "juniper")
      )

    private_for_second =
      search_until(
        agent,
        @operator_two,
        [],
        :episodes,
        private_memory_query,
        &contains_episode?(&1, "kestrel")
      )

    conversation_facts =
      attributed_facts(
        agent,
        @operator_one,
        "personal",
        "backup vacuum overlap",
        &(String.contains?(&1.fact.fact, "Susu") or String.contains?(&1.fact.fact, "Eli")),
        "conversation",
        "chat transcript"
      )

    document_facts =
      search_until(
        agent,
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
        agent,
        @operator_one,
        "personal",
        "payments ledger dependency",
        &String.contains?(&1.fact.fact, "depends on Ledger"),
        "structured_record",
        "system dependency registry"
      )

    lens_query = "Backup Vacuum 02:00 Juniper Muscat Cedar Amman Harbor Thursday"

    work_notes_lens_search =
      writer_search_until(agent, ["lens:work-notes"], lens_query, fn results ->
        results
        |> lens_episodes()
        |> Enum.any?(&(&1 |> episode_content() |> String.contains?("Vacuum")))
      end)

    lens_free_search =
      writer_search_until(agent, [], "Juniper Muscat Harbor Thursday", fn results ->
        episodes = lens_episodes(results)

        Enum.any?(episodes, &(&1 |> episode_content() |> String.contains?("Juniper"))) and
          Enum.any?(episodes, &(&1 |> episode_content() |> String.contains?("Harbor")))
      end)

    %{
      work_notes_lens_search: work_notes_lens_search,
      lens_free_search: lens_free_search,
      implicit_memory: contains_all?(implicit_memory, ["juniper", "muscat"]),
      recall_text: implicit_memory,
      direct_conversation_episodes: direct_conversation_episodes,
      personal_chat_episodes: personal_chat_episodes,
      appended_information: contains_episode?(shared_episodes, "backup"),
      global_for_first_operator: contains_episode?(global_for_first, "rollback"),
      global_for_second_operator: contains_episode?(global_for_second, "rollback"),
      first_operator_own_local_information: contains_episode?(private_for_first, "juniper"),
      second_operator_own_local_information: contains_episode?(private_for_second, "kestrel"),
      first_operator_other_local_information: contains_episode?(private_for_first, "kestrel"),
      second_operator_other_local_information: contains_episode?(private_for_second, "juniper"),
      implicit_default_operator_graph: contains_episode?(implicit_episodes, "juniper"),
      appending_operator_graph: contains_episode?(shared_episodes, "backup"),
      work_notes_input_at_operator: contains_episode?(work_notes_input, "aurora"),
      published_input_at_global: contains_episode?(global_for_first, "rollback"),
      consumer_destination_artefact: consumer_destination_artefact,
      consumer_returned_artefact: consumer_returned_artefact,
      consumer_reflection_outcome: consumer_reflection_result.outcome,
      since_reflection_search: since_reflection_search,
      default_memory_search: default_memory_search,
      default_memory_search_destinations: agent_request.memory_search_destinations,
      default_memory_search_artefacts: agent_request.memory_search_artefacts,
      memory_search_text: agent_request.memory_search_text,
      memory_search_arguments: agent_request.memory_search_arguments,
      memory_search_completion_count: agent_request.memory_search_completion_count,
      agent_answer: agent_request.answer,
      selected_memory_search: selected_memory_search,
      post_selector_memory_search: post_selector_memory_search,
      conversation_facts: conversation_facts,
      document_facts: document_facts,
      structured_record_facts: structured_record_facts
    }
  end

  defp ingest_deployment_reviews(agent) do
    first_report = """
    The Payments Deployment requires the Rollback Checkpoint before release.
    Aurora's incident review found that the Rollback Checkpoint caught a Payments
    configuration fault in a reversible limited-scope canary before customers
    were affected. Payments deployments therefore require the Rollback Checkpoint:
    begin with a reversible limited-scope trial and check for faults before broad
    rollout. This is the observed Payments deployment policy.
    """

    later_report = """
    A later operational review found that the same Payments policy extends beyond
    deployments. The Payments Database Migration and Payments Feature Release also
    require the Rollback Checkpoint. Both avoided customer-impacting failures by
    starting with reversible limited-scope trials at that checkpoint. The observed
    policy now applies to Payments deployments, database migrations, and feature
    releases: each requires the Rollback Checkpoint to expose faults in a
    reversible limited-scope trial before broad impact.
    """

    for {id, content, source_description} <- [
          {"journey-deployment-review", first_report, "Aurora canary deployment review"},
          {"journey-reversible-change-review", later_report,
           "cross-domain reversible change review"}
        ] do
      assert :ok =
               Client.ingest(agent, %Ingest{
                 id: id,
                 operator_id: @operator_one,
                 lens: "work-notes",
                 source_kind: :document,
                 content: content,
                 source_description: source_description
               })
    end

    :ok
  end

  defp invoke_reflection_result!(
         agent,
         reflection_name,
         operator_id,
         invocation_id,
         representations,
         opts \\ []
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
             Client.reflect(agent, reflection_name, invocation, callback, opts)

    receive do
      {^callback_ref,
       %{invocation_id: ^invocation_id, artefact: %Artefact{}, outcome: :delivered} = result} ->
        result
    after
      @reflection_callback_timeout_ms ->
        flunk("Reflection #{inspect(reflection_name)} did not deliver its callback")
    end
  end

  defp destination_artefact_until(agent, operator_id, destination, artefact_id, attempts \\ 120)

  defp destination_artefact_until(_agent, _operator_id, _destination, _artefact_id, 0), do: nil

  defp destination_artefact_until(agent, operator_id, destination, artefact_id, attempts) do
    results = search(agent, operator_id, [destination], :artefacts, artefact_id)

    case Enum.find(results, &match?(%{artefact: %{id: ^artefact_id}}, &1)) do
      %{artefact: artefact} ->
        artefact

      nil ->
        Process.sleep(1_000)
        destination_artefact_until(agent, operator_id, destination, artefact_id, attempts - 1)
    end
  end

  defp search(agent, operator_id, destinations, kind, query) do
    assert {:ok, results} =
             Client.search(agent, %Search{
               operator_id: operator_id,
               query: query,
               destinations: destinations
             })

    flatten(results, kind)
  end

  # Searches operator one's `personal` Destination through `Gralkor.Client.search/2`
  # including the given writers (MemorySearch has no writer selection), retrying
  # until `predicate` holds or attempts run out.
  defp writer_search_until(agent, writers, query, predicate, attempts \\ 60) do
    assert {:ok, results} =
             Client.search(agent, %Search{
               operator_id: @operator_one,
               query: query,
               destinations: ["personal"],
               writers: writers
             })

    if predicate.(results) or attempts <= 1 do
      results
    else
      Process.sleep(1_000)
      writer_search_until(agent, writers, query, predicate, attempts - 1)
    end
  end

  # Searches every Destination operator one can read through
  # `Gralkor.Client.search/2` for memory created at or after `since`, retrying
  # until `predicate` holds or attempts run out.
  defp since_search_until(agent, since, query, predicate, attempts \\ 60) do
    assert {:ok, results} =
             Client.search(agent, %Search{
               operator_id: @operator_one,
               query: query,
               since: since
             })

    if predicate.(results) or attempts <= 1 do
      results
    else
      Process.sleep(1_000)
      since_search_until(agent, since, query, predicate, attempts - 1)
    end
  end

  defp lens_episodes(results), do: Enum.flat_map(results, & &1.episodes)

  defp assert_since_reflection_artefact(%{adventure: adventure}) do
    assert adventure.consumer_destination_artefact in Enum.map(
             flatten(adventure.since_reflection_search, :artefacts),
             & &1.artefact
           )
  end

  defp refute_since_reflection_direct_memory(%{adventure: adventure}) do
    refute directly_written_memory?(adventure.since_reflection_search)
  end

  defp directly_written_memory?(results) do
    episodes = lens_episodes(results)
    facts = Enum.flat_map(results, & &1.facts)
    texts = Enum.map(episodes, &episode_content/1) ++ Enum.map(facts, & &1.fact)
    sources = Enum.flat_map(facts, &Map.get(&1, :sources, []))

    Enum.any?(episodes ++ sources, &(Map.get(&1, :writer) == :direct)) or
      Enum.any?(texts, &String.contains?(&1, ["Juniper", "Kestrel", "Cedar"]))
  end

  defp flatten(results, :facts),
    do:
      for(
        result <- results,
        fact <- result.facts,
        do: %{destination: result.destination, fact: fact}
      )

  defp flatten(results, :artefacts),
    do:
      for(
        result <- results,
        %{artefact: artefact} <- result.episodes,
        do: %{destination: result.destination, artefact: struct!(Artefact, artefact)}
      )

  defp flatten(results, :episodes),
    do:
      for(
        result <- results,
        episode <- result.episodes,
        do: %{destination: result.destination, episode: episode}
      )

  defp memory_search(agent, operator_id, params) do
    assert {:ok, %{sections: sections}} =
             MemorySearch.run(params, %{agent_id: operator_id, gralkor_runtime: agent})

    facts_matching_text(
      agent,
      operator_id,
      params,
      JidoGralkor.MemorySearchPresentation.text(sections)
    )
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
      destinations: Map.get(arguments, :destinations, Map.get(arguments, "destinations", []))
    }

    results = results_matching_text(agent, @operator_one, params, text)

    %{
      answer: answer,
      memory_search_arguments: %{
        destinations: Map.get(arguments, :destinations, Map.get(arguments, "destinations"))
      },
      memory_search_completion_count: length(memory_search_completed),
      memory_search_results: flatten(results, :facts),
      memory_search_destinations: Enum.map(results, & &1.destination),
      memory_search_artefacts: flatten(results, :artefacts),
      memory_search_text: text
    }
  end

  defp decode_memory_search_result(%{
         data: %{result: {:ok, %{sections: sections}, _effects}}
       }) do
    JidoGralkor.MemorySearchPresentation.text(sections)
  end

  defp search_until(
         agent,
         operator_id,
         destinations,
         result_type,
         query,
         predicate,
         attempts \\ 60
       ) do
    results = search(agent, operator_id, destinations, result_type, query)

    cond do
      predicate.(results) ->
        results

      attempts <= 1 ->
        results

      true ->
        Process.sleep(1_000)

        search_until(
          agent,
          operator_id,
          destinations,
          result_type,
          query,
          predicate,
          attempts - 1
        )
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

  defp facts_matching_text(agent, operator, params, text) do
    agent |> results_matching_text(operator, params, text) |> flatten(:facts)
  end

  defp results_matching_text(agent, operator, params, text) do
    assert {:ok, results} =
             Client.search(agent, %Search{
               operator_id: operator,
               query: params.query,
               destinations: Map.get(params, :destinations, [])
             })

    assert text ==
             results
             |> JidoGralkor.MemorySearchPresentation.sections()
             |> JidoGralkor.MemorySearchPresentation.text()

    results
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

  defp attributed_facts(
         agent,
         operator_id,
         destination,
         query,
         fact_from_episode?,
         source_kind,
         source_description,
         attempts \\ 10
       ) do
    facts =
      agent
      |> search(operator_id, [destination], :facts, query)
      |> Enum.filter(fact_from_episode?)

    cond do
      every_fact_attributed?(facts, source_kind, source_description) ->
        facts

      attempts <= 1 ->
        facts

      true ->
        Process.sleep(1_000)

        attributed_facts(
          agent,
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

  defp transcript(messages), do: Distill.format_transcript([messages], "Susu", "Eli")
end
