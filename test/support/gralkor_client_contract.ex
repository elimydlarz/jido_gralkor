defmodule Gralkor.ClientContract do
  @moduledoc """
  Shared port contract for `Gralkor.Client`.

  `Gralkor.Client.InMemory` imports this executable contract; the Native
  adapter proves the same public port through its integration tests. Reifies
  `test-trees/integration/gralkor-client-in-memory_TEST_TREES.md`. The describe/it hierarchy
  mirrors the tree verbatim.

  Usage from a per-adapter test file:

      use ExUnit.Case, async: false
      import Gralkor.ClientContract

      setup do
        # boot the adapter under test, return any per-test setup
      end

      run_contract(fn -> :ok end)
  """

  defmacro run_contract(do: setup_block) do
    quote do
      describe "when a recall is requested with a group, an agent name, a session id and a query > while the backend returns a memory block" do
        test "then that block is returned to the caller as a success" do
          unquote(setup_block).()

          configure_recall({:ok, "<gralkor-memory>some block</gralkor-memory>"})

          assert {:ok, "<gralkor-memory>some block</gralkor-memory>"} =
                   client().recall("group-1", "TestAgent", "session-1", "what is X?")
        end
      end

      describe "when a recall is requested with a group, an agent name, a session id and a query > if the backend fails" do
        test "then that failure is returned unchanged" do
          unquote(setup_block).()
          configure_recall({:error, :backend_down})

          assert {:error, :backend_down} =
                   client().recall("group-1", "TestAgent", "session-1", "what?")
        end
      end

      describe "where a recall is requested with no session id > while the backend returns a memory block" do
        test "then that block is returned to the caller as a success" do
          unquote(setup_block).()
          configure_recall({:ok, "<gralkor-memory>x</gralkor-memory>"})

          assert {:ok, "<gralkor-memory>x</gralkor-memory>"} =
                   client().recall("group-1", "TestAgent", nil, "anything?")
        end
      end

      describe "where a recall is requested with no session id > if the backend fails" do
        test "then that failure is returned unchanged" do
          unquote(setup_block).()
          configure_recall({:error, :nope})

          assert {:error, :nope} = client().recall("group-1", "TestAgent", nil, "q")
        end
      end

      describe "if a recall is requested with a missing or blank agent name" do
        @describetag :integration
        test "then an argument error is raised at the port boundary" do
          unquote(setup_block).()
          configure_recall({:ok, "should-not-be-returned"})

          for agent_name <- ["", "   ", nil] do
            assert_raise ArgumentError, ~r/agent_name/, fn ->
              client().recall("group-1", agent_name, "session-1", "q")
            end
          end
        end

        test "and no backend call is made" do
          unquote(setup_block).()
          configure_recall({:ok, "should-not-be-returned"})

          assert_raise ArgumentError, fn -> client().recall("group-1", "", "session-1", "q") end

          assert Gralkor.Client.InMemory.recalls() == []
        end
      end

      describe "when memory is added with a group, content and a source description > while the backend acknowledges the add" do
        test "then success is returned" do
          unquote(setup_block).()
          configure_memory_add(:ok)

          assert :ok =
                   client().memory_add(
                     "group-1",
                     "Eli prefers concise",
                     "manual",
                     :conversation
                   )
        end
      end

      describe "when memory is added with a group, content and a source description > if the backend fails" do
        test "then that failure is returned unchanged" do
          unquote(setup_block).()
          configure_memory_add({:error, :extract_failed})

          assert {:error, :extract_failed} =
                   client().memory_add("group-1", "x", nil, :document)
        end
      end

      describe "when memory is added with a group, content and a source description" do
        test "then the write uses implicit-default memory, so a caller neither supplies nor configures an ontology" do
          unquote(setup_block).()
          configure_memory_add(:ok)

          assert :ok =
                   client().memory_add(
                     "group-1",
                     "Eli prefers concise",
                     "manual",
                     :conversation
                   )

          assert [["group-1", "Eli prefers concise", "manual", :conversation]] =
                   Gralkor.Client.InMemory.adds()
        end
      end

      describe "when memory is added with a group, content and a source description > where a source kind is supplied" do
        test "then the call is recorded with that source kind unchanged" do
          unquote(setup_block).()
          configure_memory_add(:ok)

          assert :ok =
                   client().memory_add(
                     "group-1",
                     %{"status" => "approved"},
                     "project record",
                     :structured_record
                   )

          assert [
                   [
                     "group-1",
                     %{"status" => "approved"},
                     "project record",
                     :structured_record
                   ]
                 ] = Gralkor.Client.InMemory.adds()
        end
      end

      describe "when an index rebuild is requested > while the backend acknowledges the rebuild" do
        test "then its status is returned as a success" do
          unquote(setup_block).()
          configure_build_indices({:ok, %{status: "built"}})

          assert {:ok, %{status: "built"}} = client().build_indices()
        end
      end

      describe "when an index rebuild is requested > if the backend fails" do
        test "then that failure is returned unchanged" do
          unquote(setup_block).()
          configure_build_indices({:error, :nope})

          assert {:error, :nope} = client().build_indices()
        end
      end

      describe "when community building is requested for a group > while the backend returns counts" do
        test "then the number of communities and the number of edges are returned as a success" do
          unquote(setup_block).()
          configure_build_communities({:ok, %{communities: 3, edges: 7}})

          assert {:ok, %{communities: 3, edges: 7}} = client().build_communities("group-1")
        end
      end

      describe "when community building is requested for a group > if the backend fails" do
        test "then that failure is returned unchanged" do
          unquote(setup_block).()
          configure_build_communities({:error, :upstream})

          assert {:error, :upstream} = client().build_communities("group-1")
        end
      end
    end
  end
end
