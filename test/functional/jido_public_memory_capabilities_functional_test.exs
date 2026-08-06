defmodule JidoGralkor.PublicMemoryCapabilitiesFunctionalTest do
  use ExUnit.Case, async: false

  alias Gralkor.Client.InMemory
  alias JidoGralkor.Actions.MemoryBuildCommunities
  alias JidoGralkor.Actions.MemoryBuildIndices
  alias JidoGralkor.Actions.MemorySearch
  alias JidoGralkor.LifecycleTestAgent
  alias JidoGralkor.LifecycleTestJido
  alias JidoGralkor.ReAct

  @moduletag :functional

  setup do
    InMemory.reset()
    :ok
  end

  describe "when an application gracefully stops an agent with a committed thread" do
    test "then the configured memory client flushes that thread without delaying termination" do
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
        put_in(state.agent.state[:__thread__], %{id: "committed-thread"})
      end)

      started_at = System.monotonic_time(:millisecond)
      assert :ok = GenServer.stop(pid, :shutdown, 5_000)
      assert System.monotonic_time(:millisecond) - started_at < 1_000
      assert eventually(fn -> InMemory.flushes() == [["committed-thread"]] end)
    end
  end

  describe "when an operator runs the build-indices memory action" do
    test "then the action reports the backend status after one unscoped index build" do
      InMemory.set_build_indices({:ok, %{status: "stored"}})

      assert {:ok, %{result: result}} = MemoryBuildIndices.run(%{}, %{})
      assert result =~ "stored"
      assert InMemory.indices_builds() == [[]]
    end

    test "and a backend failure is returned unchanged" do
      InMemory.set_build_indices({:error, :unavailable})
      assert {:error, :unavailable} = MemoryBuildIndices.run(%{}, %{})
    end
  end

  describe "when an operator runs the build-communities memory action" do
    test "then the action reports the backend counts after one build for the operator's sanitised group" do
      InMemory.set_build_communities({:ok, %{communities: 3, edges: 17}})

      assert {:ok, %{result: result}} =
               MemoryBuildCommunities.run(%{}, %{agent_id: "operator-one"})

      assert result =~ "3"
      assert result =~ "17"
      assert InMemory.communities_builds() == [["operator_one"]]
    end

    test "and a backend failure is returned unchanged" do
      InMemory.set_build_communities({:error, :unavailable})
      assert {:error, :unavailable} = MemoryBuildCommunities.run(%{}, %{agent_id: "operator"})
    end
  end

  describe "if an agent invokes memory search without a usable query" do
    test "then no backend is queried and the agent receives an explicit non-result" do
      assert {:ok, %{result: result}} =
               MemorySearch.run(%{query: "  "}, %{
                 agent_id: "operator-one",
                 agent_name: "Susu",
                 session_id: "thread-one"
               })

      assert result =~ "NON-RESULT"
      assert result =~ "no query was provided"
      assert InMemory.recalls() == []
    end
  end

  describe "if an agent invokes memory search without a committed session" do
    test "then no backend is queried and the agent receives an explicit non-result" do
      assert {:ok, %{result: result}} =
               MemorySearch.run(%{query: "launch"}, %{
                 agent_id: "operator-one",
                 agent_name: "Susu"
               })

      assert result =~ "NON-RESULT"
      assert result =~ "long-term memory was NOT queried"
      assert InMemory.recalls() == []
    end
  end

  describe "when a consumer prepares the first ReAct iteration" do
    test "then memory search is forced while every existing request override is preserved" do
      overrides = %{messages: [:message], llm_opts: [temperature: 0.2]}
      result = ReAct.maybe_force_memory_search(overrides, %{iteration: 1})

      assert result.messages == [:message]
      assert result.llm_opts[:temperature] == 0.2

      assert result.llm_opts[:tool_choice] == %{
               type: "function",
               function: %{name: "memory_search"}
             }
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
end
