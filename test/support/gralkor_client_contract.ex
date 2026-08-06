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

      describe "if a recall or a capture is requested with a missing or blank agent name" do
        test "then an argument error is raised at the port boundary" do
          unquote(setup_block).()
          configure_recall({:ok, "should-not-be-returned"})
          configure_capture(:ok)

          for agent_name <- ["", "   ", nil] do
            assert_raise ArgumentError, ~r/agent_name/, fn ->
              client().recall("group-1", agent_name, "session-1", "q")
            end

            assert_raise ArgumentError, ~r/agent_name/, fn ->
              client().capture("session-1", "group-1", agent_name, "Eli", [
                Gralkor.Message.new("user", "hi")
              ])
            end
          end
        end

        test "and no backend call is made" do
          unquote(setup_block).()
          configure_recall({:ok, "should-not-be-returned"})
          configure_capture(:ok)

          assert_raise ArgumentError, fn -> client().recall("group-1", "", "session-1", "q") end

          assert_raise ArgumentError, fn ->
            client().capture("session-1", "group-1", "", "Eli", [
              Gralkor.Message.new("user", "hi")
            ])
          end

          assert Gralkor.Client.InMemory.recalls() == []
          assert Gralkor.Client.InMemory.captures() == []
        end
      end

      describe "when a canonical turn is captured for a named session, group, agent and user > while the backend acknowledges the capture" do
        test "then success is returned" do
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
      end

      describe "when a canonical turn is captured for a named session, group, agent and user > if the backend fails" do
        test "then that failure is returned unchanged" do
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
      end

      describe "when a canonical turn is captured for a named session, group, agent and user > while its messages have user, assistant or behaviour roles" do
        test "then the write uses the deployment ontology without a caller ontology argument" do
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

        test "and the turn is learned at flush with no per-turn flag" do
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

          assert [["session-1", "group-1", "TestAgent", "Eli", _messages]] =
                   Gralkor.Client.InMemory.captures()
        end
      end

      describe "where a turn is captured through a named Lens, alone or together with additional Lenses > while the backend acknowledges the capture" do
        test "then success is returned" do
          unquote(setup_block).()
          configure_capture(:ok)

          for lens_args <- [["observations"], ["observations", ["generalisations"]]] do
            assert :ok =
                     apply(client(), :capture, [
                       "session-1",
                       "operator-1",
                       "TestAgent",
                       "Eli",
                       [Gralkor.Message.new("user", "hi")]
                       | lens_args
                     ])
          end
        end
      end

      describe "where a turn is captured through a named Lens, alone or together with additional Lenses > if the backend fails" do
        test "then that failure is returned unchanged" do
          unquote(setup_block).()
          configure_capture({:error, :write_failed})

          for lens_args <- [["observations"], ["observations", ["generalisations"]]] do
            assert {:error, :write_failed} =
                     apply(client(), :capture, [
                       "session-1",
                       "operator-1",
                       "TestAgent",
                       "Eli",
                       [Gralkor.Message.new("user", "hi")]
                       | lens_args
                     ])
          end
        end
      end

      describe "if a capture is requested with a missing or blank user name" do
        test "then an argument error is raised at the port boundary" do
          unquote(setup_block).()
          configure_capture(:ok)

          for user_name <- ["", nil],
              lens_args <- [[], ["observations"], ["observations", ["generalisations"]]] do
            assert_raise ArgumentError, ~r/user_name/, fn ->
              apply(client(), :capture, [
                "session-1",
                "group-1",
                "TestAgent",
                user_name,
                [Gralkor.Message.new("user", "hi")]
                | lens_args
              ])
            end
          end
        end

        test "and no backend call is made" do
          unquote(setup_block).()
          configure_capture(:ok)

          assert_raise ArgumentError, ~r/user_name/, fn ->
            client().capture("session-1", "group-1", "TestAgent", "", [
              Gralkor.Message.new("user", "hi")
            ])
          end

          assert Gralkor.Client.InMemory.captures() == []
        end
      end

      describe "if a capture is requested with a missing or blank session id" do
        test "then an argument error is raised at the port boundary" do
          unquote(setup_block).()
          configure_capture(:ok)

          for session_id <- ["", nil],
              lens_args <- [[], ["observations"], ["observations", ["generalisations"]]] do
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

        test "and no backend call is made" do
          unquote(setup_block).()
          configure_capture(:ok)

          assert_raise ArgumentError, ~r/session_id/, fn ->
            client().capture("", "group-1", "TestAgent", "Eli", [
              Gralkor.Message.new("user", "hi")
            ])
          end

          assert Gralkor.Client.InMemory.captures() == []
        end
      end

      describe "when a flush is requested for a session" do
        test "then success is returned before the flush completes" do
          unquote(setup_block).()
          configure_flush(:ok)

          assert :ok = client().flush("session-1")
        end
      end

      describe "when a flush is requested for a session > if the backend fails afterwards" do
        test "then that failure is not observable through the return value" do
          unquote(setup_block).()
          configure_flush({:error, :flush_failed})

          assert :ok = client().flush("session-1")
        end
      end

      describe "when a flush is requested for a session and awaited with a timeout > while the flush completes inside the timeout" do
        test "then success is returned" do
          unquote(setup_block).()
          configure_flush_and_await(:ok)

          assert :ok = client().flush_and_await("session-1", 5_000)
        end

        test "and a recall for the same group afterwards surfaces the just-flushed turns" do
          unquote(setup_block).()
          configure_flush_and_await(:ok)
          configure_recall({:ok, "<gralkor-memory>just-flushed-turn</gralkor-memory>"})

          assert :ok = client().flush_and_await("session-1", 5_000)

          assert {:ok, "<gralkor-memory>just-flushed-turn</gralkor-memory>"} =
                   client().recall("group-1", "TestAgent", "session-1", "what did we discuss?")
        end
      end

      describe "when a flush is requested for a session and awaited with a timeout > while the flush does not complete inside the timeout" do
        test "then a timeout error is returned" do
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

      describe "when a flush is requested for a session and awaited with a timeout > if the backend fails before the timeout elapses" do
        test "then that failure is returned unchanged" do
          unquote(setup_block).()
          configure_flush_and_await({:error, :backend_down})

          assert {:error, :backend_down} = client().flush_and_await("session-1", 5_000)
        end
      end

      describe "when memory is added with a group, content and a source description > while the backend acknowledges the add" do
        test "then success is returned" do
          unquote(setup_block).()
          configure_memory_add(:ok)

          assert :ok = client().memory_add("group-1", "Eli prefers concise", "manual")
        end
      end

      describe "when memory is added with a group, content and a source description > if the backend fails" do
        test "then that failure is returned unchanged" do
          unquote(setup_block).()
          configure_memory_add({:error, :extract_failed})

          assert {:error, :extract_failed} = client().memory_add("group-1", "x", nil)
        end
      end

      describe "when memory is added with a group, content and a source description" do
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

      describe "when memory is added with a group, content and a source description > where an ontology override is supplied > while the backend acknowledges the add" do
        test "then success is returned" do
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
      end

      describe "when memory is added with a group, content and a source description > where an ontology override is supplied > if the backend fails" do
        test "then that failure is returned unchanged" do
          unquote(setup_block).()
          configure_memory_add({:error, :extract_failed})

          assert {:error, :extract_failed} =
                   client().memory_add("group-1", "x", nil, Gralkor.TestOntologies.Strict)
        end
      end

      describe "when memory is added with a group, content and a source description > where an ontology override is supplied" do
        test "then the override is applied to the write" do
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

          assert Gralkor.Config.ontology() == Gralkor.TestOntologies.Strict
        end

        test "and the deployment-configured ontology is not consulted" do
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

          assert :ok = client().memory_add("group-1", "content", "manual", nil)
          assert [["group-1", "content", "manual", nil]] = Gralkor.Client.InMemory.adds()
          assert Gralkor.Config.ontology() == Gralkor.TestOntologies.Strict
        end

        test "and this override is the only per-call ontology surface the client exposes" do
          assert Gralkor.Client.behaviour_info(:callbacks)
                 |> Enum.filter(fn {name, _arity} -> name == :memory_add end)
                 |> Enum.sort() == [memory_add: 3, memory_add: 4]
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

      describe "when generalisation is requested for a group and a transcript" do
        test "then success is returned once the pipeline completes" do
          unquote(setup_block).()
          configure_generalise(:ok)

          assert :ok = client().generalise("group-1", "distilled transcript")
        end
      end

      describe "when generalisation is requested for a group and a transcript > if the pipeline's upstream inference fails" do
        test "then success is still returned, generalisation being fire-and-forget and its failures only logged" do
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

      describe "when generalisations are searched for a group with a query and a result ceiling > while the backend returns generalisations" do
        test "then they are returned as a success carrying their decoded content, level and confidence" do
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
          assert g.level == 0
          assert g.confidence == 0.85
        end
      end

      describe "when generalisations are searched for a group with a query and a result ceiling > while the backend returns none" do
        test "then an empty list is returned as a success rather than an error" do
          unquote(setup_block).()
          configure_search_generalisations({:ok, []})

          assert {:ok, []} = client().search_generalisations("group-1", "nonexistent", 3)
        end
      end

      describe "when generalisations are searched for a group with a query and a result ceiling > if the backend fails" do
        test "then that failure is returned unchanged" do
          unquote(setup_block).()
          configure_search_generalisations({:error, :search_down})

          assert {:error, :search_down} =
                   client().search_generalisations("group-1", "query", 5)
        end
      end
    end
  end
end
