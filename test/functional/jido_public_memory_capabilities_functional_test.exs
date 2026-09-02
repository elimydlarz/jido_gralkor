defmodule JidoGralkor.PublicMemoryCapabilitiesFunctionalTest do
  use ExUnit.Case, async: false

  alias Gralkor.Client
  alias Gralkor.Client.InMemory
  alias Gralkor.Ingest
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

  setup do
    previous =
      for key <- [:destinations, :destination_storage, :lenses, :lens_storage], into: %{} do
        {key, Application.get_env(:jido_gralkor, key)}
      end

    start_supervised!(Gralkor.Lens.Storage.InMemory)
    start_supervised!(Gralkor.Destination.Storage.InMemory)

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
      pid = start_agent_with_thread("committed-thread")
      started_at = System.monotonic_time(:millisecond)
      assert :ok = GenServer.stop(pid, :shutdown, 5_000)
      assert System.monotonic_time(:millisecond) - started_at < 1_000
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
    test "then the background failure is logged and the agent's immediate acknowledgement remains unchanged" do
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

    test "where both selectors are omitted or empty then every accessible registered Destination can contribute" do
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

    test "where only Destinations are supplied then only results from any supplied Destination can contribute" do
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

    test "where only Lenses are supplied then only results originating in any supplied Lens can contribute" do
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

    test "where Destinations and Lenses are supplied then only results matching both selections can contribute" do
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

    test "where no conversation thread has been committed then search still runs for the current operator" do
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

    test "if Search fails then the failure is returned unchanged" do
      Application.put_env(:jido_gralkor, :destination_storage, FailingSearchStorage)

      assert {:error, :unavailable} =
               memory_search(
                 %{query: "unavailable", destinations: ["observations"]},
                 []
               )
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

  describe "when a mounted plugin completes a memory-worthy turn with a committed thread" do
    test "if agent state has no non-blank user name then completion raises an ArgumentError naming the missing user name" do
      assert_raise ArgumentError, ~r/user_name/, fn ->
        complete_plugin_turn(%{}, :ok)
      end
    end

    test "if capture fails then completion raises reporting the capture failure" do
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
             Gralkor.Reflection.Storage.InMemory.put(reflection, "operator-one", artefact)

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
end
