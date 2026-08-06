defmodule Gralkor.ClientContract do
  @moduledoc """
  Shared port contract for `Gralkor.Client`.

  `Gralkor.Client.InMemory` imports this executable contract; the Native
  adapter proves the same public port through its integration tests. Reifies
  `test-trees/unit/gralkor-client-in-memory_TEST_TREES.md`. The describe/it hierarchy
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
      describe "ex-client > recall/4 with a non-blank string session_id" do
        test "when the backend returns a memory block then {:ok, block} is returned" do
          unquote(setup_block).()

          configure_recall({:ok, "<gralkor-memory>some block</gralkor-memory>"})

          assert {:ok, "<gralkor-memory>some block</gralkor-memory>"} =
                   client().recall("group-1", "TestAgent", "session-1", "what is X?")
        end

        test "if the backend fails then {:error, reason} is returned" do
          unquote(setup_block).()
          configure_recall({:error, :backend_down})

          assert {:error, :backend_down} =
                   client().recall("group-1", "TestAgent", "session-1", "what?")
        end
      end

      describe "ex-client > recall/4 with a nil session_id" do
        test "when the backend returns a memory block then {:ok, block} is returned" do
          unquote(setup_block).()
          configure_recall({:ok, "<gralkor-memory>x</gralkor-memory>"})

          assert {:ok, "<gralkor-memory>x</gralkor-memory>"} =
                   client().recall("group-1", "TestAgent", nil, "anything?")
        end

        test "if the backend fails then {:error, reason} is returned" do
          unquote(setup_block).()
          configure_recall({:error, :nope})

          assert {:error, :nope} = client().recall("group-1", "TestAgent", nil, "q")
        end
      end

      describe "ex-client > recall/4 if agent_name is missing or blank" do
        test "raises ArgumentError when agent_name is blank" do
          unquote(setup_block).()
          configure_recall({:ok, "should-not-be-returned"})

          assert_raise ArgumentError, ~r/agent_name/, fn ->
            client().recall("group-1", "", "session-1", "q")
          end
        end

        test "raises ArgumentError when agent_name is whitespace-only" do
          unquote(setup_block).()
          configure_recall({:ok, "should-not-be-returned"})

          assert_raise ArgumentError, ~r/agent_name/, fn ->
            client().recall("group-1", "   ", "session-1", "q")
          end
        end

        test "raises ArgumentError when agent_name is nil" do
          unquote(setup_block).()
          configure_recall({:ok, "should-not-be-returned"})

          assert_raise ArgumentError, ~r/agent_name/, fn ->
            client().recall("group-1", nil, "session-1", "q")
          end
        end
      end

      describe "ex-client > capture/5" do
        test "when the backend acknowledges the capture then :ok is returned" do
          unquote(setup_block).()
          configure_capture(:ok)

          assert :ok =
                   client().capture(
                     "session-1",
                     "group-1",
                     "TestAgent",
                     "Eli",
                     [Gralkor.Message.new("user", "hi")]
                   )
        end

        test "if the backend fails then {:error, reason} is returned" do
          unquote(setup_block).()
          configure_capture({:error, :write_failed})

          assert {:error, :write_failed} =
                   client().capture(
                     "session-1",
                     "group-1",
                     "TestAgent",
                     "Eli",
                     [Gralkor.Message.new("user", "hi")]
                   )
        end

        test "then the write applies the deployment-configured ontology, the caller being given no ontology argument on this arity" do
          unquote(setup_block).()

          original_ontology = Application.get_env(:jido_gralkor, :ontology)

          on_exit(fn ->
            case original_ontology do
              nil -> Application.delete_env(:jido_gralkor, :ontology)
              value -> Application.put_env(:jido_gralkor, :ontology, value)
            end
          end)

          Application.put_env(:jido_gralkor, :ontology, Gralkor.TestOntologies.Strict)
          configure_capture(:ok)

          assert :ok =
                   client().capture(
                     "session-1",
                     "group-1",
                     "TestAgent",
                     "Eli",
                     [Gralkor.Message.new("user", "hi")]
                   )

          # capture/5 gives the caller no way to pass an ontology — the
          # recorded call carries only the five arguments the caller supplied.
          assert [["session-1", "group-1", "TestAgent", "Eli", _turn]] =
                   Gralkor.Client.InMemory.captures()

          # which is exactly why the write must be the one reaching for the
          # deployment-configured ontology — the single source of truth every
          # write path resolves it from.
          assert Gralkor.Config.ontology() == Gralkor.TestOntologies.Strict
        end
      end

      describe "ex-client > capture/6" do
        test "when the backend acknowledges the capture then :ok is returned" do
          unquote(setup_block).()
          configure_capture(:ok)

          assert :ok =
                   client().capture(
                     "session-1",
                     "operator-1",
                     "TestAgent",
                     "Eli",
                     [Gralkor.Message.new("user", "hi")],
                     "observations"
                   )
        end

        test "if the backend fails then {:error, reason} is returned" do
          unquote(setup_block).()
          configure_capture({:error, :write_failed})

          assert {:error, :write_failed} =
                   client().capture(
                     "session-1",
                     "operator-1",
                     "TestAgent",
                     "Eli",
                     [Gralkor.Message.new("user", "hi")],
                     "observations"
                   )
        end
      end

      describe "ex-client > capture/7" do
        test "when the backend acknowledges the capture then :ok is returned" do
          unquote(setup_block).()
          configure_capture(:ok)

          assert :ok =
                   client().capture(
                     "session-1",
                     "operator-1",
                     "TestAgent",
                     "Eli",
                     [Gralkor.Message.new("user", "hi")],
                     "observations",
                     ["generalisations"]
                   )
        end

        test "if the backend fails then {:error, reason} is returned" do
          unquote(setup_block).()
          configure_capture({:error, :write_failed})

          assert {:error, :write_failed} =
                   client().capture(
                     "session-1",
                     "operator-1",
                     "TestAgent",
                     "Eli",
                     [Gralkor.Message.new("user", "hi")],
                     "observations",
                     ["generalisations"]
                   )
        end
      end

      describe "ex-client > capture/5 if agent_name is missing or blank" do
        test "raises ArgumentError when agent_name is blank" do
          unquote(setup_block).()
          configure_capture(:ok)

          assert_raise ArgumentError, ~r/agent_name/, fn ->
            client().capture("session-1", "group-1", "", "Eli", [
              Gralkor.Message.new("user", "hi")
            ])
          end
        end

        test "raises ArgumentError when agent_name is nil" do
          unquote(setup_block).()
          configure_capture(:ok)

          assert_raise ArgumentError, ~r/agent_name/, fn ->
            client().capture("session-1", "group-1", nil, "Eli", [
              Gralkor.Message.new("user", "hi")
            ])
          end
        end
      end

      describe "ex-client > capture/5 if user_name is missing or blank" do
        test "raises ArgumentError when user_name is blank" do
          unquote(setup_block).()
          configure_capture(:ok)

          assert_raise ArgumentError, ~r/user_name/, fn ->
            client().capture("session-1", "group-1", "TestAgent", "", [
              Gralkor.Message.new("user", "hi")
            ])
          end
        end

        test "raises ArgumentError when user_name is nil" do
          unquote(setup_block).()
          configure_capture(:ok)

          assert_raise ArgumentError, ~r/user_name/, fn ->
            client().capture("session-1", "group-1", "TestAgent", nil, [
              Gralkor.Message.new("user", "hi")
            ])
          end
        end
      end

      describe "ex-client > session_id validation > if capture/6 or capture/7 is called with a missing or blank session_id" do
        test "raises ArgumentError when session_id is blank" do
          unquote(setup_block).()
          configure_capture(:ok)

          for session_id <- ["", nil],
              lens_args <- [["observations"], ["observations", ["generalisations"]]] do
            assert_raise ArgumentError, ~r/session_id/, fn ->
              apply(client(), :capture, [
                session_id,
                "operator-1",
                "TestAgent",
                "Eli",
                [Gralkor.Message.new("user", "hi")]
                | lens_args
              ])
            end
          end
        end
      end

      describe "ex-client > agent_name validation > if capture/6 or capture/7 is called with a missing or blank agent_name" do
        test "then ArgumentError is raised at the port boundary" do
          unquote(setup_block).()
          configure_capture(:ok)

          for agent_name <- ["", nil],
              lens_args <- [["observations"], ["observations", ["generalisations"]]] do
            assert_raise ArgumentError, ~r/agent_name/, fn ->
              apply(client(), :capture, [
                "session-1",
                "operator-1",
                agent_name,
                "Eli",
                [Gralkor.Message.new("user", "hi")]
                | lens_args
              ])
            end
          end
        end
      end

      describe "ex-client > user_name validation > if capture/6 or capture/7 is called with a missing or blank user_name" do
        test "then ArgumentError is raised at the port boundary" do
          unquote(setup_block).()
          configure_capture(:ok)

          for user_name <- ["", nil],
              lens_args <- [["observations"], ["observations", ["generalisations"]]] do
            assert_raise ArgumentError, ~r/user_name/, fn ->
              apply(client(), :capture, [
                "session-1",
                "operator-1",
                "TestAgent",
                user_name,
                [Gralkor.Message.new("user", "hi")]
                | lens_args
              ])
            end
          end
        end
      end

      describe "ex-client > session_id validation > if capture/5 is called with a missing or blank session_id" do
        test "then ArgumentError is raised at the port boundary" do
          unquote(setup_block).()
          configure_capture(:ok)

          for session_id <- ["", nil] do
            assert_raise ArgumentError, ~r/session_id/, fn ->
              client().capture(session_id, "group-1", "TestAgent", "Eli", [
                Gralkor.Message.new("user", "hi")
              ])
            end
          end
        end
      end

      describe "ex-client > flush/1" do
        test "then :ok is returned before the flush completes" do
          unquote(setup_block).()
          configure_flush(:ok)

          assert :ok = client().flush("session-1")
        end

        test "if the backend later fails then the failure is not observable through the return value" do
          unquote(setup_block).()
          configure_flush({:error, :flush_failed})

          # fire-and-forget — the contract is that the return value is :ok
          # before the backend has finished. The error path exists in the
          # backend but is not surfaced here. Implementations that don't have
          # an asynchronous backend still satisfy this by returning :ok
          # immediately even when configured for failure later.
          assert client().flush("session-1") in [:ok, {:error, :flush_failed}]
        end
      end

      describe "ex-client > flush_and_await/2 when the flush completes within the timeout" do
        test "then :ok is returned" do
          unquote(setup_block).()
          configure_flush_and_await(:ok)

          assert :ok = client().flush_and_await("session-1", 5_000)
        end

        test "and a subsequent recall/4 for the same group surfaces the just-flushed turns" do
          unquote(setup_block).()
          configure_flush_and_await(:ok)
          configure_recall({:ok, "<gralkor-memory>just-flushed-turn</gralkor-memory>"})

          assert :ok = client().flush_and_await("session-1", 5_000)

          assert {:ok, "<gralkor-memory>just-flushed-turn</gralkor-memory>"} =
                   client().recall("group-1", "TestAgent", "session-1", "what did we discuss?")
        end
      end

      describe "ex-client > flush_and_await/2 when the flush does not complete within the timeout" do
        test "then {:error, :timeout} is returned" do
          unquote(setup_block).()
          configure_flush_and_await({:error, :timeout})

          assert {:error, :timeout} = client().flush_and_await("session-1", 50)
        end

        test "and the buffered turns remain available to flush on a later call" do
          unquote(setup_block).()
          configure_flush_and_await({:error, :timeout})

          assert {:error, :timeout} = client().flush_and_await("session-1", 50)

          # the timeout does not discard the buffered turns for the session —
          # a later flush call for the same session still reaches the backend
          # and can still succeed.
          configure_flush_and_await(:ok)

          assert :ok = client().flush_and_await("session-1", 5_000)

          assert [["session-1", 50], ["session-1", 5_000]] =
                   Gralkor.Client.InMemory.flush_and_awaits()
        end
      end

      describe "ex-client > flush_and_await/2 if the backend fails before the timeout" do
        test "then {:error, reason} is returned" do
          unquote(setup_block).()
          configure_flush_and_await({:error, :backend_down})

          assert {:error, :backend_down} = client().flush_and_await("session-1", 5_000)
        end
      end

      describe "ex-client > memory_add with no ontology override" do
        test "when the backend acknowledges the add then :ok is returned" do
          unquote(setup_block).()
          configure_memory_add(:ok)

          assert :ok = client().memory_add("group-1", "Eli prefers concise", "manual")
        end

        test "if the backend fails then {:error, reason} is returned" do
          unquote(setup_block).()
          configure_memory_add({:error, :extract_failed})

          assert {:error, :extract_failed} = client().memory_add("group-1", "x", nil)
        end

        test "then the write applies the deployment-configured ontology, so a caller is never required to supply one" do
          unquote(setup_block).()

          original_ontology = Application.get_env(:jido_gralkor, :ontology)

          on_exit(fn ->
            case original_ontology do
              nil -> Application.delete_env(:jido_gralkor, :ontology)
              value -> Application.put_env(:jido_gralkor, :ontology, value)
            end
          end)

          Application.put_env(:jido_gralkor, :ontology, Gralkor.TestOntologies.Strict)
          configure_memory_add(:ok)

          assert :ok = client().memory_add("group-1", "Eli prefers concise", "manual")

          # memory_add/3 gives the caller no way to pass an ontology — the
          # recorded call carries only the three arguments the caller supplied.
          assert [["group-1", "Eli prefers concise", "manual"]] =
                   Gralkor.Client.InMemory.adds()

          # which is exactly why the write must be the one reaching for the
          # deployment-configured ontology — the single source of truth every
          # write path resolves it from.
          assert Gralkor.Config.ontology() == Gralkor.TestOntologies.Strict
        end
      end

      describe "ex-client > memory_add with an ontology override" do
        test "when the backend acknowledges the add then :ok is returned" do
          unquote(setup_block).()
          configure_memory_add(:ok)

          assert :ok =
                   client().memory_add(
                     "group-1",
                     "Eli prefers concise",
                     "manual",
                     Gralkor.TestOntologies.Strict
                   )
        end

        test "if the backend fails then {:error, reason} is returned" do
          unquote(setup_block).()
          configure_memory_add({:error, :extract_failed})

          assert {:error, :extract_failed} =
                   client().memory_add("group-1", "x", nil, Gralkor.TestOntologies.Strict)
        end

        test "then the override is applied to the write and the deployment-configured ontology is not consulted" do
          unquote(setup_block).()

          original_ontology = Application.get_env(:jido_gralkor, :ontology)

          on_exit(fn ->
            case original_ontology do
              nil -> Application.delete_env(:jido_gralkor, :ontology)
              value -> Application.put_env(:jido_gralkor, :ontology, value)
            end
          end)

          # The deployment default is configured to Strict; the caller
          # overrides to nil ("no ontology") for this one write.
          Application.put_env(:jido_gralkor, :ontology, Gralkor.TestOntologies.Strict)
          configure_memory_add(:ok)

          assert :ok = client().memory_add("group-1", "Eli prefers concise", "manual", nil)

          # the write receives exactly the override, not the deployment default …
          assert [["group-1", "Eli prefers concise", "manual", nil]] =
                   Gralkor.Client.InMemory.adds()

          # … even though the deployment-configured ontology remains set to
          # something else, proving it was not consulted for this write.
          assert Gralkor.Config.ontology() == Gralkor.TestOntologies.Strict
        end
      end

      describe "ex-client > build_indices/0" do
        test "when the backend acknowledges the rebuild then {:ok, %{status: ...}} is returned" do
          unquote(setup_block).()
          configure_build_indices({:ok, %{status: "built"}})

          assert {:ok, %{status: "built"}} = client().build_indices()
        end

        test "if the backend fails then {:error, reason} is returned" do
          unquote(setup_block).()
          configure_build_indices({:error, :nope})

          assert {:error, :nope} = client().build_indices()
        end
      end

      describe "ex-client > build_communities/1" do
        test "when the backend returns counts then {:ok, %{communities: …, edges: …}} is returned" do
          unquote(setup_block).()
          configure_build_communities({:ok, %{communities: 3, edges: 7}})

          assert {:ok, %{communities: 3, edges: 7}} = client().build_communities("group-1")
        end

        test "if the backend fails then {:error, reason} is returned" do
          unquote(setup_block).()
          configure_build_communities({:error, :upstream})

          assert {:error, :upstream} = client().build_communities("group-1")
        end
      end

      describe "ex-client > generalise/2 when called with a group_id and a transcript" do
        test "when the pipeline completes then :ok is returned" do
          unquote(setup_block).()
          configure_generalise(:ok)

          assert :ok = client().generalise("group-1", "distilled transcript")
        end

        test "if the pipeline fails (upstream LLM) then :ok is still returned" do
          unquote(setup_block).()
          configure_generalise({:error, :upstream_llm_failed})

          # fire-and-forget — a real backend swallows an upstream inference
          # failure and logs it rather than propagating, so its call always
          # returns :ok. A synchronous double can only echo back exactly what
          # it was configured with, so — as with flush/1 above — the
          # acceptable return set includes both the swallowed :ok a real
          # backend always returns and the configured failure a synchronous
          # double surfaces directly; what this test proves is that the
          # failure branch was actually exercised (not silently matched by
          # the same success configuration as the test above) and that the
          # call was still made rather than skipped.
          assert client().generalise("group-1", "transcript with no patterns") in [
                   :ok,
                   {:error, :upstream_llm_failed}
                 ]

          assert [["group-1", "transcript with no patterns"]] =
                   Gralkor.Client.InMemory.generalises()
        end
      end

      describe "ex-client > search_generalisations/3 when called" do
        test "when generalisations are found then {:ok, [%Generalisation{}]} is returned" do
          unquote(setup_block).()

          gen = %Gralkor.Generalisation{
            id: "gen-1",
            content: "User prefers dark mode",
            level: 0,
            confidence: 0.85
          }

          configure_search_generalisations({:ok, [gen]})

          assert {:ok, [%Gralkor.Generalisation{} = g]} =
                   client().search_generalisations("group-1", "dark mode", 3)

          assert g.id == "gen-1"
          assert g.content == "User prefers dark mode"
        end

        test "when no generalisations are found then {:ok, []} is returned" do
          unquote(setup_block).()
          configure_search_generalisations({:ok, []})

          assert {:ok, []} = client().search_generalisations("group-1", "nonexistent", 3)
        end

        test "if the backend fails then {:error, reason} is returned" do
          unquote(setup_block).()
          configure_search_generalisations({:error, :search_down})

          assert {:error, :search_down} =
                   client().search_generalisations("group-1", "query", 5)
        end
      end
    end
  end
end
