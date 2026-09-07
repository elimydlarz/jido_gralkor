defmodule JidoGralkor.PublicMemoryCapabilitiesFunctionalTest do
  use Jido.AI.TestCase, async: false

  alias Gralkor.Client
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

      {:ok, [%{content: "matching stored episode", lens: "observations"}]}
    end
  end

  defmodule InspectingProviderFixture do
    @observation "A reversible canary exposed a configuration fault before broad deployment impact."
    @generalisation "Reversible limited-scope trials expose faults before broad impact across deployments, migrations, and feature releases."
    @predecessor "A reversible limited-scope trial exposed faults before a deployment reached broad impact."
    @answer "RECOMMENDATION: Use a reversible limited-scope canary for the Payments database migration.\nPREDECESSOR: level 1; scope deployment rollout\nEVOLVED: level 2; newly covered scope feature releases\nRATIONALE: The evolved lesson and related observation show that a limited reversible trial can expose faults before broad impact."

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
          object: "chat.completion",
          model: "fixture",
        status: "completed",
        output:
          if(valid?, do: [%{"type" => "message", "role" => "assistant", "content" => [%{"type" => "output_text", "text" => @answer}]}], else: [])
        })
      )
    end

    defp exact_memory_evidence?(tool_results) when tool_results != [] do
      decoded = Enum.flat_map(tool_results, &decode_content/1)

      Enum.any?(decoded, &deep_contains?(&1, @observation)) and
        Enum.any?(decoded, &deep_contains_generalisation?(&1))
    end

    defp exact_memory_evidence?(_), do: false

    defp decode_content(%{"output" => output}) when is_binary(output), do: decode_json(output)

    defp decode_content(%{"content" => content}) when is_binary(content), do: decode_json(content)

    defp decode_content(_), do: []

    defp decode_json(value) do
      case Jason.decode(value) do
        {:ok, decoded} -> [decoded | nested_decoded(decoded)]
        {:error, _} -> [value]
      end
    end

    defp nested_decoded(value) when is_map(value),
      do: value |> Map.values() |> Enum.flat_map(&nested_decoded/1)

    defp nested_decoded(value) when is_list(value),
      do: Enum.flat_map(value, &nested_decoded/1)

    defp nested_decoded(_), do: []

    defp deep_contains?(value, expected) when is_binary(value), do: value == expected

    defp deep_contains?(value, expected) when is_map(value),
      do:
        Enum.any?(value, fn {key, item} ->
          (key == "content" and deep_contains?(item, expected)) or deep_contains?(item, expected)
        end)

    defp deep_contains?(value, expected) when is_list(value),
      do: Enum.any?(value, &deep_contains?(&1, expected))

    defp deep_contains?(_, _), do: false

    defp deep_contains_generalisation?(value) when is_map(value) do
      generalisations = Map.get(value, "generalisations", [])

      Enum.any?(generalisations, fn item ->
        is_map(item) and
          item["content"] == @generalisation and
          item["level"] == 2 and
          Enum.any?(item["evolves_from"] || [], fn predecessor ->
            is_map(predecessor) and predecessor["content"] == @predecessor and
              predecessor["level"] == 1
          end)
      end) or Enum.any?(Map.values(value), &deep_contains_generalisation?/1)
    end

    defp deep_contains_generalisation?(value) when is_list(value),
      do: Enum.any?(value, &deep_contains_generalisation?/1)

    defp deep_contains_generalisation?(_), do: false
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

  setup do
    previous =
      for key <- [
            :client,
            :destinations,
            :destination_storage,
            :lenses,
            :lens_storage
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
      Gralkor.Destination.Storage.InMemory
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
      for operator <- ["operator-one", "operator-two"] do
        assert :ok =
                 Client.ingest(%Ingest{
                   id: "operator-scope-#{operator}",
                   operator_id: operator,
                   lens: "operator",
                   source_kind: :document,
                   content: "private memory for #{operator}",
                   source_description: "functional"
                 })
      end

      assert {:ok, %{result: result}} =
               memory_search(%{query: "private", destinations: ["operator"]}, [])

      assert Jason.decode!(result) == [
               %{
                 "destination" => "operator",
                 "episode" => %{
                   "content" => "private memory for operator-one",
                   "lens" => "operator"
                 }
               }
             ]
    end

    test "and the usable query selects relevant stored episodes" do
      Application.put_env(:jido_gralkor, :destination_storage, RecordingSearchStorage)
      Application.put_env(:jido_gralkor, :public_search_test_pid, self())
      on_exit(fn -> Application.delete_env(:jido_gralkor, :public_search_test_pid) end)

      query = "  launch city  "

      assert {:ok, %{result: result}} =
               memory_search(%{query: query, destinations: ["observations"]}, [])

      assert_receive {:public_search, "observations", "operator-one", ^query, :episodes, 20, []}

      assert Jason.decode!(result) == [
               %{
                 "destination" => "observations",
                 "episode" => %{
                   "content" => "matching stored episode",
                   "lens" => "observations"
                 }
               }
             ]
    end

    test "and returned results obey the optional `destinations` and `lenses` selectors supplied for that invocation" do
      assert :ok = ingest_memory("observations", "selected observation")
      assert :ok = ingest_memory("decisions", "selected decision")

      assert {:ok, %{result: result}} =
               memory_search(
                 %{
                   query: "selected",
                   destinations: ["observations", "decisions"],
                   lenses: ["decisions"]
                 },
                 []
               )

      assert Jason.decode!(result) == [
               %{
                 "destination" => "decisions",
                 "episode" => %{"content" => "selected decision", "lens" => "decisions"}
               }
             ]
    end

    test "and the action returns results as JSON with their Destination and originating Lens or declaring Reflection" do
      assert :ok = ingest_memory("observations", "provenance observation")
      artefact = put_generalisation("provenance generalisation", 1, [])

      assert {:ok, %{result: result}} =
               memory_search(
                 %{query: "provenance", destinations: ["observations", "global"]},
                 []
               )

      assert [
               %{
                 "destination" => "observations",
                 "episode" => %{
                   "content" => "provenance observation",
                   "lens" => "observations"
                 }
               },
               %{
                 "destination" => "global",
                 "episode" => %{
                   "content" => encoded_artefact,
                   "reflection" => "generalisations"
                 }
               }
             ] = Jason.decode!(result)

      assert Jason.decode!(encoded_artefact)["id"] == artefact.id
    end

    test "and relevant stored generalisations can contribute beside related ingested information" do
      assert :ok = ingest_memory("observations", "related rollout observation")
      _artefact = put_generalisation("related rollout generalisation", 1, [])

      assert {:ok, %{result: result}} =
               memory_search(
                 %{query: "related rollout", destinations: ["observations", "global"]},
                 []
               )

      assert [
               %{"episode" => %{"lens" => "observations"}},
               %{"episode" => %{"reflection" => "generalisations"}}
             ] = Jason.decode!(result)
    end

    test "and each returned generalisation exposes its exact content, evolution-depth level, and `evolves_from` history" do
      evolves_from = [%{"content" => "earlier rollout guidance", "level" => 1}]
      artefact = put_generalisation("current rollout guidance", 2, evolves_from)

      assert {:ok, %{result: result}} =
               memory_search(%{query: "rollout guidance", destinations: ["global"]}, [])

      assert [
               %{
                 "episode" => %{
                   "content" => encoded_artefact,
                   "reflection" => "generalisations"
                 }
               }
             ] = Jason.decode!(result)

      assert Jason.decode!(encoded_artefact)["payload"] == artefact.payload
    end
  end

  describe "when an agent invokes memory search with a usable query > where both selectors are omitted or empty" do
    test "then every accessible registered Destination can contribute" do
      assert :ok = ingest_memory("operator", "operator default")
      assert :ok = ingest_memory("shared-notes", "global default")
      assert :ok = ingest_memory("observations", "observation default")
      assert :ok = ingest_memory("decisions", "decision default")

      assert {:ok, %{result: result}} = memory_search(%{query: "default"}, [])

      assert Enum.map(Jason.decode!(result), & &1["destination"]) == [
               "operator",
               "global",
               "observations",
               "decisions"
             ]
    end
  end

  describe "when an agent invokes memory search with a usable query > where only Destinations are supplied" do
    test "then only results from any supplied Destination can contribute" do
      assert :ok = ingest_memory("observations", "destination-only observation")
      assert :ok = ingest_memory("decisions", "destination-only decision")

      assert {:ok, %{result: result}} =
               memory_search(
                 %{query: "destination-only", destinations: ["observations"]},
                 []
               )

      assert Jason.decode!(result) == [
               %{
                 "destination" => "observations",
                 "episode" => %{
                   "content" => "destination-only observation",
                   "lens" => "observations"
                 }
               }
             ]
    end
  end

  describe "when an agent invokes memory search with a usable query > where only Lenses are supplied" do
    test "then only results originating in any supplied Lens can contribute" do
      assert :ok = ingest_memory("observations", "lens-only observation")
      assert :ok = ingest_memory("decisions", "lens-only decision")

      assert {:ok, %{result: result}} =
               memory_search(%{query: "lens-only", lenses: ["decisions"]}, [])

      assert Jason.decode!(result) == [
               %{
                 "destination" => "decisions",
                 "episode" => %{
                   "content" => "lens-only decision",
                   "lens" => "decisions"
                 }
               }
             ]
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

      assert Jason.decode!(result) == []
    end
  end

  describe "when an agent invokes memory search with a usable query > where no conversation thread has been committed" do
    test "then search still runs for the current operator" do
      assert :ok = ingest_memory("observations", "thread-independent search")

      assert {:ok, %{result: result}} =
               memory_search(
                 %{query: "thread-independent", destinations: ["observations"]},
                 []
               )

      assert Jason.decode!(result) == [
               %{
                 "destination" => "observations",
                 "episode" => %{
                   "content" => "thread-independent search",
                   "lens" => "observations"
                 }
               }
             ]
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
    test "then the answer identifies the retrieved deployment predecessor and newly covered feature-release scope" do
      answer = deterministic_evolved_generalisation_answer()

      assert answer =~ "PREDECESSOR: level 1; scope deployment rollout"
      assert answer =~ "EVOLVED: level 2; newly covered scope feature releases"
    end

    test "and the recommendation applies their reversible limited-scope lesson to the requested migration" do
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

    test "and its description directs the agent to apply relevant generalisations in light of their evolution histories and related observations" do
      description = MemorySearch.__action_metadata__().description

      assert description =~
               "Apply relevant generalisations in light of their evolution histories and related observations"
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
    assert Enum.any?(tool_results, &(to_string(&1["content"]) =~ "evolves_from"))
    answer
  end

  defp drain_provider_messages(acc) do
    receive do
      {:provider_request, url, payload} ->
        roles = payload |> Map.get("messages", []) |> Enum.map(&Map.get(&1, "role"))
        drain_provider_messages([{url, roles} | acc])

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

    artefact
  end
end
