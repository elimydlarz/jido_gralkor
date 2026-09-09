defmodule JidoGralkor.PublicMemoryCapabilitiesFunctionalTest do
  use Jido.AI.TestCase, async: false

  alias Gralkor.Client
  alias JidoGralkor.MemorySearchPresentation, as: Presentation
  alias Gralkor.Client.InMemory
  alias Gralkor.Client.Native
  alias Gralkor.CaptureBuffer
  alias Gralkor.Ingest
  alias Gralkor.Message
  alias JidoGralkor.Actions.MemoryAdd
  alias JidoGralkor.Actions.MemoryBuildCommunities
  alias JidoGralkor.Actions.MemoryBuildIndices
  alias JidoGralkor.Actions.MemorySearch
  alias JidoGralkor.LifecycleTestAgent
  alias JidoGralkor.LifecycleTestJido
  alias JidoGralkor.Plugin
  alias JidoGralkor.ReAct

  @moduletag :functional

  defmodule FailingSearchStorage do
    @behaviour Gralkor.Destination.Storage

    @impl true
    def search(_destination, _operator_id, _query, _result_type, _max_results, _opts),
      do: {:error, :unavailable}
  end

  defmodule RecordingSearchStorage do
    @behaviour Gralkor.Destination.Storage

    @impl true
    def search(destination, operator_id, query, result_type, max_results, opts) do
      test_pid = Application.fetch_env!(:jido_gralkor, :public_search_test_pid)

      send(
        test_pid,
        {:public_search, destination.name, operator_id, query, result_type, max_results, opts}
      )

      {:ok, [%{fact: "matching stored fact", sources: [%{lens: "observations"}]}]}
    end
  end

  defmodule FactSearchStorage do
    @behaviour Gralkor.Destination.Storage
    def search(destination, operator, query, :facts, maximum, opts) do
      {:ok, observations} =
        Gralkor.Destination.Storage.InMemory.search(
          destination,
          operator,
          query,
          :facts,
          maximum,
          opts
        )

      lenses = Keyword.get(opts, :lenses, [])

      extracted =
        Application.get_env(:jido_gralkor, :public_extracted_facts, [])
        |> Enum.filter(&(&1.destination == destination.name and &1.operator == operator))
        |> Enum.map(& &1.fact)
        |> Enum.filter(fn fact ->
          lenses == [] or Enum.any?(fact.sources, &(Map.get(&1, :lens) in lenses))
        end)

      {:ok, Enum.take(extracted ++ observations, maximum)}
    end

    def search(destination, operator, query, type, maximum, opts),
      do:
        Gralkor.Destination.Storage.InMemory.search(
          destination,
          operator,
          query,
          type,
          maximum,
          opts
        )
  end

  defmodule InspectingProviderFixture do
    @observation "A reversible canary exposed a configuration fault before broad deployment impact."
    @generalisation "Reversible limited-scope trials expose faults before broad impact across deployments, migrations, and feature releases."
    @answer "RECOMMENDATION: Use a reversible limited-scope canary for the Payments database migration. RATIONALE: Retrieved facts show that trials expose faults before broad impact."

    def adapter(test_pid) do
      fn request ->
        body = IO.iodata_to_binary(request.body)
        payload = Jason.decode!(body)
        input = payload["input"] || []
        has_tool_results? = Enum.any?(input, &(&1["type"] == "function_call_output"))
        send(test_pid, {:provider_request, request.url, payload})

        response =
          if has_tool_results? do
            answer_response(payload, test_pid)
          else
            tool_call_response()
          end

        {request, Req.Response.new(status: 200, body: response)}
      end
    end

    defp tool_call_response do
      Jason.decode!(
        Jason.encode!(%{
          id: "fixture-tool-call",
          object: "response",
          status: "completed",
          model: "fixture",
          output: [
            %{
              type: "function_call",
              id: "memory-search-call",
              call_id: "memory-search-call",
              name: "memory_search",
              arguments: Jason.encode!(%{query: "reversible canary deployment feature releases"})
            }
          ]
        })
      )
    end

    defp answer_response(payload, test_pid) do
      tool_results = Enum.filter(payload["input"] || [], &(&1["type"] == "function_call_output"))
      valid? = exact_memory_evidence?(tool_results)

      send(test_pid, {:provider_tool_results_inspected, valid?, tool_results})

      Jason.decode!(
        Jason.encode!(%{
          id: "fixture-answer",
          object: "response",
          model: "fixture",
          status: "completed",
          output:
            if(valid?,
              do: [
                %{
                  "type" => "message",
                  "role" => "assistant",
                  "content" => [%{"type" => "output_text", "text" => @answer}]
                }
              ],
              else: []
            )
        })
      )
    end

    defp exact_memory_evidence?(tool_results) do
      Enum.any?(tool_results, fn %{"output" => output} ->
        case Jason.decode!(output) do
          %{"ok" => true, "result" => %{"result" => text}} when is_binary(text) ->
            String.contains?(text, "Lens: observations\n- " <> @observation) and
              String.contains?(text, "Reflection: generalisations\n- " <> @generalisation)

          _ ->
            false
        end
      end)
    end
  end

  defmodule DeterministicMemoryAgent do
    use Jido.AI.Agent,
      name: "deterministic_memory_agent",
      model: "openai:gpt-4o-mini",
      streaming: false,
      default_plugins: %{__memory__: false},
      plugins: [
        {JidoGralkor.Plugin,
         %{
           agent_name: "Deterministic Memory Agent",
           runtime_config: %{
             destinations: [],
             lenses: [
               %{
                 name: "observations",
                 destination: "operator",
                 write: :append,
                 ingestion: Gralkor.Lens.Ingestion.Store
               }
             ],
             reflections: []
           }
         }}
      ],
      tools: [JidoGralkor.Actions.MemorySearch],
      max_iterations: 2,
      system_prompt:
        "Search memory before answering and apply the retrieved evolved generalisation."

    def on_before_cmd(agent, action) do
      super(%{agent | state: Map.put(agent.state, :user_name, "Eli")}, action)
    end
  end

  defmodule TransportMemoryAgent do
    use Jido.AI.Agent,
      name: "memory_transport_acceptance",
      model: "openai:gpt-4o-mini",
      streaming: false,
      default_plugins: %{__memory__: false},
      tools: [JidoGralkor.Actions.MemorySearch],
      max_iterations: 2,
      system_prompt: "Search memory before answering."
  end

  setup do
    previous =
      for key <- [
            :client,
            :destinations,
            :destination_storage,
            :lenses,
            :lens_storage,
            :public_extracted_facts
          ],
          into: %{} do
        {key, Application.get_env(:jido_gralkor, key)}
      end

    start_supervised!(Gralkor.Lens.Storage.InMemory)
    start_supervised!(Gralkor.Destination.Storage.InMemory)

    flush_test_pid = self()

    add_episode_fn = fn group_id, body, source, ontology, opts ->
      send(
        flush_test_pid,
        {:external_write_started, self(), group_id, body, source, ontology, opts}
      )

      receive do
        :release ->
          send(flush_test_pid, {:external_write_finished, group_id})
          :ok
      after
        5_000 -> :ok
      end
    end

    start_supervised!(
      {CaptureBuffer,
       flush_callback:
         Gralkor.Application.build_flush_callback(nil, add_episode_fn: add_episode_fn)}
    )

    Application.put_env(:jido_gralkor, :destinations, [
      [name: "observations"],
      [name: "decisions"]
    ])

    Application.put_env(
      :jido_gralkor,
      :destination_storage,
      FactSearchStorage
    )

    Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)

    Application.put_env(:jido_gralkor, :lenses, [
      [
        name: "observations",
        destination: "observations",
        ingestion: Gralkor.Lens.Ingestion.Store
      ],
      [
        name: "decisions",
        destination: "decisions",
        ingestion: Gralkor.Lens.Ingestion.Store
      ],
      [
        name: "shared-notes",
        destination: "global",
        ingestion: Gralkor.Lens.Ingestion.Store
      ]
    ])

    Application.put_env(:jido_gralkor, :public_extracted_facts, [])
    InMemory.reset()

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:jido_gralkor, key)
        {key, value} -> Application.put_env(:jido_gralkor, key, value)
      end)
    end)

    :ok
  end

  describe "when an application gracefully stops an agent with a committed thread" do
    test "then termination returns without waiting for the memory flush" do
      Application.put_env(:jido_gralkor, :client, Native)

      assert :ok =
               Native.capture(
                 "committed-thread",
                 "operator/operator-one",
                 "Lifecycle Agent",
                 "Eli",
                 [Message.new("user", "flush this")]
               )

      pid = start_agent_with_thread("committed-thread")
      stop = Task.async(fn -> GenServer.stop(pid, :shutdown, 5_000) end)

      assert_receive {:external_write_started, worker, "operator/operator-one", body, "captured",
                      Gralkor.DefaultOntology, opts}

      assert body == "Eli: flush this"
      assert opts[:source_kind] == :conversation
      refute_receive {:external_write_finished, "operator/operator-one"}
      assert {:ok, :ok} = Task.yield(stop, 100)
      send(worker, :release)
      assert_receive {:external_write_finished, "operator/operator-one"}
    end

    test "and the configured memory client flushes the committed thread" do
      pid = start_agent_with_thread("committed-thread")
      assert :ok = GenServer.stop(pid, :shutdown, 5_000)
      assert eventually(fn -> InMemory.flushes() == [["committed-thread"]] end)
    end
  end

  describe "when an operator runs the build-indices memory action" do
    test "then the action reports the backend status" do
      InMemory.set_build_indices({:ok, %{status: "stored"}})

      assert {:ok, %{result: result}} = MemoryBuildIndices.run(%{}, %{})
      assert result =~ "stored"
    end

    test "and the backend receives one unscoped index build" do
      InMemory.set_build_indices({:ok, %{status: "stored"}})
      assert {:ok, _result} = MemoryBuildIndices.run(%{}, %{})
      assert InMemory.indices_builds() == [[]]
    end

    test "and a backend failure is returned unchanged" do
      InMemory.set_build_indices({:error, :unavailable})
      assert {:error, :unavailable} = MemoryBuildIndices.run(%{}, %{})
    end
  end

  describe "when an operator runs the build-communities memory action" do
    test "then the action reports the backend counts" do
      InMemory.set_build_communities({:ok, %{communities: 3, edges: 17}})

      assert {:ok, %{result: result}} =
               MemoryBuildCommunities.run(%{}, %{agent_id: "operator-one"})

      assert result =~ "3"
      assert result =~ "17"
    end

    test "and the backend receives one build for the graph named `operator/<operator id>`" do
      InMemory.set_build_communities({:ok, %{communities: 3, edges: 17}})

      assert {:ok, _result} =
               MemoryBuildCommunities.run(%{}, %{agent_id: "operator-one"})

      assert InMemory.communities_builds() == [["operator/operator-one"]]
    end

    test "and a backend failure is returned unchanged" do
      InMemory.set_build_communities({:error, :unavailable})
      assert {:error, :unavailable} = MemoryBuildCommunities.run(%{}, %{agent_id: "operator"})
    end
  end

  describe "when an agent invokes memory addition and its background write fails" do
    test "then the background failure is logged" do
      InMemory.set_memory_add({:error, :unavailable})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{result: "Ingesting."}} =
                   MemoryAdd.run(
                     %{
                       content: "remember this",
                       source_kind: :conversation,
                       source_description: "functional"
                     },
                     %{agent_id: "operator-one"}
                   )

          assert eventually(fn -> InMemory.adds() != [] end)
          Process.sleep(20)
        end)

      assert log =~ "memory_add failed"
      assert log =~ "unavailable"
    end

    test "and the agent's immediate acknowledgement remains unchanged" do
      InMemory.set_memory_add({:error, :unavailable})

      assert {:ok, %{result: "Ingesting."}} =
               MemoryAdd.run(
                 %{
                   content: "remember this",
                   source_kind: :conversation,
                   source_description: "functional"
                 },
                 %{agent_id: "operator-one"}
               )

      assert eventually(fn -> InMemory.adds() != [] end)
    end
  end

  describe "when an agent invokes memory search with a usable query" do
    test "then returned results are scoped to the current operator" do
      assert :ok = ingest_memory("operator", "own memory")
      assert :ok = ingest_memory("operator", "other memory", "operator-two")

      assert {:ok, %{result: text}} =
               memory_search(%{query: "memory", destinations: ["operator"]}, [])

      assert text == "Lens: operator\n- own memory"
    end

    test "and the usable query selects relevant extracted facts" do
      Application.put_env(:jido_gralkor, :destination_storage, RecordingSearchStorage)
      Application.put_env(:jido_gralkor, :public_search_test_pid, self())
      on_exit(fn -> Application.delete_env(:jido_gralkor, :public_search_test_pid) end)

      assert {:ok, %{result: "Lens: observations\n- matching stored fact"}} =
               memory_search(%{query: "precise query", destinations: ["observations"]}, [])

      assert_receive {:public_search, "observations", "operator-one", "precise query", :facts, 20,
                      _}
    end

    test "and returned results obey the optional `destinations` and `lenses` selectors supplied for that invocation" do
      assert :ok = ingest_memory("observations", "wanted")
      assert :ok = ingest_memory("decisions", "other")

      assert {:ok, %{result: text}} =
               memory_search(
                 %{query: "memory", destinations: ["observations"], lenses: ["observations"]},
                 []
               )

      assert text == "Lens: observations\n- wanted"
    end

    test "and the action returns one readable string with fact bullets grouped under named Lens or Reflection headings" do
      assert :ok = ingest_memory("observations", "Payment retries need an idempotency key.")

      assert {:ok, %{result: text}} =
               memory_search(%{query: "payment", destinations: ["observations"]}, [])

      assert text == "Lens: observations\n- Payment retries need an idempotency key."
    end

    test "and relevant stored generalisations can contribute beside related ingested information" do
      assert :ok = ingest_memory("observations", "observed rollout")
      put_generalisation("Use canaries", 2, [])

      assert {:ok, %{result: text}} =
               memory_search(%{query: "rollout", destinations: ["observations", "global"]}, [])

      assert text ==
               "Lens: observations\n- observed rollout\n\nReflection: generalisations\n- Use canaries"
    end

    test "and the presentation adds no artefact identifiers, evolution-depth levels, or lineage metadata" do
      put_generalisation("Use canaries", 2, [%{"content" => "prior", "level" => 1}])

      assert {:ok, %{result: "Reflection: generalisations\n- Use canaries"}} =
               memory_search(%{query: "canaries", destinations: ["global"]}, [])
    end
  end

  describe "when an agent invokes memory search with a usable query > where both selectors are omitted or empty" do
    test "then every accessible registered Destination can contribute" do
      for lens <- ["operator", "shared-notes", "observations", "decisions"],
          do: assert(:ok = ingest_memory(lens, lens <> " fact"))

      assert {:ok, %{result: text}} = memory_search(%{query: "fact"}, [])

      for lens <- ["operator", "shared-notes", "observations", "decisions"],
          do: assert(text =~ "Lens: #{lens}\n- #{lens} fact")
    end
  end

  describe "when an agent invokes memory search with a usable query > where only Destinations are supplied" do
    test "then only results from any supplied Destination can contribute" do
      assert :ok = ingest_memory("observations", "wanted")
      assert :ok = ingest_memory("decisions", "other")

      assert {:ok, %{result: text}} =
               memory_search(%{query: "memory", destinations: ["observations"]}, [])

      assert text == "Lens: observations\n- wanted"
    end
  end

  describe "when an agent invokes memory search with a usable query > where only Lenses are supplied" do
    test "then only results originating in any supplied Lens can contribute" do
      assert :ok = ingest_memory("observations", "wanted")
      assert :ok = ingest_memory("decisions", "other")
      assert {:ok, %{result: text}} = memory_search(%{query: "memory", lenses: ["decisions"]}, [])
      assert text == "Lens: decisions\n- other"
    end
  end

  describe "when an agent invokes memory search with a usable query > where Destinations and Lenses are supplied" do
    test "then only results matching both selections can contribute" do
      assert :ok = ingest_memory("observations", "intersection observation")
      assert :ok = ingest_memory("decisions", "intersection decision")

      assert {:ok, %{result: result}} =
               memory_search(
                 %{
                   query: "intersection",
                   destinations: ["observations"],
                   lenses: ["decisions"]
                 },
                 []
               )

      assert result == "No matching facts."
    end
  end

  describe "when an agent invokes memory search with a usable query > where no conversation thread has been committed" do
    test "then search still runs for the current operator" do
      assert :ok = ingest_memory("observations", "wanted")
      assert :ok = ingest_memory("decisions", "other")

      assert {:ok, %{result: text}} =
               memory_search(%{query: "memory", destinations: ["observations"]}, [])

      assert text == "Lens: observations\n- wanted"
    end
  end

  describe "when an agent invokes memory search with a usable query > if Search fails" do
    test "then the failure is returned unchanged" do
      Application.put_env(:jido_gralkor, :destination_storage, FailingSearchStorage)

      assert {:error, :unavailable} =
               memory_search(
                 %{query: "unavailable", destinations: ["observations"]},
                 []
               )
    end
  end

  describe "when a fresh agent handles a request related to an evolved generalisation" do
    test "then the answer uses the retrieved facts relevant to the requested migration" do
      answer = deterministic_evolved_generalisation_answer()
      assert answer =~ "Retrieved facts show that trials expose faults before broad impact"
    end

    test "and the recommendation applies the retrieved reversible limited-scope lesson to the requested migration" do
      answer = deterministic_evolved_generalisation_answer()

      assert answer =~ "RECOMMENDATION: Use a reversible limited-scope canary"
      assert answer =~ "Payments database migration"
      assert answer =~ "expose faults before broad impact"
    end
  end

  describe "when an agent receives the memory search tool" do
    test "then its description directs the agent to search related observations and generalisations" do
      description = MemorySearch.__action_metadata__().description

      assert description =~ "Search related stored observations and generalisations"
    end

    test "and its description directs the agent to use the returned source-grouped facts" do
      description = MemorySearch.__action_metadata__().description

      assert description =~
               "Use the returned source-grouped facts"
    end
  end

  describe "if an agent invokes memory search without a usable query" do
    test "then no Search is issued" do
      Application.put_env(:jido_gralkor, :destination_storage, RecordingSearchStorage)
      Application.put_env(:jido_gralkor, :public_search_test_pid, self())
      on_exit(fn -> Application.delete_env(:jido_gralkor, :public_search_test_pid) end)

      assert {:ok, _result} = memory_search(%{query: "  "}, session_id: "thread-one")
      refute_receive {:public_search, _, _, _, _, _, _}
    end

    test "and the agent receives an explicit non-result" do
      assert {:ok, %{result: result}} =
               memory_search(%{query: "  "}, session_id: "thread-one")

      assert result =~ "NON-RESULT"
      assert result =~ "no query was provided"
    end
  end

  describe "when a mounted plugin completes a memory-worthy turn with a committed thread > if agent state has no non-blank user name" do
    test "then completion raises an ArgumentError naming the missing user name" do
      assert_raise ArgumentError, ~r/user_name/, fn ->
        complete_plugin_turn(%{}, :ok)
      end
    end
  end

  describe "when a mounted plugin completes a memory-worthy turn with a committed thread > if capture fails" do
    test "then completion raises reporting the capture failure" do
      assert_raise RuntimeError, ~r/capture failed.*unavailable/, fn ->
        complete_plugin_turn(%{user_name: "Eli"}, {:error, :unavailable})
      end
    end
  end

  describe "when a consumer prepares the first ReAct iteration" do
    test "then memory search is forced" do
      overrides = %{messages: [:message], llm_opts: [temperature: 0.2]}
      result = ReAct.maybe_force_memory_search(overrides, %{iteration: 1})

      assert result.llm_opts[:tool_choice] == %{
               type: "function",
               function: %{name: "memory_search"}
             }
    end

    test "and every existing request override is preserved" do
      overrides = %{messages: [:message], llm_opts: [temperature: 0.2]}
      result = ReAct.maybe_force_memory_search(overrides, %{iteration: 1})

      assert result.messages == [:message]
      assert result.llm_opts[:temperature] == 0.2
    end
  end

  describe "when a consumer prepares a later ReAct iteration" do
    test "then every request override is returned unchanged" do
      overrides = %{messages: [:message], llm_opts: [temperature: 0.2]}
      assert ReAct.maybe_force_memory_search(overrides, %{iteration: 2}) == overrides
    end
  end

  describe "when a consumer explicitly formats structured fact search results" do
    test "then named Lens sources have headings of the form `Lens: <name>`" do
      assert rendered([fact("Use retries", [%{lens: "jira"}])]) == "Lens: jira\n- Use retries"
    end

    test "and named Reflection sources have headings of the form `Reflection: <name>`" do
      assert rendered([fact("Use canaries", [%{reflection: "lessons"}])]) ==
               "Reflection: lessons\n- Use canaries"
    end

    test "and each source heading is followed by bullets containing its returned fact text" do
      assert rendered([
               fact("First\ncontinued", [%{lens: "notes"}]),
               fact("Second", [%{lens: "notes"}])
             ]) == "Lens: notes\n- First\ncontinued\n- Second"
    end

    test "and source groups retain first-appearance order" do
      assert rendered([
               fact("one", [%{lens: "z"}]),
               fact("two", [%{lens: "a"}]),
               fact("three", [%{lens: "z"}])
             ]) == "Lens: z\n- one\n- three\n\nLens: a\n- two"
    end

    test "and facts retain retrieval order within each source group" do
      assert rendered([
               fact("one", [%{lens: "z"}]),
               fact("two", [%{lens: "a"}]),
               fact("three", [%{lens: "z"}])
             ]) == "Lens: z\n- one\n- three\n\nLens: a\n- two"
    end

    test "and formatting leaves the canonical structured search results unchanged" do
      input = [fact("one", [%{lens: "notes", id: "source-id"}])]
      assert rendered(input) == "Lens: notes\n- one"
      assert input == [fact("one", [%{lens: "notes", id: "source-id"}])]
    end
  end

  describe "when a consumer explicitly formats structured fact search results > while a fact has several named sources" do
    test "then the fact appears once under each distinct named source" do
      assert rendered([fact("shared", [%{lens: "notes"}, %{reflection: "lessons"}])]) ==
               "Lens: notes\n- shared\n\nReflection: lessons\n- shared"
    end
  end

  describe "when a consumer explicitly formats structured fact search results > while a Lens and a Reflection share a name" do
    test "then their facts remain in separate source groups" do
      assert rendered([fact("one", [%{lens: "same"}]), fact("two", [%{reflection: "same"}])]) ==
               "Lens: same\n- one\n\nReflection: same\n- two"
    end
  end

  describe "when a consumer explicitly formats structured fact search results > while a fact has no named Lens or Reflection provenance" do
    test "then the fact appears under `Source: unknown`" do
      assert rendered([fact("one", []), fact("two", [%{source_description: "legacy"}])]) ==
               "Source: unknown\n- one\n- two"
    end
  end

  describe "when a consumer explicitly formats structured fact search results > while search returns no facts" do
    test "then the text explicitly states that no matching facts were found" do
      assert rendered([]) == "No matching facts."
    end
  end

  describe "when memory search formats facts for the consuming agent" do
    test "then the complete text including headings and omission notices stays within 16384 characters" do
      assert :ok = ingest_memory("observations", String.duplicate("x", 16_385))
      assert :ok = ingest_memory("observations", "small")

      assert {:ok, %{result: text}} =
               memory_search(%{query: "x", destinations: ["observations"]}, [])

      assert text == "Lens: observations\n- small\n\nOmitted facts: 1 (response limit)."
      assert String.length(text) <= 16_384
    end

    test "and the serialized success envelope fits the configured byte budget" do
      assert :ok = ingest_memory("observations", String.duplicate("λ\n\"", 100))
      assert :ok = ingest_memory("observations", "small")

      result =
        memory_search(%{query: "x", destinations: ["observations"]}, memory_search_max_bytes: 200)

      assert byte_size(Jido.AI.Turn.format_tool_result_content(result)) <= 200
    end

    test "and every included fact retains its complete text" do
      content = "Exact λ text\nwith another line."
      assert :ok = ingest_memory("observations", content)

      assert {:ok, %{result: text}} =
               memory_search(%{query: "x", destinations: ["observations"]}, [])

      assert text == "Lens: observations\n- " <> content
    end
  end

  describe "when memory search formats facts for the consuming agent > while a fact cannot fit within the response limits" do
    test "then that whole fact is omitted while later fitting facts remain eligible" do
      assert :ok = ingest_memory("observations", String.duplicate("x", 17_000))
      assert :ok = ingest_memory("observations", "later")

      assert {:ok, %{result: "Lens: observations\n- later\n\nOmitted facts: 1 (response limit)."}} =
               memory_search(%{query: "x", destinations: ["observations"]}, [])
    end

    test "and the text reports the omitted fact count and response-limit reason" do
      for _ <- 1..2,
          do: assert(:ok = ingest_memory("observations", String.duplicate("x", 17_000)))

      assert {:ok, %{result: "Omitted facts: 2 (response limit)."}} =
               memory_search(%{query: "x", destinations: ["observations"]}, [])
    end
  end

  describe "when memory search formats facts for the consuming agent > while the byte budget cannot hold an empty response with the required notice" do
    test "then an explicit budget error is returned" do
      assert {:error, {:memory_search_budget_too_small, %{max_bytes: 1, minimum_bytes: minimum}}} =
               memory_search(%{query: "x"}, memory_search_max_bytes: 1)

      assert minimum > 1
    end
  end

  describe "when memory search formats facts for the consuming agent > if the byte budget is not a positive integer" do
    test "then the action rejects the budget before searching memory" do
      Application.put_env(:jido_gralkor, :destination_storage, RecordingSearchStorage)
      Application.put_env(:jido_gralkor, :public_search_test_pid, self())
      on_exit(fn -> Application.delete_env(:jido_gralkor, :public_search_test_pid) end)

      for invalid <- [0, -1, nil, 1.5, "100"] do
        assert_raise ArgumentError, ~r/memory_search_max_bytes.*positive integer/, fn ->
          memory_search(%{query: "x"}, memory_search_max_bytes: invalid)
        end
      end

      refute_received {:public_search, _, _, _, _, _, _}
    end
  end

  describe "when unmodified Jido AI 2.3.0 sends memory search output to the provider" do
    test "then one decode of the tool envelope exposes the exact readable string returned by the action" do
      assert :ok = ingest_memory("observations", "A precise fact with document_key and λ.")
      params = %{query: "x", destinations: ["observations"]}
      assert {:ok, expected} = memory_search(params, [])
      {wire, _} = provider_memory_result(params)
      assert wire == %{"ok" => true, "result" => %{"result" => expected.result}}
    end

    test "and the tool result contains readable fact bullets rather than a JSON-encoded result list" do
      assert :ok = ingest_memory("observations", "Use retries.")
      {wire, _} = provider_memory_result(%{query: "x", destinations: ["observations"]})
      assert wire["result"]["result"] == "Lens: observations\n- Use retries."
    end
  end

  describe "when unmodified Jido AI 2.3.0 sends memory search output to the provider > while the canonical Reflection payload contains deep lineage or domain keys ending in `_key`" do
    test "then the provider receives the retained extracted fact text unchanged" do
      history =
        Enum.reduce(1..12, %{"document_key" => "ABC-123"}, fn _, value ->
          %{"history" => value}
        end)

      artefact = put_generalisation("Use canaries for ABC-123.", 2, [history])
      {wire, _} = provider_memory_result(%{query: "x", destinations: ["global"]})

      assert wire["result"]["result"] ==
               "Reflection: generalisations\n- Use canaries for ABC-123."

      assert {:ok, [%{episode: %{artefact: stored}}]} =
               Client.search(%Gralkor.Search{
                 operator_id: "operator-one",
                 query: "x",
                 destinations: ["global"]
               })

      assert stored.payload == artefact.payload
    end
  end

  describe "when unmodified Jido AI 2.3.0 sends memory search output to the provider > while more than 100 facts fit within the response limits" do
    test "then the provider receives every formatted fact without a synthetic omission item" do
      names = Enum.map(1..6, &"transport-#{&1}")
      Application.put_env(:jido_gralkor, :destinations, Enum.map(names, &[name: &1]))

      Application.put_env(
        :jido_gralkor,
        :lenses,
        Enum.map(names, &[name: &1, destination: &1, ingestion: Gralkor.Lens.Ingestion.Store])
      )

      for index <- 0..100,
          do: assert(:ok = ingest_memory(Enum.at(names, div(index, 20)), "record-#{index}"))

      params = %{query: "x", destinations: names}
      {wire, _} = provider_memory_result(params)

      expected =
        Enum.map_join(Enum.with_index(names), "\n\n", fn {name, n} ->
          "Lens: #{name}\n" <>
            Enum.map_join((n * 20)..min(n * 20 + 19, 100), "\n", &"- record-#{&1}")
        end)

      assert wire["result"]["result"] == expected
    end
  end

  describe "when unmodified Jido AI 2.3.0 sends memory search output to the provider > while a source fact exceeds the response limits" do
    test "then the provider receives an explicit omission notice instead of a sliced fact" do
      assert :ok = ingest_memory("observations", String.duplicate("λ", 16_385))
      assert :ok = ingest_memory("observations", "small")
      {wire, _} = provider_memory_result(%{query: "x", destinations: ["observations"]})

      assert wire["result"]["result"] ==
               "Lens: observations\n- small\n\nOmitted facts: 1 (response limit)."
    end
  end

  defp provider_memory_result(params, max_bytes \\ 65_536) do
    jido = Jido.default_instance()
    start_supervised!({Jido, name: jido, otp_app: :jido_gralkor})

    assert {:ok, agent} =
             Jido.start_agent(jido, TransportMemoryAgent,
               id: "operator-one",
               register_global: false
             )

    test_pid = self()

    adapter = fn request ->
      payload = request.body |> IO.iodata_to_binary() |> Jason.decode!()

      output =
        case Enum.find(payload["input"], &(&1["type"] == "function_call_output")) do
          nil ->
            [
              %{
                type: "function_call",
                id: "memory-call",
                call_id: "memory-call",
                name: "memory_search",
                arguments: Jason.encode!(params)
              }
            ]

          %{"output" => content} ->
            send(test_pid, {:model_memory_output, content})

            [
              %{
                type: "message",
                role: "assistant",
                content: [%{type: "output_text", text: "done"}]
              }
            ]
        end

      body =
        %{
          id: "transport-response",
          object: "response",
          status: "completed",
          model: "fixture",
          output: output
        }
        |> Jason.encode!()
        |> Jason.decode!()

      {request, Req.Response.new(status: 200, body: body)}
    end

    assert {:ok, "done"} =
             TransportMemoryAgent.ask_sync(agent, "Search memory",
               tool_context: %{memory_search_max_bytes: max_bytes},
               llm_opts: [api_key: "test-provider-key"],
               req_http_options: [adapter: adapter]
             )

    assert_receive {:model_memory_output, content}
    {Jason.decode!(content), byte_size(content)}
  end

  defp fact(text, sources), do: %{destination: "global", fact: %{fact: text, sources: sources}}

  defp rendered(input) do
    assert {:ok, %{result: text}} = Presentation.for_model(input, 65_536)
    text
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp start_agent_with_thread(thread_id) do
    InMemory.set_flush(:ok)
    {:ok, jido} = Jido.start(name: LifecycleTestJido, otp_app: :jido_gralkor)

    on_exit(fn ->
      if Process.alive?(jido) do
        try do
          GenServer.stop(jido, :normal, 5_000)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    {:ok, pid} =
      Jido.start_agent(
        LifecycleTestJido,
        LifecycleTestAgent,
        id: "agent-#{System.unique_integer([:positive])}",
        lifecycle_mod: JidoGralkor.Lifecycle
      )

    :sys.replace_state(pid, fn state ->
      put_in(state.agent.state[:__thread__], %{id: thread_id})
    end)

    pid
  end

  defp memory_search(params, context_options) do
    context =
      %{agent_id: "operator-one", agent_name: "Susu"}
      |> Map.merge(Map.new(context_options))

    MemorySearch.run(params, context)
  end

  defp ingest_memory(lens, content, operator_id \\ "operator-one") do
    Client.ingest(%Ingest{
      id: "public-search-#{System.unique_integer([:positive, :monotonic])}",
      operator_id: operator_id,
      lens: lens,
      source_kind: :document,
      content: content,
      source_description: "functional"
    })
  end

  defp put_generalisation(content, level, evolves_from) do
    reflection = %Gralkor.Reflection{
      name: "generalisations",
      outputs: [
        %{
          kind: :destination,
          destination: Gralkor.Destination.Registry.fetch!("global"),
          ontology: Gralkor.DefaultOntology
        }
      ],
      chain_of_thought: nil
    }

    artefact = %Gralkor.Artefact{
      id: "public-generalisation-#{System.unique_integer([:positive, :monotonic])}",
      payload: %{
        "generalisations" => [
          %{"content" => content, "level" => level, "evolves_from" => evolves_from}
        ]
      }
    }

    assert :ok =
             Gralkor.Destination.Storage.InMemory.put_artefact(
               Enum.find(reflection.outputs, &(&1.kind == :destination)),
               reflection.name,
               "operator-one",
               artefact
             )

    fixtures = Application.get_env(:jido_gralkor, :public_extracted_facts, [])

    Application.put_env(
      :jido_gralkor,
      :public_extracted_facts,
      fixtures ++
        [
          %{
            destination: "global",
            operator: "operator-one",
            fact: %{
              fact: content,
              sources: [
                %{reflection: "generalisations", source_description: "reflection:generalisations"}
              ]
            }
          }
        ]
    )

    artefact
  end

  defp complete_plugin_turn(extra_state, capture_result) do
    request_id = "functional-completion"
    InMemory.set_capture(capture_result)

    agent = %{
      id: "operator-one",
      state:
        Map.merge(
          %{
            __memory__: %{agent_name: "Susu"},
            __thread__: %{id: "thread-one"},
            __strategy__: %{
              request_traces: %{request_id => %{events: [%{kind: :llm_completed, data: %{}}]}}
            },
            requests: %{request_id => %{query: "remember this"}}
          },
          extra_state
        )
    }

    signal =
      Jido.Signal.new!(
        "ai.request.completed",
        %{request_id: request_id, result: "remembered"},
        source: "/functional"
      )

    Plugin.handle_signal(signal, %{agent: agent})
  end

  defp deterministic_evolved_generalisation_answer do
    operator_id = "functional-agent-#{System.unique_integer([:positive])}"
    jido = Jido.default_instance()

    InMemory.set_capture(:ok)

    start_supervised!({Jido, name: jido, otp_app: :jido_gralkor})

    assert {:ok, agent} =
             Jido.start_agent(jido, DeterministicMemoryAgent,
               id: operator_id,
               register_global: false
             )

    assert :ok =
             Client.ingest(agent, %Ingest{
               id: "functional-related-observation",
               operator_id: operator_id,
               lens: "observations",
               source_kind: :document,
               content:
                 "A reversible canary exposed a configuration fault before broad deployment impact.",
               source_description: "deployment review"
             })

    put_generalisation_for(
      operator_id,
      "Reversible limited-scope trials expose faults before broad impact across deployments, migrations, and feature releases.",
      2,
      [
        %{
          "content" =>
            "A reversible limited-scope trial exposed faults before a deployment reached broad impact.",
          "level" => 1
        }
      ]
    )

    prompt = "Recommend how to roll out the Payments database migration."

    provider_adapter = InspectingProviderFixture.adapter(self())

    result =
      DeterministicMemoryAgent.ask_sync(agent, prompt,
        llm_opts: [api_key: "test-provider-key"],
        req_http_options: [adapter: provider_adapter]
      )

    unless match?({:ok, _answer}, result) do
      diagnostics = drain_provider_messages([])

      flunk(
        "provider ReAct diagnostic: result=#{inspect(result)} " <>
          "messages=#{inspect(diagnostics)}"
      )
    end

    {:ok, answer} = result

    assert_receive {:provider_tool_results_inspected, true, tool_results}
    assert tool_results != []
    assert Enum.any?(tool_results, &(to_string(&1["output"]) =~ "Reflection: generalisations"))
    answer
  end

  defp drain_provider_messages(acc) do
    receive do
      {:provider_request, url, payload} ->
        input_types = payload |> Map.get("input", []) |> Enum.map(&Map.get(&1, "type"))
        drain_provider_messages([{url, input_types} | acc])

      {:provider_tool_results_inspected, valid?, _tool_results} ->
        drain_provider_messages([{:tool_results_inspected, valid?} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp put_generalisation_for(operator_id, content, level, evolves_from) do
    reflection = %Gralkor.Reflection{
      name: "generalisations",
      outputs: [
        %{
          kind: :destination,
          destination: Gralkor.Destination.Registry.fetch!("global"),
          ontology: Gralkor.DefaultOntology
        }
      ],
      chain_of_thought: nil
    }

    artefact = %Gralkor.Artefact{
      id: "functional-agent-generalisation-#{System.unique_integer([:positive, :monotonic])}",
      payload: %{
        "generalisations" => [
          %{"content" => content, "level" => level, "evolves_from" => evolves_from}
        ]
      }
    }

    assert :ok =
             Gralkor.Destination.Storage.InMemory.put_artefact(
               Enum.find(reflection.outputs, &(&1.kind == :destination)),
               reflection.name,
               operator_id,
               artefact
             )

    fixtures = Application.get_env(:jido_gralkor, :public_extracted_facts, [])

    Application.put_env(
      :jido_gralkor,
      :public_extracted_facts,
      fixtures ++
        [
          %{
            destination: "global",
            operator: operator_id,
            fact: %{
              fact: content,
              sources: [
                %{reflection: "generalisations", source_description: "reflection:generalisations"}
              ]
            }
          }
        ]
    )

    artefact
  end
end
