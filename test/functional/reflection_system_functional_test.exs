defmodule Gralkor.ReflectionSystemFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  alias Gralkor.Client
  alias Gralkor.Reflection.Runner
  alias Gralkor.Search
  alias JidoGralkor.Runtime

  defmodule AsyncConsumerAgent do
    use Jido.Agent,
      name: "reflection_async_consumer",
      default_plugins: false,
      plugins: [
        {JidoGralkor.Plugin,
         %{
           agent_name: "Reflection Async Consumer",
           runtime_config: %{destinations: [], lenses: [], reflections: []}
         }}
      ]
  end

  defmodule ReflectionProbe do
    use Jido.Action,
      name: "reflection_probe",
      description: "Record Reflection evidence.",
      schema: Zoi.object(%{value: Zoi.string()})

    def run(%{value: value}, context) do
      send(
        context.test_pid,
        {:reflection_tool, value, context.operator_id, Map.get(context, :tenant)}
      )

      {:ok, %{evidence: value}}
    end
  end

  defmodule RequestProbe do
    @behaviour Jido.AI.Reasoning.ReAct.RequestTransformer

    def transform_request(request, _state, _config, context) do
      send(context.test_pid, {:model_request, request.messages})
      {:ok, %{}}
    end
  end

  defmodule ReflectionOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open
  end

  defmodule StepProbe do
    use Jido.Action,
      name: "step_probe",
      description: "Record a step's tool evidence.",
      schema: Zoi.object(%{value: Zoi.string()})

    def run(%{value: value}, context) do
      send(context.test_pid, {:step_tool, value, context})
      {:ok, %{evidence: value}}
    end
  end

  defmodule HeldTool do
    use Jido.Action,
      name: "held_tool",
      description: "Wait until the test releases it.",
      schema: Zoi.object(%{value: Zoi.string()})

    def run(%{value: value}, context) do
      send(context.test_pid, {:tool_running, value, self()})

      receive do
        :release -> {:ok, %{released: value}}
      end
    end
  end

  defmodule ScriptedModel do
    @usage %{"input_tokens" => 3, "output_tokens" => 4, "total_tokens" => 7}

    def start_link(test_pid, replies) do
      Agent.start_link(fn -> %{test_pid: test_pid, replies: replies, count: 0} end,
        name: __MODULE__
      )
    end

    def replace(test_pid, replies) do
      Agent.update(__MODULE__, fn _ -> %{test_pid: test_pid, replies: replies, count: 0} end)
    end

    def run(request) do
      body = request.body |> IO.iodata_to_binary() |> Jason.decode!()
      {test_pid, reply, count} = Agent.get_and_update(__MODULE__, &next/1)
      send(test_pid, {:scripted_model_request, body})
      respond(request, reply, count)
    end

    defp next(%{replies: [{:always, reply}]} = state),
      do: {{state.test_pid, reply, state.count}, %{state | count: state.count + 1}}

    defp next(%{replies: [reply | rest]} = state),
      do: {{state.test_pid, reply, state.count}, %{state | replies: rest, count: state.count + 1}}

    defp respond(request, :hold, _count) do
      receive do
        :never_sent -> {request, Req.Response.new(status: 500)}
      end
    end

    defp respond(request, {:fail, status}, _count) do
      {request,
       Req.Response.new(
         status: status,
         headers: [{"content-type", "application/json"}],
         body:
           Jason.encode!(%{
             "error" => %{"message" => "scripted provider failure", "type" => "invalid_request"}
           })
       )}
    end

    defp respond(request, {:answer, text}, _count) do
      ok(request, [
        %{
          "type" => "message",
          "id" => "message-1",
          "role" => "assistant",
          "status" => "completed",
          "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}]
        }
      ])
    end

    defp respond(request, {:tool_calls, calls}, count) do
      ok(
        request,
        calls
        |> Enum.with_index(1)
        |> Enum.map(fn {{name, arguments}, index} ->
          %{
            "type" => "function_call",
            "id" => "fc-#{count}-#{index}",
            "call_id" => "call-#{count}-#{index}",
            "name" => name,
            "arguments" => Jason.encode!(arguments),
            "status" => "completed"
          }
        end)
      )
    end

    defp ok(request, output) do
      {request,
       Req.Response.new(
         status: 200,
         headers: [{"content-type", "application/json"}],
         body:
           Jason.encode!(%{
             "id" => "response-1",
             "object" => "response",
             "model" => "gpt-5",
             "status" => "completed",
             "output" => output,
             "usage" => @usage
           })
       )}
    end
  end

  defmodule FailingReflectionStorage do
    def put_artefact(_, _, _, _), do: {:error, :destination_unavailable}
    def get_artefact(_, _, _, _), do: {:error, :not_found}
  end

  defmodule OutputProbeStorage do
    @behaviour Gralkor.Destination.Storage

    @impl true
    def search(_, _, _, _), do: {:ok, %{facts: [], nodes: [], episodes: []}}

    @impl true
    def put_artefact(output, reflection_name, operator_id, artefact) do
      send(
        Application.fetch_env!(:jido_gralkor, :reflection_output_test_pid),
        {:destination_output_delivered, output, reflection_name, operator_id, artefact}
      )

      :ok
    end

    @impl true
    def get_artefact(_, _, _, _), do: {:error, :not_found}
  end

  setup do
    start_supervised!(Gralkor.Destination.Storage.InMemory)
    start_supervised!(Gralkor.Lens.Storage.InMemory)

    previous =
      for key <- [
            :destinations,
            :destination_storage,
            :lenses,
            :lens_storage,
            :reflections,
            :reflection_storage,
            :reflection_output_test_pid
          ],
          into: %{} do
        {key, Application.get_env(:jido_gralkor, key)}
      end

    Application.put_env(:jido_gralkor, :destinations, [
      [name: "reflection-test"],
      [name: "observations"],
      [name: "decisions"]
    ])

    Application.put_env(
      :jido_gralkor,
      :destination_storage,
      Gralkor.Destination.Storage.InMemory
    )

    Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)
    Application.put_env(:jido_gralkor, :reflection_output_test_pid, self())

    on_exit(fn -> Enum.each(previous, fn {key, value} -> restore_env(key, value) end) end)
    :ok
  end

  describe "when an agent runtime validates Reflection declarations > while all declarations satisfy their naming, Chain-of-Thought, and Destination-output requirements" do
    test "then validation succeeds" do
      definition = valid_definition()
      reflection = resolve_reflection(definition)

      assert reflection.name == "generalisation"

      assert %Gralkor.Reflection.ChainOfThought{
               steps: [%{label: "gather"}, %{label: "synthesise"}]
             } =
               reflection.chain_of_thought

      assert [
               %{
                 kind: :destination,
                 destination: %Gralkor.Destination{name: "personal"},
                 ontology: Gralkor.DefaultOntology
               }
             ] =
               reflection.outputs
    end
  end

  describe "when an agent runtime validates Reflection declarations > if the configured Reflection collection is not a list" do
    test "then validation fails identifying the configured value" do
      assert {:error, {:invalid_collection, :reflections, :invalid_collection}} =
               validate_reflections(:invalid_collection)
    end
  end

  describe "when an agent runtime validates Reflection declarations > if a Reflection's `outputs` value is not a list" do
    test "then validation fails identifying that Reflection and outputs value" do
      definition = valid_definition(outputs: :invalid)

      assert {:error, {:invalid_reflection_outputs, "generalisation", :invalid}} =
               validate_reflections([definition])
    end
  end

  describe "when an agent runtime validates Reflection declarations > if a Reflection declares no Destination output" do
    test "then validation fails identifying that Reflection and missing Destination output" do
      definition = valid_definition(outputs: [])

      assert {:error, {:missing_destination_output, "generalisation"}} =
               validate_reflections([definition])
    end
  end

  describe "when an agent runtime validates Reflection declarations > if a Reflection declares more than one Destination output" do
    test "then validation fails identifying that Reflection and duplicate Destination output kind" do
      output = [kind: :destination, destination: "personal"]
      definition = valid_definition(outputs: [output, output])

      assert {:error, {:duplicate_destination_output, "generalisation"}} =
               validate_reflections([definition])
    end
  end

  describe "when an agent runtime validates Reflection declarations > if a Reflection declares an unsupported output kind" do
    test "then validation fails identifying that Reflection and output kind" do
      outputs = [
        [kind: :destination, destination: "personal"],
        [kind: :return]
      ]

      assert {:error, {:unsupported_reflection_output, "generalisation", :return}} =
               validate_reflections([valid_definition(outputs: outputs)])
    end
  end

  describe "when an agent runtime validates Reflection declarations > if a Reflection name is blank" do
    test "then validation fails identifying the blank name" do
      assert {:error, {:blank_definition_name, :reflections, " "}} =
               validate_reflections([valid_definition(name: " ")])
    end
  end

  describe "when an agent runtime validates Reflection declarations > if a Reflection name contains the reserved provenance delimiter ` [lens: `" do
    test "then validation fails identifying the Reflection and reserved provenance syntax" do
      name = "review [lens: observations]"

      assert {:error, {:reserved_provenance_syntax, :reflections, ^name, " [lens: "}} =
               validate_reflections([valid_definition(name: name)])
    end
  end

  describe "when an agent runtime validates Reflection declarations > if Reflection names are duplicated" do
    test "then validation fails identifying the duplicate name" do
      definition = valid_definition()

      assert {:error, {:duplicate_definition_name, :reflections, "generalisation"}} =
               validate_reflections([definition, definition])
    end
  end

  describe "when an agent runtime validates Reflection declarations > if a Reflection has no Chain of Thought" do
    test "then validation fails identifying that Reflection" do
      definition = valid_definition() |> Keyword.delete(:chain_of_thought)

      assert {:error, {:missing_chain_of_thought, "generalisation"}} =
               validate_reflections([definition])
    end
  end

  describe "when an agent runtime validates Reflection declarations > if a Reflection's Chain of Thought is not structured configuration" do
    test "then validation fails identifying that Reflection and configured value" do
      assert {:error, {:invalid_chain_of_thought, "generalisation", "external-definition"}} =
               validate_reflections([valid_definition(chain_of_thought: "external-definition")])
    end
  end

  describe "when an agent runtime validates Reflection declarations > if a Chain of Thought has no steps" do
    test "then validation fails identifying that Reflection and Chain of Thought" do
      assert {:error, {:invalid_chain_of_thought, "generalisation", :missing_steps}} =
               validate_reflections([valid_definition(chain_of_thought: %{steps: []})])
    end
  end

  describe "when an agent runtime validates Reflection declarations > if a Chain of Thought step has no non-blank label" do
    test "then validation fails identifying that Reflection and step" do
      cot = %{steps: [%{label: " ", directions: "Think.", output: %{"result" => "string"}}]}

      assert {:error, {:invalid_chain_of_thought, "generalisation", {:invalid_step_label, " "}}} =
               validate_reflections([valid_definition(chain_of_thought: cot)])
    end
  end

  describe "when an agent runtime validates Reflection declarations > if a Chain of Thought step has no natural-language directions" do
    test "then validation fails identifying that Reflection and step" do
      cot = %{steps: [%{label: "think", output: %{"result" => "string"}}]}

      assert {:error,
              {:invalid_chain_of_thought, "generalisation", {:invalid_step_directions, "think"}}} =
               validate_reflections([valid_definition(chain_of_thought: cot)])
    end
  end

  describe "when an agent runtime validates Reflection declarations > if a Chain of Thought step has no structured-output declaration" do
    test "then validation fails identifying that Reflection and step" do
      cot = %{steps: [%{label: "think", directions: "Think."}]}

      assert {:error,
              {:invalid_chain_of_thought, "generalisation", {:invalid_step_output, "think"}}} =
               validate_reflections([valid_definition(chain_of_thought: cot)])
    end
  end

  describe "when an agent runtime validates Reflection declarations > if a Chain of Thought step is not a map" do
    test "then validation fails identifying that Reflection and step" do
      assert {:error,
              {:invalid_chain_of_thought, "generalisation", {:invalid_step, "not-a-step"}}} =
               validate_reflections([
                 valid_definition(chain_of_thought: %{steps: ["not-a-step"]})
               ])
    end
  end

  describe "when an agent runtime validates Reflection declarations > if a Chain of Thought step declares an unsupported structured-output type" do
    test "then validation fails identifying that Reflection, step, and type" do
      cot = %{steps: [%{label: "think", directions: "Think.", output: %{"result" => "mystery"}}]}

      assert {:error,
              {:invalid_chain_of_thought, "generalisation",
               {:invalid_output_type, "think", "mystery"}}} =
               validate_reflections([valid_definition(chain_of_thought: cot)])
    end
  end

  describe "when an agent runtime validates Reflection declarations > if a Chain of Thought step declares an output name holding a brace" do
    test "then validation fails identifying that Reflection, step, and output name" do
      for name <- ["a{b", "cfg}", "{{facts}}"] do
        cot = %{steps: [%{label: "think", directions: "Think.", output: %{name => "string"}}]}

        assert {:error,
                {:invalid_chain_of_thought, "generalisation",
                 {:invalid_output_name, "think", ^name}}} =
                 validate_reflections([valid_definition(chain_of_thought: cot)])
      end
    end
  end

  describe "when an agent runtime validates Reflection declarations > if an output name is declared by more than one step" do
    test "then validation fails identifying that Reflection, output name, and steps" do
      cot = %{
        steps: [
          %{label: "one", directions: "First.", output: %{"result" => "string"}},
          %{label: "two", directions: "Second.", output: %{"result" => "string"}}
        ]
      }

      assert {:error,
              {:invalid_chain_of_thought, "generalisation",
               {:duplicate_output, "result", "one", "two"}}} =
               validate_reflections([valid_definition(chain_of_thought: cot)])
    end
  end

  describe "when an agent runtime validates Reflection declarations > if an interpolation references an output not declared by an earlier step" do
    test "then validation fails identifying that Reflection, step, and interpolation" do
      cot = %{
        steps: [
          %{label: "one", directions: "Use {{later}}.", output: %{"first" => "string"}},
          %{label: "two", directions: "Later.", output: %{"later" => "string"}}
        ]
      }

      assert {:error,
              {:invalid_chain_of_thought, "generalisation",
               {:unknown_interpolation, "later", "one"}}} =
               validate_reflections([valid_definition(chain_of_thought: cot)])
    end

    test "and an interpolation is identified whatever characters other than braces it holds" do
      cot = %{
        steps: [
          %{label: "one", directions: "List.", output: %{"blocked tasks" => "string"}},
          %{label: "two", directions: "Use {{ blocked  tasks? }}.", output: %{"done" => "string"}}
        ]
      }

      assert {:error,
              {:invalid_chain_of_thought, "generalisation",
               {:unknown_interpolation, "blocked  tasks?", "two"}}} =
               validate_reflections([valid_definition(chain_of_thought: cot)])

      known = put_in(cot, [:steps, Access.at(1), :directions], "Use {{ blocked tasks }}.")
      assert :ok = validate_reflections([valid_definition(chain_of_thought: known)])
    end

    test "and double braces whose text reaches another brace before closing double braces are not an interpolation" do
      cot = %{
        steps: [
          %{
            label: "one",
            directions: "For {{Ana (ana@example.com). Use {{later}}.",
            output: %{"first" => "string"}
          },
          %{label: "two", directions: "Later.", output: %{"later" => "string"}}
        ]
      }

      assert {:error,
              {:invalid_chain_of_thought, "generalisation",
               {:unknown_interpolation, "later", "one"}}} =
               validate_reflections([valid_definition(chain_of_thought: cot)])
    end
  end

  describe "when an agent runtime validates Reflection declarations > if a Destination output has no Destination name" do
    test "then validation fails identifying that Reflection and missing Destination" do
      definition = valid_definition(outputs: [[kind: :destination]])

      assert {:error, {:missing_reflection_destination, "generalisation", nil}} =
               validate_reflections([definition])
    end
  end

  describe "when an agent runtime validates Reflection declarations > if a Destination output references an unknown Destination" do
    test "then validation fails identifying that Reflection and Destination" do
      assert {:error, {:unknown_destination, :reflections, "generalisation", "missing"}} =
               validate_reflections([
                 valid_definition(outputs: [[kind: :destination, destination: "missing"]])
               ])
    end
  end

  describe "when an agent runtime validates Reflection declarations > if a Destination output declares an invalid ontology" do
    test "then validation fails identifying that Reflection and ontology" do
      assert {:error, {:invalid_reflection_ontology, "generalisation", String}} =
               validate_reflections([
                 valid_definition(
                   outputs: [
                     [kind: :destination, destination: "personal", ontology: String]
                   ]
                 )
               ])
    end
  end

  describe "when an agent runtime validates Reflection declarations > if a Reflection name contains the reserved direct-writer delimiter" do
    test "then validation fails identifying the Reflection and reserved provenance syntax" do
      assert {:error,
              {:reserved_provenance_syntax, :reflections, "review [gralkor: direct]",
               " [gralkor: "}} =
               Runtime.validate(%{
                 destinations: [],
                 lenses: [],
                 reflections: [valid_definition(name: "review [gralkor: direct]")]
               })
    end
  end

  describe "where an application-defined Destination output omits its ontology" do
    test "then the output selects generic extraction for a runtime-delivered artefact" do
      reflection = resolve_reflection(valid_definition())
      assert destination_output(reflection).ontology == Gralkor.DefaultOntology
    end
  end

  describe "where an application-defined Destination output declares an application ontology" do
    test "then the output selects that ontology for a runtime-delivered artefact" do
      reflection =
        resolve_reflection(
          valid_definition(
            outputs: [
              [
                kind: :destination,
                destination: "observations",
                ontology: ReflectionOntology
              ]
            ]
          )
        )

      assert destination_output(reflection).ontology == ReflectionOntology
    end
  end

  describe "when a consumer Reflection is installed in an agent's runtime configuration" do
    test "then its inline steps become the Reflection's Chain of Thought" do
      definition = [
        name: "inline-review",
        outputs: [[kind: :destination, destination: "personal"]],
        chain_of_thought: %{
          steps: [
            %{
              label: "review",
              directions: "Review the supplied evidence.",
              output: %{"summary" => "string"}
            }
          ]
        }
      ]

      assert %Gralkor.Reflection{
               name: "inline-review",
               chain_of_thought: %Gralkor.Reflection.ChainOfThought{
                 steps: [
                   %Gralkor.Reflection.ChainOfThought.Step{
                     label: "review",
                     directions: "Review the supplied evidence.",
                     output: %{"summary" => "string"}
                   }
                 ]
               }
             } = resolve_reflection(definition)
    end
  end

  describe "when a Reflection Runner is invoked" do
    test "then its ordered Chain of Thought runner starts its first step for the supplied operator and invocation",
         context do
      parent = self()

      inference = fn request ->
        send(parent, {:first, request.operator_id, request.invocation_id, request.step.label})
        output_for(request)
      end

      assert {:ok, _} = Runner.run(reflection(context), invocation(), inference: inference)
      assert_receive {:first, "operator-one", "ingestion-1", "gather"}
    end

    test "and makes the consumer-supplied invocation context available to every step", context do
      requests = run_and_collect_requests(reflection(context), invocation())

      assert Enum.all?(requests, fn request ->
               request.invocation_context == %{source: "direct-invocation"}
             end)
    end
  end

  describe "when a Reflection Runner is invoked > where the invocation supplies ingested representations" do
    test "then every representation is available with its identifier, Lens identity, content, and storage result",
         context do
      parent = self()

      inference = fn request ->
        send(parent, {:available, request.representations})
        output_for(request)
      end

      assert {:ok, _} = Runner.run(reflection(context), invocation(), inference: inference)

      assert_receive {:available, representations}

      assert representations == [
               %{
                 id: "representation-one",
                 lens: "observations",
                 content: "fact one",
                 result: :ok
               },
               %{
                 id: "representation-two",
                 lens: "decisions",
                 content: "fact two",
                 result: :ok
               }
             ]
    end
  end

  describe "when a Reflection Runner is invoked > while the initial step prompt exceeds 100,000 characters" do
    test "then the configured model receives the complete directions, representations, and output contract" do
      content = String.duplicate("retained source ", 10_000)
      representations = [%{id: "source-one", lens: "observations", content: content, result: :ok}]

      schema = %{"answer" => "string"}

      register_step("Inspect all evidence.", representations, schema, [
        answer_turn("ready")
      ])

      request = %{
        directions: "Inspect all evidence.",
        representations: representations,
        output_schema: schema,
        operator_id: "operator-one",
        tools: [],
        tool_context: %{test_pid: self()}
      }

      assert {:ok, %{output: %{"answer" => "ready"}}} = Runner.default_inference(request)
    end

    test "and valid model output completes the Reflection without a local prompt-length rejection" do
      directions = String.duplicate("Evidence. ", 20_000)
      schema = %{"answer" => "string"}

      reflection = %Gralkor.Reflection{
        name: "large-input",
        outputs: [],
        chain_of_thought: %Gralkor.Reflection.ChainOfThought{
          steps: [
            %Gralkor.Reflection.ChainOfThought.Step{
              label: "inspect",
              directions: directions,
              output: schema
            }
          ]
        }
      }

      prompt = expected_step_prompt(directions, [], schema)

      Jido.AI.Test.ReActScript.new(%{
        user: prompt,
        turns: [%{type: :answer, text: ~s({"answer":"complete"})}]
      })
      |> Jido.AI.Test.ReActScript.register()

      on_exit(fn -> Jido.AI.Test.ReActScript.clear_current_owner() end)

      assert {:ok, %Gralkor.Artefact{payload: %{"answer" => "complete"}}} =
               Runner.run(reflection, %{
                 id: "large-input",
                 operator_id: "operator-one",
                 representations: []
               })
    end
  end

  describe "when a Reflection Runner is invoked > if the model request fails" do
    test "then the Reflection fails identifying its name, current step, and provider failure" do
      {reflection, invocation} =
        scripted_reflection([%{type: :fail, reason: :provider_unavailable}])

      assert {:error,
              %{reflection: "runtime-contract", step: "inspect", reason: :provider_unavailable}} =
               Runner.run(reflection, invocation)
    end

    test "and no later step is invoked" do
      assert {:error, _} =
               run_observed_reflection([%{type: :fail, reason: :provider_unavailable}])

      assert [_] = model_requests()
    end
  end

  describe "when a Reflection Runner is invoked > if the model and tool loop reaches its iteration limit without a final answer" do
    test "then the Reflection fails identifying its name, current step, and exhausted iteration limit" do
      turns =
        for n <- 1..11,
            do: %{type: :tool_call, name: "reflection_probe", arguments: %{value: "round-#{n}"}}

      {reflection, invocation} =
        scripted_reflection(turns ++ [%{type: :answer, text: ~s({"answer":"too late"})}])

      assert {:error, %{reflection: "runtime-contract", step: "inspect", reason: :max_iterations}} =
               Runner.run(reflection, invocation,
                 tools: [ReflectionProbe],
                 tool_context: %{test_pid: self()}
               )
    end

    test "and no partial artefact is returned" do
      assert {:error, %{reason: :max_iterations}} = run_observed_reflection(exhausted_turns())
    end

    test "and no later step is invoked" do
      assert {:error, _} = run_observed_reflection(exhausted_turns())
      requests = model_requests()
      assert length(requests) == 10
      assert Enum.all?(requests, &(hd(&1) == hd(hd(requests))))
    end
  end

  describe "when a Reflection Runner is invoked > while an earlier step's output makes a later step prompt exceed 100,000 characters" do
    test "then the configured model receives the complete interpolated output in that later step" do
      answer = String.duplicate("retained evidence ", 10_000)
      assert {:ok, _} = run_observed_reflection([answer_turn(answer)], answer)
      assert [_, messages] = model_requests()
      assert [%{content: prompt}] = messages

      assert prompt ==
               expected_step_prompt("Conclude " <> answer, [], %{"conclusion" => "string"})
    end

    test "and valid model output completes the remaining Chain of Thought" do
      answer = String.duplicate("retained evidence ", 10_000)

      assert {:ok, %Gralkor.Artefact{payload: %{"conclusion" => "done"}}} =
               run_observed_reflection([answer_turn(answer)], answer)
    end
  end

  describe "when a Reflection Runner is invoked > where the model requests tools before returning the current step's structured output" do
    test "then the supplied tools execute with the invocation's operator identity and supplied tool context" do
      assert {:ok, _} = run_observed_reflection([tool_turn("first"), answer_turn("ready")])
      assert_receive {:reflection_tool, "first", "operator-one", "kept"}
    end

    test "and subsequent model turns receive the preceding tool results within that step" do
      assert {:ok, _} =
               run_observed_reflection([
                 tool_turn("first"),
                 tool_turn("second"),
                 answer_turn("ready")
               ])

      assert [_, second, third, _] = model_requests()
      assert Enum.any?(second, &(&1.role == :tool and &1.content =~ "first"))
      assert Enum.any?(third, &(&1.role == :tool and &1.content =~ "second"))
    end

    test "and the next step starts only after the current step returns valid structured output" do
      assert {:ok, _} = run_observed_reflection([tool_turn("first"), answer_turn("ready")])
      assert [first, continuation, final] = model_requests()
      assert hd(first) == hd(continuation)
      assert [%{content: prompt}] = final
      assert prompt == expected_step_prompt("Conclude ready", [], %{"conclusion" => "string"})
    end
  end

  describe "when a Reflection Runner is invoked > if the model returns invalid JSON or a non-object JSON value" do
    test "then the Reflection fails identifying its name, current step, and invalid structured output" do
      for text <- ["not JSON", "[1,2]"] do
        assert {:error,
                %{
                  reflection: "runtime-contract",
                  step: "inspect",
                  reason: {:invalid_structured_output, _}
                }} = run_observed_reflection([%{type: :answer, text: text}])
      end
    end

    test "and no later step is invoked" do
      for text <- ["not JSON", "[1,2]"] do
        assert {:error, _} = run_observed_reflection([%{type: :answer, text: text}])
        assert [_] = model_requests()
      end
    end
  end

  describe "when a Chain of Thought step begins" do
    test "then built-in inference receives that step's interpolated natural-language directions",
         context do
      requests = run_and_collect_requests(reflection(context), invocation())
      assert Enum.at(requests, 1).directions == "Synthesise [\"fact one\"]"
    end

    test "and receives that step's declared structured-output contract", context do
      assert [first | _] = run_and_collect_requests(reflection(context), invocation())
      assert first.output_schema == %{"facts" => "Array<string>"}
    end

    test "and receives the complete tool set available to the host agent", _context do
      tools = [JidoGralkor.Actions.MemorySearch, JidoGralkor.Actions.MemoryAdd]
      tool_context = %{session_id: "session-one", custom: "kept"}

      request = %{
        directions: "Use memory.",
        output_schema: %{"artefact" => "string"},
        representations: [
          Gralkor.IngestedRepresentation.new(
            "observations",
            "first representation"
          )
        ],
        tools: tools,
        tool_context: tool_context,
        operator_id: "operator-one"
      }

      call = fn prompt, config, opts ->
        params = %{prompt: prompt, model: config.model, tools: config.tools}
        received = Keyword.fetch!(opts, :context)
        send(self(), {:default_inference, params, received})
        %{termination_reason: :final_answer, result: ~s({"artefact":"done"})}
      end

      assert {:ok, %{output: %{"artefact" => "done"}}} = Runner.default_inference(request, call)

      assert_receive {:default_inference, %{model: model, prompt: prompt, tools: ^tools},
                      received_context}

      configured = Gralkor.Config.llm_model()
      assert model == "#{configured.provider}:#{configured.id}"
      assert prompt =~ ~s("lens":"observations")
      assert received_context == Map.put(tool_context, :operator_id, "operator-one")
    end

    test "and the current step is the only step exposed to inference", context do
      assert [first | _] = run_and_collect_requests(reflection(context), invocation())
      assert first.step == %{label: "gather", directions: "Gather facts."}
      refute Map.has_key?(first, :steps)
    end

    test "and built-in inference tool context uses the invocation's operator identity while retaining every other supplied context value" do
      tool_context = %{
        operator_id: "conflicting-caller-value",
        session_id: "session-one",
        custom: "kept"
      }

      request = %{
        directions: "Use memory.",
        output_schema: %{"artefact" => "string"},
        representations: [],
        tools: [],
        tool_context: tool_context,
        operator_id: "invocation-operator"
      }

      call = fn _prompt, _config, opts ->
        received = Keyword.fetch!(opts, :context)
        send(self(), {:default_inference_context, received})
        %{termination_reason: :final_answer, result: ~s({"artefact":"done"})}
      end

      assert {:ok, %{output: %{"artefact" => "done"}}} = Runner.default_inference(request, call)

      assert_receive {:default_inference_context, received}

      assert received == %{
               operator_id: "invocation-operator",
               session_id: "session-one",
               custom: "kept"
             }
    end
  end

  describe "when a Chain of Thought step begins > where the Runner is given a model resolver" do
    test "then built-in inference runs the model that resolver names" do
      parent = self()
      schema = %{"answer" => "string"}

      register_step("Resolve the model.", [], schema, [answer_turn("ready")])

      reflection = %Gralkor.Reflection{
        name: "resolved-model",
        outputs: [],
        chain_of_thought: %Gralkor.Reflection.ChainOfThought{
          steps: [
            %Gralkor.Reflection.ChainOfThought.Step{
              label: "resolve",
              directions: "Resolve the model.",
              output: schema
            }
          ]
        }
      }

      resolver = fn ->
        send(parent, :model_resolved)
        %{provider: "openai", id: "gpt-6-luna"}
      end

      assert {:ok, %Gralkor.Artefact{payload: %{"answer" => "ready"}}} =
               Runner.run(
                 reflection,
                 %{id: "resolved-model-run", operator_id: "operator-one", representations: []},
                 model_resolver: resolver
               )

      assert_received :model_resolved
    end
  end

  describe "when a Chain of Thought step begins > where the Runner is given no model resolver" do
    test "then built-in inference runs Gralkor's configured LLM model" do
      configured = Gralkor.Config.llm_model()
      assert step_call(step_request()).model == "#{configured.provider}:#{configured.id}"
    end
  end

  describe "when a Chain of Thought step begins > where the Runner is given a reasoning effort" do
    test "then built-in inference asks the model for that reasoning effort" do
      assert step_config(step_request(), reasoning_effort: :low).llm_opts ==
               [reasoning_effort: :low]
    end
  end

  describe "when a Chain of Thought step begins > where the Runner is given no reasoning effort" do
    test "then built-in inference names no reasoning effort" do
      refute Map.has_key?(step_config(step_request(), []), :llm_opts)
    end
  end

  describe "when a Chain of Thought step begins > where the directions reference outputs from earlier steps" do
    test "then every referenced value is interpolated from the Chain of Thought's shared output space",
         context do
      assert [_first, second] = run_and_collect_requests(reflection(context), invocation())
      assert second.directions =~ "fact one"
      refute second.directions =~ "{{facts}}"
    end

    test "and an output whose name holds a space is interpolated too" do
      cot = %{
        steps: [
          %{
            label: "gather",
            directions: "Gather.",
            output: %{"blocked tasks" => "Array<string>"}
          },
          %{
            label: "synthesise",
            directions: "Confirm {{ blocked tasks }}.",
            output: %{"artefact" => "string"}
          }
        ]
      }

      reflection = resolve_reflection(valid_definition(chain_of_thought: cot))
      parent = self()

      inference = fn
        %{step: %{label: "gather"}} ->
          {:ok, %{output: %{"blocked tasks" => ["OPS-12"]}}}

        %{step: %{label: "synthesise"}} = request ->
          send(parent, {:request, request})
          {:ok, %{output: %{"artefact" => "OPS-12 is blocked"}}}
      end

      assert {:ok, _} = Runner.run(reflection, invocation(), inference: inference)
      assert_receive {:request, %{directions: ~s(Confirm ["OPS-12"].)}}
    end

    test "and a value that is not a string is interpolated as its JSON encoding" do
      reflection = resolve_reflection(valid_definition())

      assert synthesise_directions(reflection, ["fact one", "fact two"]) ==
               ~s(Synthesise ["fact one","fact two"])
    end

    test "and double braces inside an interpolated value are not interpolated again" do
      cot = %{
        steps: [
          %{label: "gather", directions: "Gather.", output: %{"facts" => "string"}},
          %{label: "synthesise", directions: "Use {{facts}}.", output: %{"artefact" => "string"}}
        ]
      }

      reflection = resolve_reflection(valid_definition(chain_of_thought: cot))

      assert synthesise_directions(reflection, "see {{facts}} and {{ unknown }}") ==
               "Use see {{facts}} and {{ unknown }}."
    end
  end

  describe "when a Chain of Thought step begins > where the directions reference outputs from earlier steps > where text put before the validated directions holds an unclosed double brace" do
    test "then every referenced value is still interpolated" do
      reflection =
        valid_definition()
        |> resolve_reflection()
        |> prepend_directions("synthesise", "This run is for {{Ana (ana@example.com). ")

      assert synthesise_directions(reflection, ["fact one"]) =~ ~s(Synthesise ["fact one"])
    end

    test "and that text reaches inference as written" do
      reflection =
        valid_definition()
        |> resolve_reflection()
        |> prepend_directions("synthesise", "This run is for {{Ana (ana@example.com). ")

      assert synthesise_directions(reflection, ["fact one"]) ==
               ~s(This run is for {{Ana (ana@example.com\). Synthesise ["fact one"])
    end
  end

  describe "when a Chain of Thought step begins > where the directions reference outputs from earlier steps > where text added to the validated directions holds double braces naming no earlier output" do
    test "then those braces and their text reach inference as written" do
      reflection =
        valid_definition()
        |> resolve_reflection()
        |> prepend_directions("synthesise", "Write for {{ the reader }}. ")

      assert synthesise_directions(reflection, ["fact one"]) ==
               ~s(Write for {{ the reader }}. Synthesise ["fact one"])
    end
  end

  describe "when a Chain of Thought step begins > where inference directs a tool call" do
    @tag timeout: 120_000
    test "then the requested tool is called with the model-produced arguments",
         context do
      parent = self()
      inference = tool_calling_inference(parent, 1)

      executor = fn call, _ ->
        send(parent, {:executed, call})
        {:ok, "found"}
      end

      assert {:ok, _} =
               Runner.run(one_step_reflection(context), invocation(),
                 inference: inference,
                 tool_executor: executor
               )

      assert_receive {:executed, %{name: "memory_search", arguments: %{"query" => "pattern"}}}
    end

    test "and the tool result is returned to inference within the same step", context do
      parent = self()
      inference = tool_calling_inference(parent, 1)
      executor = fn _, _ -> {:ok, "found"} end

      assert {:ok, _} =
               Runner.run(one_step_reflection(context), invocation(),
                 inference: inference,
                 tool_executor: executor
               )

      assert_receive {:continued, "reflect", [%{result: {:ok, "found"}}]}
    end

    test "and inference continues within that step with access to the result and every configured tool",
         context do
      parent = self()
      tools = [:memory_search, :memory_add]
      inference = tool_calling_inference(parent, 1)

      assert {:ok, _} =
               Runner.run(one_step_reflection(context), invocation(),
                 inference: inference,
                 tools: tools,
                 tool_executor: fn _, _ -> :ok end
               )

      assert_receive {:continued_tools, "reflect", ^tools}
    end
  end

  describe "when a Chain of Thought step begins > where inference directs further tool calls" do
    test "then each requested call and result continues the same step in sequence",
         context do
      parent = self()
      inference = tool_calling_inference(parent, 2)

      executor = fn call, _ ->
        send(parent, {:tool_sequence, call.name})
        {:ok, call.name}
      end

      assert {:ok, _} =
               Runner.run(one_step_reflection(context), invocation(),
                 inference: inference,
                 tool_executor: executor
               )

      assert_receive {:tool_sequence, "tool-1"}
      assert_receive {:tool_sequence, "tool-2"}
    end
  end

  describe "when inference returns a structured output for the current step > while its keys and values satisfy that step's declared output contract" do
    test "then the output is added to the Chain of Thought's shared output space",
         context do
      assert [_first, second] = run_and_collect_requests(reflection(context), invocation())
      assert second.directions =~ "fact one"
    end

    test "and the next step begins with those outputs available for interpolation", context do
      assert [_first, second] = run_and_collect_requests(reflection(context), invocation())
      assert second.step.label == "synthesise"
      assert second.directions == "Synthesise [\"fact one\"]"
    end
  end

  describe "when inference returns a structured output for the current step > if a declared output key is missing > while the step is not the final step" do
    test "then the Reflection fails identifying its name, current step, and missing key",
         context do
      assert {:error,
              %{reflection: "generalisation", step: "gather", reason: {:missing_output, "facts"}}} =
               Runner.run(reflection(context), invocation(),
                 inference: fn _ -> {:ok, %{output: %{}}} end
               )
    end
  end

  describe "when inference returns a structured output for the current step > if a declared output key is missing > while the step is the final step" do
    test "then the Reflection fails identifying its name and missing artefact", context do
      inference = fn
        %{step: %{label: "gather"}} -> {:ok, %{output: %{"facts" => ["fact one"]}}}
        %{step: %{label: "synthesise"}} -> {:ok, %{output: %{}}}
      end

      assert {:error, failure} =
               Runner.run(reflection(context), invocation(), inference: inference)

      assert failure == %{reflection: "generalisation", reason: :missing_artefact}
    end
  end

  describe "when inference returns a structured output for the current step > if an undeclared output key is returned" do
    test "then the Reflection fails identifying its name, current step, and unexpected key",
         context do
      assert {:error,
              %{
                reflection: "generalisation",
                step: "gather",
                reason: {:unexpected_output, "extra"}
              }} =
               Runner.run(reflection(context), invocation(),
                 inference: fn _ -> {:ok, %{output: %{"facts" => [], "extra" => true}}} end
               )
    end
  end

  describe "when inference returns a structured output for the current step > if an output value does not satisfy its declared type" do
    test "then the Reflection fails identifying its name, current step, and type mismatch",
         context do
      assert {:error,
              %{
                reflection: "generalisation",
                step: "gather",
                reason: {:output_type_mismatch, "facts", "Array<string>"}
              }} =
               Runner.run(reflection(context), invocation(),
                 inference: fn _ -> {:ok, %{output: %{"facts" => "not a list"}}} end
               )
    end
  end

  describe "when the final Chain of Thought step returns valid structured output" do
    test "then that structured output becomes one `%Gralkor.Artefact{}`", context do
      assert {:ok, %Gralkor.Artefact{}} =
               Runner.run(reflection(context), invocation(), inference: &output_for/1)
    end

    test "and the artefact contains exactly its stable identifier and structured payload",
         context do
      assert {:ok, artefact} =
               Runner.run(reflection(context), invocation(), inference: &output_for/1)

      assert Map.from_struct(artefact) == %{
               id: artefact.id,
               payload: %{"artefact" => "durable pattern"}
             }
    end

    test "and the artefact carries no producer identity", context do
      assert {:ok, artefact} =
               Runner.run(reflection(context), invocation(), inference: &output_for/1)

      refute Map.has_key?(Map.from_struct(artefact), :producer)
    end

    test "and the caller receives that artefact", context do
      assert {:ok, %Gralkor.Artefact{} = artefact} =
               Runner.run(reflection(context), invocation(), inference: &output_for/1)

      assert artefact.payload == %{"artefact" => "durable pattern"}
    end

    test "and the Runner does not deliver the declared Destination output", context do
      reflection = reflection(context)

      Application.put_env(:jido_gralkor, :destination_storage, OutputProbeStorage)

      assert {:ok, %Gralkor.Artefact{}} =
               Runner.run(reflection, invocation(), inference: &output_for/1)

      refute_receive {:destination_output_delivered, _, _, _, _}
    end
  end

  describe "when a consumer triggers a named Reflection with an invocation callback" do
    test "then submission returns its invocation identifier without waiting for the Reflection to finish" do
      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: AsyncConsumerAgent, id: "reflection-async-submission", register_global: false}
        )

      assert :ok =
               JidoGralkor.Runtime.replace(agent_server, async_reflection_configuration())

      test_pid = self()
      release = make_ref()

      inference = fn _request ->
        send(test_pid, {:reflection_inference_started, self()})

        receive do
          {^release, :continue} -> {:ok, %{output: %{"summary" => "complete"}}}
        end
      end

      callback = fn result -> send(test_pid, {:reflection_callback, result}) end

      submission =
        Task.async(fn ->
          Client.reflect(
            agent_server,
            "review",
            async_reflection_invocation(),
            callback,
            inference: inference
          )
        end)

      assert_receive {:reflection_inference_started, inference_process}
      assert {:ok, {:ok, "reflection-invocation-one"}} = Task.yield(submission, 100)
      refute_receive {:reflection_callback, _}

      send(inference_process, {release, :continue})

      assert_receive {:reflection_callback,
                      %{invocation_id: "reflection-invocation-one", outcome: :delivered}}
    end
  end

  describe "if a consumer triggers a Reflection without a valid invocation callback" do
    test "then submission fails before the Reflection is admitted" do
      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: AsyncConsumerAgent, id: "reflection-invalid-callback", register_global: false}
        )

      assert :ok =
               JidoGralkor.Runtime.replace(agent_server, async_reflection_configuration())

      test_pid = self()

      assert {:error, {:invalid_invocation_callback, :not_a_callback}} =
               Client.reflect(
                 agent_server,
                 "review",
                 async_reflection_invocation(),
                 :not_a_callback,
                 inference: fn _ ->
                   send(test_pid, :invalid_callback_inference_started)
                   {:ok, %{output: %{"summary" => "complete"}}}
                 end
               )

      refute_receive :invalid_callback_inference_started
    end
  end

  describe "if a consumer triggers a Reflection without a valid invocation identifier or operator identifier" do
    test "then submission fails before the Reflection is admitted" do
      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: AsyncConsumerAgent, id: "reflection-invalid-identity", register_global: false}
        )

      assert :ok =
               JidoGralkor.Runtime.replace(agent_server, async_reflection_configuration())

      test_pid = self()
      callback = fn result -> send(test_pid, {:reflection_callback, result}) end

      for invalid <- [nil, " "] do
        assert {:error, {:invalid_invocation_id, ^invalid}} =
                 Client.reflect(
                   agent_server,
                   "review",
                   %{async_reflection_invocation() | id: invalid},
                   callback,
                   inference: fn _ -> send(test_pid, :invalid_identity_work_started) end
                 )
      end

      assert {:error, {:invalid_operator_id, nil}} =
               Client.reflect(
                 agent_server,
                 "review",
                 Map.delete(async_reflection_invocation(), :operator_id),
                 callback,
                 inference: fn _ -> send(test_pid, :invalid_identity_work_started) end
               )

      refute_receive :invalid_identity_work_started
      refute_receive {:reflection_callback, _}
    end
  end

  describe "when an admitted Reflection completes successfully" do
    test "then its produced artefact is delivered to its Destination" do
      Application.put_env(:jido_gralkor, :destination_storage, OutputProbeStorage)

      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: AsyncConsumerAgent, id: "reflection-async-success", register_global: false}
        )

      assert :ok =
               JidoGralkor.Runtime.replace(agent_server, async_reflection_configuration())

      test_pid = self()
      callback = fn result -> send(test_pid, {:reflection_callback, result}) end

      assert {:ok, "reflection-invocation-one"} =
               Client.reflect(
                 agent_server,
                 "review",
                 async_reflection_invocation(),
                 callback,
                 inference: fn _ -> {:ok, %{output: %{"summary" => "complete"}}} end
               )

      assert_receive {:destination_output_delivered, output, "review", "operator-one", artefact}
      assert output.destination.name == "reviews"
      assert artefact.payload == %{"summary" => "complete"}

      assert_receive {:reflection_callback,
                      %{
                        invocation_id: "reflection-invocation-one",
                        artefact: ^artefact,
                        outcome: :delivered
                      }}
    end

    test "and the submitting consumer's callback eventually receives the same invocation identifier" do
      {_artefact, result} = submit_successful_reflection("success-callback-identifier")
      assert result.invocation_id == "success-callback-identifier"
    end

    test "and that callback receives the produced artefact and successful delivery outcome" do
      {artefact, result} = submit_successful_reflection("success-callback-outcome")
      assert result.artefact == artefact
      assert result.outcome == :delivered
    end
  end

  describe "when independently submitted Reflection invocations are running" do
    test "then each invocation progresses without waiting for another invocation" do
      Application.put_env(:jido_gralkor, :destination_storage, OutputProbeStorage)

      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: AsyncConsumerAgent,
           id: "reflection-independent-invocations",
           register_global: false}
        )

      assert :ok =
               JidoGralkor.Runtime.replace(agent_server, async_reflection_configuration())

      test_pid = self()
      release = make_ref()

      inference = fn request ->
        case request.invocation_id do
          "blocked-invocation" ->
            send(test_pid, {:blocked_reflection_started, self()})

            receive do
              {^release, :continue} -> {:ok, %{output: %{"summary" => "first"}}}
            end

          "independent-invocation" ->
            {:ok, %{output: %{"summary" => "second"}}}
        end
      end

      callback = fn result -> send(test_pid, {:reflection_callback, result}) end

      assert {:ok, "blocked-invocation"} =
               Client.reflect(
                 agent_server,
                 "review",
                 async_reflection_invocation("blocked-invocation"),
                 callback,
                 inference: inference
               )

      assert_receive {:blocked_reflection_started, blocked_process}

      assert {:ok, "independent-invocation"} =
               Client.reflect(
                 agent_server,
                 "review",
                 async_reflection_invocation("independent-invocation"),
                 callback,
                 inference: inference
               )

      assert_receive {:reflection_callback,
                      %{invocation_id: "independent-invocation", outcome: :delivered}}

      refute_receive {:reflection_callback, %{invocation_id: "blocked-invocation"}}
      send(blocked_process, {release, :continue})

      assert_receive {:reflection_callback,
                      %{invocation_id: "blocked-invocation", outcome: :delivered}}
    end
  end

  describe "when a consumer-owned scheduled job triggers a Reflection" do
    test "then the scheduled job does not wait for the Reflection to finish" do
      Application.put_env(:jido_gralkor, :destination_storage, OutputProbeStorage)

      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: AsyncConsumerAgent,
           id: "reflection-consumer-scheduled-job",
           register_global: false}
        )

      assert :ok =
               JidoGralkor.Runtime.replace(agent_server, async_reflection_configuration())

      test_pid = self()
      release = make_ref()
      callback = fn result -> send(test_pid, {:scheduled_reflection_callback, result}) end

      inference = fn _request ->
        send(test_pid, {:scheduled_reflection_started, self()})

        receive do
          {^release, :continue} -> {:ok, %{output: %{"summary" => "scheduled"}}}
        end
      end

      scheduled_job =
        Task.async(fn ->
          Client.reflect(
            agent_server,
            "review",
            async_reflection_invocation("scheduled-invocation"),
            callback,
            inference: inference
          )
        end)

      assert_receive {:scheduled_reflection_started, reflection_process}
      assert {:ok, {:ok, "scheduled-invocation"}} = Task.yield(scheduled_job, 100)
      refute_receive {:scheduled_reflection_callback, _}

      send(reflection_process, {release, :continue})

      assert_receive {:scheduled_reflection_callback,
                      %{
                        invocation_id: "scheduled-invocation",
                        artefact: %Gralkor.Artefact{payload: %{"summary" => "scheduled"}},
                        outcome: :delivered
                      }}
    end

    test "and its invocation callback eventually receives the same completion or failure outcome as any other consumer trigger" do
      Application.put_env(:jido_gralkor, :destination_storage, OutputProbeStorage)

      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: AsyncConsumerAgent, id: "reflection-scheduled-callback", register_global: false}
        )

      assert :ok = Runtime.replace(agent_server, async_reflection_configuration())

      test_pid = self()
      callback = &send(test_pid, {:scheduled_reflection_callback, &1})

      scheduled_job =
        Task.async(fn ->
          Client.reflect(
            agent_server,
            "review",
            async_reflection_invocation("scheduled-callback-invocation"),
            callback,
            inference: fn _ -> {:ok, %{output: %{"summary" => "complete"}}} end
          )
        end)

      assert {:ok, "scheduled-callback-invocation"} = Task.await(scheduled_job)

      assert_receive {:scheduled_reflection_callback,
                      %{
                        invocation_id: "scheduled-callback-invocation",
                        artefact: %Gralkor.Artefact{payload: %{"summary" => "complete"}},
                        outcome: :delivered
                      } = scheduled_success}

      assert_receive {:destination_output_delivered, _output, "review", "operator-one",
                      %Gralkor.Artefact{}}

      failing_job =
        Task.async(fn ->
          Client.reflect(
            agent_server,
            "review",
            async_reflection_invocation("scheduled-failure-invocation"),
            callback,
            inference: fn _ -> {:error, :provider_unavailable} end
          )
        end)

      assert {:ok, "scheduled-failure-invocation"} = Task.await(failing_job)
      assert_receive {:scheduled_reflection_callback, scheduled_failure}

      {_artefact, direct_success} = submit_successful_reflection("direct-success-invocation")
      direct_failure = submit_failed_reflection("direct-failure-invocation")

      assert scheduled_success.outcome == direct_success.outcome
      assert scheduled_success.artefact.payload == direct_success.artefact.payload
      assert scheduled_failure.outcome == direct_failure.outcome
      assert Map.keys(scheduled_failure) == Map.keys(direct_failure)
      assert scheduled_failure.invocation_id == "scheduled-failure-invocation"
    end
  end

  describe "if Reflection production fails" do
    test "then no Destination output is attempted" do
      Application.put_env(:jido_gralkor, :destination_storage, OutputProbeStorage)

      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: AsyncConsumerAgent,
           id: "reflection-async-production-failure",
           register_global: false}
        )

      assert :ok =
               JidoGralkor.Runtime.replace(agent_server, async_reflection_configuration())

      test_pid = self()
      callback = fn result -> send(test_pid, {:reflection_callback, result}) end

      assert {:ok, "reflection-invocation-one"} =
               Client.reflect(
                 agent_server,
                 "review",
                 async_reflection_invocation(),
                 callback,
                 inference: fn _ -> {:error, :provider_unavailable} end
               )

      assert_receive {:reflection_callback,
                      %{
                        invocation_id: "reflection-invocation-one",
                        outcome:
                          {:production_failed,
                           %{
                             reflection: "review",
                             step: "review",
                             reason: :provider_unavailable
                           }}
                      }}

      refute_receive {:destination_output_delivered, _, _, _, _}
    end

    test "and the invocation callback eventually receives the production failure" do
      result = submit_failed_reflection("generic-production-failure")

      assert result == %{
               invocation_id: "generic-production-failure",
               outcome:
                 {:production_failed,
                  %{reflection: "review", step: "review", reason: :provider_unavailable}}
             }
    end
  end

  describe "if a Reflection's Chain of Thought fails" do
    test "then the Reflection failure identifies its name and reason", context do
      assert {:error, %{reflection: "generalisation", reason: :inference_failed}} =
               Runner.run(reflection(context), invocation(),
                 inference: fn _ -> {:error, :inference_failed} end
               )
    end
  end

  describe "when a Destination holding Reflection artefacts is searched" do
    test "then that Destination is searched", context do
      {reflection, artefact} = stored_artefact(context)
      expected = Map.from_struct(artefact)

      assert {:ok, [%{destination: "personal", episodes: [%{artefact: ^expected}]}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "durable",
                 destinations: [destination_output(reflection).destination.name]
               })
    end

    test "and relevant artefacts written through any Destination output using that Destination are returned among its episodes",
         context do
      one = reflection(context, "one")
      two = reflection(context, "two")
      {:ok, a1} = Runner.run(one, invocation(), inference: &output_for/1)
      {:ok, a2} = Runner.run(two, invocation(), inference: &output_for/1)
      :ok = put_artefact(one, "operator-one", a1, storage: Gralkor.Destination.Storage.InMemory)
      :ok = put_artefact(two, "operator-one", a2, storage: Gralkor.Destination.Storage.InMemory)

      assert {:ok, [%{destination: "personal", episodes: episodes}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "",
                 destinations: [destination_output(one).destination.name]
               })

      assert [
               %{artefact: Map.from_struct(a1), reflection: one.name},
               %{artefact: Map.from_struct(a2), reflection: two.name}
             ] == Enum.map(episodes, &Map.take(&1, [:artefact, :reflection]))
    end

    test "and every returned artefact contains exactly its stable identifier and structured payload",
         context do
      {reflection, stored} = stored_artefact(context)

      assert {:ok, [%{episodes: [%{artefact: artefact}]}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "durable",
                 destinations: [destination_output(reflection).destination.name]
               })

      assert artefact == %{
               id: stored.id,
               payload: %{"artefact" => "durable pattern"}
             }
    end
  end

  describe "when a Destination holding Reflection artefacts is searched > where the caller identifies one artefact" do
    test "then that artefact is found among the Destination's episodes by its identifier",
         context do
      {reflection, artefact} = stored_artefact(context)

      {:ok, other} =
        Runner.run(reflection, %{invocation() | id: "ingestion-2"}, inference: &output_for/1)

      refute other.id == artefact.id

      :ok =
        put_artefact(reflection, "operator-one", other,
          storage: Gralkor.Destination.Storage.InMemory
        )

      assert {:ok, [%{destination: "personal", episodes: episodes}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "durable",
                 destinations: [destination_output(reflection).destination.name]
               })

      assert Enum.sort(for(%{artefact: %{id: id}} <- episodes, do: id)) ==
               Enum.sort([artefact.id, other.id])

      artefact_id = artefact.id

      assert [Map.from_struct(artefact)] ==
               for(%{artefact: %{id: ^artefact_id} = found} <- episodes, do: found)
    end

    test "and exact lookup by that identifier returns only that artefact",
         context do
      {reflection, artefact} = stored_artefact(context)

      {:ok, other} =
        Runner.run(reflection, %{invocation() | id: "ingestion-2"}, inference: &output_for/1)

      refute other.id == artefact.id

      :ok =
        put_artefact(reflection, "operator-one", other,
          storage: Gralkor.Destination.Storage.InMemory
        )

      assert {:ok, ^artefact} =
               Gralkor.Destination.Storage.get_artefact(
                 destination_output(reflection),
                 reflection.name,
                 "operator-one",
                 artefact.id,
                 storage: Gralkor.Destination.Storage.InMemory
               )

      assert {:ok, ^other} =
               Gralkor.Destination.Storage.get_artefact(
                 destination_output(reflection),
                 reflection.name,
                 "operator-one",
                 other.id,
                 storage: Gralkor.Destination.Storage.InMemory
               )
    end
  end

  describe "if the retired `:reflection_storage` setting is configured" do
    test "then application startup fails identifying Destination outputs as the artefact memory boundary" do
      Application.put_env(:jido_gralkor, :reflection_storage, FailingReflectionStorage)

      assert_raise ArgumentError, ~r/Destination outputs.*artefact memory boundary/, fn ->
        Gralkor.Application.children()
      end
    end
  end

  describe "when a Reflection delivers to personal memory" do
    test "then its artefact is searchable only by the invocation identity" do
      artefact = deliver_personal_reflection()

      expected = Map.from_struct(artefact)

      assert {:ok, [%{destination: "personal", episodes: [%{artefact: ^expected}]}]} =
               Client.search(self(), %Gralkor.Search{
                 operator_id: "owner",
                 query: "separate recurring jobs",
                 destinations: ["personal"]
               })

      assert {:ok, [%{destination: "personal", episodes: []}]} =
               Client.search(self(), %Gralkor.Search{
                 operator_id: "dashboard:another",
                 query: "separate recurring jobs",
                 destinations: ["personal"]
               })
    end

    test "and its artefact identifier remains derived from the unchanged operator and invocation identifiers" do
      artefact = deliver_personal_reflection()

      assert artefact.id ==
               Gralkor.Artefact.id_for("owner", "personal-reflection-invocation", "lessons")
    end
  end

  describe "when the Runner runs one step on its own" do
    test "then built-in inference receives the step's declared output contract" do
      assert step_inference_request().output_schema == %{"answer" => "string"}
    end

    test "and built-in inference receives the supplied tools" do
      assert step_inference_request().tools == [StepProbe]
    end

    test "and built-in inference receives no Reflection name" do
      refute Map.has_key?(step_inference_request(), :reflection)
    end

    test "and built-in inference receives no representations" do
      refute Map.has_key?(step_inference_request(), :representations)
      script_model([{:answer, ~s({"answer":"done"})}])
      assert {:ok, _} = Runner.run_step(scripted_step(), %{}, [])
      assert [body] = model_bodies()
      refute user_prompt(body) =~ "representations"
    end
  end

  describe "when the Runner runs one step on its own > when the model asks for a supplied tool" do
    test "then that tool executes with exactly the supplied tool context" do
      tool_context = %{test_pid: self(), session_id: "session-one", operator_id: "caller-value"}

      script_model([
        {:tool_calls, [{"step_probe", %{"value" => "first"}}]},
        {:answer, ~s({"answer":"done"})}
      ])

      assert {:ok, _} =
               Runner.run_step(scripted_step(), %{},
                 tools: [StepProbe],
                 tool_context: tool_context
               )

      assert_receive {:step_tool, "first", context}
      assert Map.take(context, Map.keys(tool_context)) == tool_context

      script_model([
        {:tool_calls, [{"step_probe", %{"value" => "second"}}]},
        {:answer, ~s({"answer":"done"})}
      ])

      assert {:ok, _} =
               Runner.run_step(scripted_step(), %{},
                 tools: [StepProbe],
                 tool_context: %{test_pid: self()}
               )

      assert_receive {:step_tool, "second", context}
      refute Map.has_key?(context, :operator_id)
    end
  end

  describe "when the Runner runs one step on its own > where a reference in the directions names a supplied value > where the value is a string" do
    test "then built-in inference receives the directions with that reference replaced by the string" do
      assert step_directions("Review {{ ticket }}.", %{"ticket" => "OPS-12"}) == "Review OPS-12."
    end
  end

  describe "when the Runner runs one step on its own > where a reference in the directions names a supplied value > where the value is not a string" do
    test "then built-in inference receives the directions with that reference replaced by the value's JSON encoding" do
      assert step_directions("Review {{ tickets }}.", %{"tickets" => ["OPS-12", 3]}) ==
               ~s(Review ["OPS-12",3].)
    end
  end

  describe "when the Runner runs one step on its own > where a reference in the directions names a supplied value > where the value holds a reference naming another supplied value" do
    test "then that inner reference reaches the model as written" do
      values = %{"ticket" => "see {{ other }}", "other" => "OPS-13"}

      assert step_prompt("Review {{ ticket }}.", values) ==
               run_step_prompt("Review see {{ other }}.", %{"answer" => "string"})
    end
  end

  describe "when the Runner runs one step on its own > where a reference in the directions names no supplied value" do
    test "then that reference reaches the model as written" do
      assert step_prompt("Review {{ missing }}.", %{"ticket" => "OPS-12"}) ==
               run_step_prompt("Review {{ missing }}.", %{"answer" => "string"})
    end
  end

  describe "when the Runner runs one step on its own > where the directions hold an unclosed double brace ahead of a reference naming a supplied value" do
    test "then that reference is filled in from its value" do
      assert step_prompt("For {{Ana. Review {{ ticket }}.", %{"ticket" => "OPS-12"}) =~
               "Review OPS-12."
    end

    test "and the unclosed double brace reaches the model as written" do
      assert step_prompt("For {{Ana. Review {{ ticket }}.", %{"ticket" => "OPS-12"}) ==
               run_step_prompt("For {{Ana. Review OPS-12.", %{"answer" => "string"})
    end
  end

  describe "when the Runner runs one step on its own > where the step is given a model" do
    test "then every model request of the step runs that model" do
      script_model([
        {:tool_calls, [{"step_probe", %{"value" => "first"}}]},
        {:answer, ~s({"answer":"done"})}
      ])

      assert {:ok, _} =
               Runner.run_step(scripted_step(), %{},
                 tools: [StepProbe],
                 tool_context: %{test_pid: self()}
               )

      assert [first, second] = model_bodies()
      assert first["model"] == "gpt-5"
      assert second["model"] == "gpt-5"
    end
  end

  describe "when the Runner runs one step on its own > where the step is given no model" do
    test "then every model request of the step runs Gralkor's configured LLM model" do
      previous = System.get_env("GRALKOR_LLM_MODEL")
      System.put_env("GRALKOR_LLM_MODEL", "openai:gpt-5-mini")

      on_exit(fn ->
        if previous,
          do: System.put_env("GRALKOR_LLM_MODEL", previous),
          else: System.delete_env("GRALKOR_LLM_MODEL")
      end)

      script_model([
        {:tool_calls, [{"step_probe", %{"value" => "first"}}]},
        {:answer, ~s({"answer":"done"})}
      ])

      assert {:ok, _} =
               Runner.run_step(Map.delete(scripted_step(), :model), %{},
                 tools: [StepProbe],
                 tool_context: %{test_pid: self()}
               )

      configured = Gralkor.Config.llm_model()
      assert Enum.map(model_bodies(), & &1["model"]) == [configured.id, configured.id]
    end
  end

  describe "when the Runner runs one step on its own > where the step is given a reasoning effort" do
    test "then every model request of the step asks for that reasoning effort" do
      script_model([
        {:tool_calls, [{"step_probe", %{"value" => "first"}}]},
        {:answer, ~s({"answer":"done"})}
      ])

      assert {:ok, _} =
               Runner.run_step(Map.put(scripted_step(), :reasoning_effort, :low), %{},
                 tools: [StepProbe],
                 tool_context: %{test_pid: self()}
               )

      assert Enum.map(model_bodies(), & &1["reasoning"]) == [
               %{"effort" => "low"},
               %{"effort" => "low"}
             ]
    end
  end

  describe "when the Runner runs one step on its own > where the step is given no reasoning effort" do
    test "then no model request of the step names a reasoning effort" do
      script_model([
        {:tool_calls, [{"step_probe", %{"value" => "first"}}]},
        {:answer, ~s({"answer":"done"})}
      ])

      assert {:ok, _} =
               Runner.run_step(scripted_step(), %{},
                 tools: [StepProbe],
                 tool_context: %{test_pid: self()}
               )

      assert [first, second] = model_bodies()
      refute Map.has_key?(first, "reasoning")
      refute Map.has_key?(second, "reasoning")
    end
  end

  describe "when the Runner runs one step on its own > when the model returns structured output satisfying the step's declared output contract" do
    test "then the Runner returns exactly those outputs" do
      script_model([{:answer, ~s({"answer":"done"})}])
      assert Runner.run_step(scripted_step(), %{}, []) == {:ok, %{"answer" => "done"}}
    end

    test "and the Runner returns no artefact" do
      script_model([{:answer, ~s({"answer":"done"})}])
      assert {:ok, outputs} = Runner.run_step(scripted_step(), %{}, [])
      refute is_struct(outputs)
    end
  end

  describe "when the Runner runs one step on its own > if a declared output key is missing" do
    test "then the step fails identifying the missing key" do
      script_model([{:answer, ~s({})}])

      assert Runner.run_step(scripted_step(), %{}, []) ==
               {:error, {:missing_output, "answer"}}
    end
  end

  describe "when the Runner runs one step on its own > if an undeclared output key is returned" do
    test "then the step fails identifying the unexpected key" do
      script_model([{:answer, ~s({"answer":"done","extra":"kept"})}])

      assert Runner.run_step(scripted_step(), %{}, []) ==
               {:error, {:unexpected_output, "extra"}}
    end
  end

  describe "when the Runner runs one step on its own > if an output value does not satisfy its declared type" do
    test "then the step fails identifying the key and type" do
      script_model([{:answer, ~s({"answer":3})}])

      assert Runner.run_step(scripted_step(), %{}, []) ==
               {:error, {:output_type_mismatch, "answer", "string"}}
    end
  end

  describe "when the Runner runs one step on its own > if the model request fails" do
    test "then the step fails identifying the provider failure" do
      script_model([{:fail, 400}])

      assert {:error, %ReqLLM.Error.API.Request{status: 400}} =
               Runner.run_step(scripted_step(), %{}, [])
    end
  end

  describe "when the Runner runs one step on its own > if the model returns invalid JSON or a non-object JSON value" do
    test "then the step fails identifying the invalid structured output" do
      for text <- ["not JSON", "[1,2]"] do
        script_model([{:answer, text}])

        assert {:error, {:invalid_structured_output, _}} =
                 Runner.run_step(scripted_step(), %{}, [])
      end
    end
  end

  describe "when the Runner runs one step on its own > if the model and tool loop reaches its iteration limit without a final answer" do
    test "then the step fails identifying the exhausted iteration limit" do
      script_model([{:always, {:tool_calls, [{"step_probe", %{"value" => "again"}}]}}])

      assert Runner.run_step(scripted_step(), %{},
               tools: [StepProbe],
               tool_context: %{test_pid: self()}
             ) == {:error, :max_iterations}
    end
  end

  describe "when the Runner runs one step on its own > if the step fails" do
    test "then its failure names no Reflection and no step" do
      for reply <- [{:answer, ~s({})}, {:answer, "not JSON"}, {:fail, 400}] do
        script_model([reply])
        assert {:error, reason} = Runner.run_step(scripted_step(), %{}, [])
        refute is_map(reason) and Map.has_key?(reason, :reflection)
        refute is_map(reason) and Map.has_key?(reason, :step)
      end
    end
  end

  describe "where the Runner runs a Reflection or one step on its own with an observer > when built-in inference starts a model request" do
    test "then the observer is told the request's identifier" do
      prove_model_request_started(:reflection)
      prove_model_request_started(:step)
    end
  end

  describe "where the Runner runs a Reflection or one step on its own with an observer > when built-in inference starts a model request > when that model request finishes" do
    test "then the observer is told the request's identifier, its duration, and its token use" do
      prove_model_request_finished(:reflection)
      prove_model_request_finished(:step)
    end
  end

  describe "where the Runner runs a Reflection or one step on its own with an observer > when built-in inference starts a model request > if that model request fails" do
    test "then the observer is told the request's identifier, its duration, and that it failed" do
      prove_model_request_failed(:reflection)
      prove_model_request_failed(:step)
    end
  end

  describe "where the Runner runs a Reflection or one step on its own with an observer > when built-in inference starts a model request > if that model request gets no answer in the time allowed" do
    @tag timeout: 300_000
    test "then the observer is told the request's identifier, its duration, and that it failed" do
      prove_model_request_unanswered(:reflection)
      prove_model_request_unanswered(:step)
    end
  end

  describe "where the Runner runs a Reflection or one step on its own with an observer > when built-in inference starts a tool call" do
    test "then the observer is told the call's identifier, tool name, and arguments" do
      prove_tool_started(:reflection)
      prove_tool_started(:step)
    end
  end

  describe "where the Runner runs a Reflection or one step on its own with an observer > when built-in inference starts a tool call > when that tool call completes" do
    test "then the observer is told the call's identifier, tool name, duration, and whether it succeeded" do
      prove_tool_completed(:reflection)
      prove_tool_completed(:step)
    end

    test "and the observer is told the call's result as the model receives it" do
      prove_tool_result_told(:reflection)
      prove_tool_result_told(:step)
    end
  end

  describe "where the Runner runs a Reflection or one step on its own with a time allowed for a tool call > if a tool call runs longer than that time" do
    test "then that tool call fails" do
      prove_tool_call_timed_out(:reflection, tool_timeout_ms: 200)
      prove_tool_call_timed_out(:step, tool_timeout_ms: 200)
    end

    test "and the model receives that failure within the same step" do
      prove_timeout_reaches_model(:reflection, tool_timeout_ms: 200)
      prove_timeout_reaches_model(:step, tool_timeout_ms: 200)
    end
  end

  describe "where the Runner runs a Reflection or one step on its own without being given a time allowed for a tool call > if a tool call runs longer than the default time" do
    @tag timeout: 300_000
    test "then that tool call fails" do
      prove_tool_call_timed_out(:reflection, [])
      prove_tool_call_timed_out(:step, [])
    end

    @tag timeout: 300_000
    test "and the model receives that failure within the same step" do
      prove_timeout_reaches_model(:reflection, [])
      prove_timeout_reaches_model(:step, [])
    end
  end

  describe "where the Runner runs a Reflection or one step on its own with a limit on rounds of tool use in a step > if the model keeps asking for tools beyond that many rounds" do
    test "then the step fails identifying the exhausted iteration limit" do
      prove_iteration_limit_failure(:reflection, max_iterations: 3)
      prove_iteration_limit_failure(:step, max_iterations: 3)
    end

    test "and the model receives no more requests in that step than that limit" do
      prove_requests_within_limit(:reflection, [max_iterations: 3], 3)
      prove_requests_within_limit(:step, [max_iterations: 3], 3)
    end
  end

  describe "where the Runner runs a Reflection or one step on its own without being given a limit on rounds of tool use in a step > if the model keeps asking for tools beyond the default number of rounds" do
    test "then the step fails identifying the exhausted iteration limit" do
      prove_iteration_limit_failure(:reflection, [])
      prove_iteration_limit_failure(:step, [])
    end

    test "and the model receives no more requests in that step than the default number" do
      prove_requests_within_limit(:reflection, [], Runner.default_limits().max_iterations)
      prove_requests_within_limit(:step, [], Runner.default_limits().max_iterations)
    end
  end

  describe "where the Runner runs a Reflection or one step on its own with a limit on tool calls at once > when the model asks for more tool calls in one answer than that limit" do
    test "then no more than that limit of them run at the same time" do
      prove_at_most_at_once(:reflection, [tool_concurrency: 2], 2)
      prove_at_most_at_once(:step, [tool_concurrency: 2], 2)
    end

    test "and as many of them as that limit run at the same time" do
      prove_as_many_at_once(:reflection, [tool_concurrency: 2], 2)
      prove_as_many_at_once(:step, [tool_concurrency: 2], 2)
    end

    test "and the model receives every one of their results within the same step" do
      prove_every_result_received(:reflection, [tool_concurrency: 2], 2)
      prove_every_result_received(:step, [tool_concurrency: 2], 2)
    end
  end

  describe "where the Runner runs a Reflection or one step on its own without being given a limit on tool calls at once > when the model asks for more tool calls in one answer than the default limit" do
    test "then no more than the default limit of them run at the same time" do
      prove_at_most_at_once(:reflection, [], Runner.default_limits().tool_concurrency)
      prove_at_most_at_once(:step, [], Runner.default_limits().tool_concurrency)
    end

    test "and as many of them as the default limit run at the same time" do
      prove_as_many_at_once(:reflection, [], Runner.default_limits().tool_concurrency)
      prove_as_many_at_once(:step, [], Runner.default_limits().tool_concurrency)
    end

    test "and the model receives every one of their results within the same step" do
      prove_every_result_received(:reflection, [], Runner.default_limits().tool_concurrency)
      prove_every_result_received(:step, [], Runner.default_limits().tool_concurrency)
    end
  end

  defp prove_model_request_started(entry) do
    script_model([{:answer, ~s({"answer":"done"})}])
    {_result, told} = observed_entry(entry, [])

    assert [{:model_request_started, %{id: id, model: "openai:gpt-5"}}] =
             model_tellings(told, :model_request_started)

    assert is_binary(id)
  end

  defp prove_model_request_finished(entry) do
    script_model([{:answer, ~s({"answer":"done"})}])
    {_result, told} = observed_entry(entry, [])
    assert [{:model_request_started, %{id: id}}] = model_tellings(told, :model_request_started)

    assert [{:model_request_finished, %{id: ^id, duration_ms: duration, usage: usage}}] =
             model_tellings(told, :model_request_finished)

    assert is_integer(duration) and duration >= 0
    assert %{input_tokens: 3, output_tokens: 4} = usage
  end

  defp prove_model_request_failed(entry) do
    script_model([{:fail, 400}])
    {_result, told} = observed_entry(entry, [])
    assert [{:model_request_started, %{id: id}}] = model_tellings(told, :model_request_started)

    assert [{:model_request_failed, %{id: ^id, duration_ms: duration}}] =
             model_tellings(told, :model_request_failed)

    assert is_integer(duration) and duration >= 0
    assert [] = model_tellings(told, :model_request_finished)
  end

  defp prove_model_request_unanswered(entry) do
    script_model([:hold])
    {_result, told} = observed_entry(entry, tool_timeout_ms: 1)
    assert [{:model_request_started, %{id: id}}] = model_tellings(told, :model_request_started)

    assert [{:model_request_failed, %{id: ^id, duration_ms: duration}}] =
             model_tellings(told, :model_request_failed)

    assert duration >= 60_001
    assert [] = model_tellings(told, :model_request_finished)
  end

  defp prove_tool_started(entry) do
    script_model([
      {:tool_calls, [{"step_probe", %{"value" => "first"}}]},
      {:answer, ~s({"answer":"done"})}
    ])

    {_result, told} = observed_entry(entry, [])

    assert [{:tool_started, %{id: "call-0-1", name: "step_probe", arguments: arguments}}] =
             model_tellings(told, :tool_started)

    assert arguments == %{"value" => "first"}
  end

  defp prove_tool_completed(entry) do
    script_model([
      {:tool_calls, [{"step_probe", %{"value" => "first"}}]},
      {:answer, ~s({"answer":"done"})}
    ])

    {_result, told} = observed_entry(entry, [])

    assert [
             {:tool_completed,
              %{id: "call-0-1", name: "step_probe", duration_ms: duration, ok?: true}}
           ] = model_tellings(told, :tool_completed)

    assert is_integer(duration) and duration >= 0
  end

  defp prove_tool_result_told(entry) do
    script_model([
      {:tool_calls, [{"step_probe", %{"value" => "first"}}]},
      {:answer, ~s({"answer":"done"})}
    ])

    {_result, told} = observed_entry(entry, [])
    assert [{:tool_completed, %{result: result}}] = model_tellings(told, :tool_completed)
    assert [_first, second] = model_bodies()
    assert [%{"call_id" => "call-0-1", "output" => ^result}] = tool_outputs(second)
  end

  defp prove_tool_call_timed_out(entry, opts) do
    script_model([
      {:tool_calls, [{"held_tool", %{"value" => "slow"}}]},
      {:answer, ~s({"answer":"done"})}
    ])

    started = System.monotonic_time(:millisecond)
    assert {:ok, _} = run_entry(entry, opts)

    assert System.monotonic_time(:millisecond) - started >=
             Keyword.get(opts, :tool_timeout_ms, Runner.default_limits().tool_timeout_ms)

    assert [_first, second] = model_bodies()
    assert [%{"output" => output}] = tool_outputs(second)
    assert %{"ok" => false} = Jason.decode!(output)
  end

  defp prove_timeout_reaches_model(entry, opts) do
    script_model([
      {:tool_calls, [{"held_tool", %{"value" => "slow"}}]},
      {:answer, ~s({"answer":"done"})}
    ])

    assert {:ok, _} = run_entry(entry, opts)
    assert [first, second] = model_bodies()
    assert user_prompt(first) == user_prompt(second)
    assert [%{"call_id" => "call-0-1", "output" => output}] = tool_outputs(second)
    assert %{"ok" => false, "error" => %{"type" => "timeout"}} = Jason.decode!(output)
  end

  defp prove_iteration_limit_failure(entry, opts) do
    script_model([{:always, {:tool_calls, [{"step_probe", %{"value" => "again"}}]}}])
    assert {:error, failure} = run_entry(entry, opts)
    assert step_failure(entry, failure) == :max_iterations
  end

  defp prove_requests_within_limit(entry, opts, limit) do
    script_model([{:always, {:tool_calls, [{"step_probe", %{"value" => "again"}}]}}])
    assert {:error, _} = run_entry(entry, opts)
    assert length(model_bodies()) == limit
  end

  defp prove_at_most_at_once(entry, opts, limit) do
    assert {{:ok, _}, peak} = held_round(entry, limit + 1, opts)
    assert peak <= limit
  end

  defp prove_as_many_at_once(entry, opts, limit) do
    assert {{:ok, _}, ^limit} = held_round(entry, limit + 1, opts)
  end

  defp prove_every_result_received(entry, opts, limit) do
    assert {{:ok, _}, _peak} = held_round(entry, limit + 1, opts)
    assert [first, second] = model_bodies()
    assert user_prompt(first) == user_prompt(second)

    assert Enum.map(tool_outputs(second), & &1["call_id"]) ==
             Enum.map(1..(limit + 1), &"call-0-#{&1}")
  end

  defp scripted_step do
    %{
      directions: "Answer the question.",
      output: %{"answer" => "string"},
      model: %{provider: :openai, id: "gpt-5"}
    }
  end

  defp scripted_reflection_step do
    %Gralkor.Reflection{
      name: "scripted",
      outputs: [],
      chain_of_thought: %Gralkor.Reflection.ChainOfThought{
        steps: [
          %Gralkor.Reflection.ChainOfThought.Step{
            label: "answer",
            directions: "Answer the question.",
            output: %{"answer" => "string"},
            model: %{provider: :openai, id: "gpt-5"}
          }
        ]
      }
    }
  end

  defp run_entry(entry, opts) do
    runner_opts =
      Keyword.merge(
        [tools: [StepProbe, HeldTool], tool_context: %{test_pid: self()}],
        opts
      )

    case entry do
      :reflection ->
        Runner.run(
          scripted_reflection_step(),
          %{id: "scripted-run", operator_id: "operator-one", representations: []},
          runner_opts
        )

      :step ->
        Runner.run_step(scripted_step(), %{}, runner_opts)
    end
  end

  defp observed_entry(entry, opts) do
    test_pid = self()
    result = run_entry(entry, Keyword.put(opts, :observer, &send(test_pid, {:told, &1})))
    {result, drain_tellings([])}
  end

  defp drain_tellings(acc) do
    receive do
      {:told, telling} -> drain_tellings([telling | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp model_tellings(told, kind), do: Enum.filter(told, &match?({^kind, _}, &1))

  defp step_failure(:reflection, %{reason: reason}), do: reason
  defp step_failure(:step, reason), do: reason

  defp held_round(entry, calls, opts) do
    script_model([
      {:tool_calls, Enum.map(1..calls, &{"held_tool", %{"value" => "held-#{&1}"}})},
      {:answer, ~s({"answer":"done"})}
    ])

    test_pid = self()

    task =
      Task.async(fn ->
        run_entry(entry, Keyword.put(opts, :tool_context, %{test_pid: test_pid}))
      end)

    peak = peak_running(calls, [], 0, 0)
    {Task.await(task, 30_000), peak}
  end

  defp peak_running(total, [], total, peak), do: peak

  defp peak_running(total, [], seen, peak) do
    receive do
      {:tool_running, _value, pid} -> peak_running(total, [pid], seen + 1, max(peak, 1))
    after
      10_000 -> flunk("#{seen} of #{total} tool calls ran")
    end
  end

  defp peak_running(total, running, seen, peak) do
    receive do
      {:tool_running, _value, pid} ->
        running = [pid | running]
        peak_running(total, running, seen + 1, max(peak, length(running)))
    after
      500 ->
        Enum.each(running, &send(&1, :release))
        peak_running(total, [], seen, peak)
    end
  end

  defp step_inference_request do
    test_pid = self()

    inference = fn request ->
      send(test_pid, {:step_inference_request, request})
      {:ok, %{output: %{"answer" => "done"}}}
    end

    assert {:ok, %{"answer" => "done"}} =
             Runner.run_step(scripted_step(), %{},
               inference: inference,
               tools: [StepProbe],
               tool_context: %{test_pid: test_pid}
             )

    assert_receive {:step_inference_request, request}
    request
  end

  defp step_directions(directions, values) do
    test_pid = self()

    inference = fn request ->
      send(test_pid, {:step_inference_request, request})
      {:ok, %{output: %{"answer" => "done"}}}
    end

    assert {:ok, _} =
             Runner.run_step(%{scripted_step() | directions: directions}, values,
               inference: inference
             )

    assert_receive {:step_inference_request, %{directions: received}}
    received
  end

  defp step_prompt(directions, values) do
    script_model([{:answer, ~s({"answer":"done"})}])

    assert {:ok, _} =
             Runner.run_step(%{scripted_step() | directions: directions}, values, [])

    assert [body] = model_bodies()
    user_prompt(body)
  end

  defp run_step_prompt(directions, schema) do
    """
    #{directions}

    Return only one JSON object satisfying this exact output contract:
    #{Jason.encode!(schema)}

    The quoted contract values are type declarations, not literal output
    values. Emit actual JSON values of those types. In particular, an object
    declaration such as "{ field: string }" requires a nested JSON object,
    and an Array<...> declaration requires a JSON array; do not quote either.
    """
  end

  defp script_model(replies) do
    _ = model_bodies()

    case Process.whereis(ScriptedModel) do
      nil ->
        previous = Req.default_options()
        Req.default_options(Keyword.put(previous, :adapter, ScriptedModel))
        on_exit(fn -> Req.default_options(previous) end)

        start_supervised!(%{
          id: ScriptedModel,
          start: {ScriptedModel, :start_link, [self(), replies]}
        })

      _pid ->
        ScriptedModel.replace(self(), replies)
    end
  end

  defp model_bodies(acc \\ []) do
    receive do
      {:scripted_model_request, body} -> model_bodies([body | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp user_prompt(body) do
    body["input"]
    |> Enum.filter(&(&1["role"] == "user"))
    |> Enum.map_join("\n", fn
      %{"content" => content} when is_binary(content) -> content
      %{"content" => parts} -> Enum.map_join(parts, "\n", & &1["text"])
    end)
  end

  defp tool_outputs(body), do: Enum.filter(body["input"], &(&1["type"] == "function_call_output"))

  defp deliver_personal_reflection do
    Application.put_env(:jido_gralkor, :destination_storage, Gralkor.Destination.Storage.InMemory)

    lessons = %{
      name: "lessons",
      outputs: [%{kind: :destination, destination: "personal"}],
      chain_of_thought: %{
        steps: [
          %{
            label: "derive-lesson",
            directions: "Derive a lesson.",
            output: %{"lesson" => "string"}
          }
        ]
      }
    }

    start_supervised!(
      {Runtime,
       owner: self(), configuration: %{destinations: [], lenses: [], reflections: [lessons]}}
    )

    parent = self()

    assert {:ok, "personal-reflection-invocation"} =
             Client.reflect(
               self(),
               "lessons",
               %{
                 id: "personal-reflection-invocation",
                 operator_id: "owner",
                 representations: [],
                 invocation_context: %{}
               },
               &send(parent, {:personal_reflection, &1}),
               inference: fn _request ->
                 {:ok, %{output: %{"lesson" => "separate recurring jobs"}}}
               end
             )

    assert_receive {:personal_reflection, %{outcome: :delivered, artefact: artefact}}, 1_000
    artefact
  end

  defp reflection(
         _context,
         name \\ "generalisation",
         destination \\ "personal"
       ) do
    resolve_reflection(
      valid_definition(
        name: name,
        outputs: [[kind: :destination, destination: destination]]
      )
    )
  end

  defp destination_output(reflection),
    do: Enum.find(reflection.outputs, &(&1.kind == :destination))

  defp put_artefact(reflection, operator_id, artefact, opts) do
    Gralkor.Destination.Storage.put_artefact(
      destination_output(reflection),
      reflection.name,
      operator_id,
      artefact,
      opts
    )
  end

  defp one_step_reflection(_context) do
    resolve_reflection(
      valid_definition(
        chain_of_thought: %{
          steps: [
            %{
              label: "reflect",
              directions: "Reflect.",
              output: %{"artefact" => "string"}
            }
          ]
        }
      )
    )
  end

  defp invocation do
    %{
      id: "ingestion-1",
      operator_id: "operator-one",
      invocation_context: %{source: "direct-invocation"},
      representations: [
        %{
          id: "representation-one",
          lens: "observations",
          content: "fact one",
          result: :ok
        },
        %{
          id: "representation-two",
          lens: "decisions",
          content: "fact two",
          result: :ok
        }
      ]
    }
  end

  defp async_reflection_configuration(destination \\ "reviews") do
    %{
      destinations: [%{name: destination}],
      lenses: [],
      reflections: [
        %{
          name: "review",
          outputs: [%{kind: :destination, destination: destination}],
          chain_of_thought: %{
            steps: [
              %{
                label: "review",
                directions: "Review supplied information.",
                output: %{"summary" => "string"}
              }
            ]
          }
        }
      ]
    }
  end

  defp async_reflection_invocation(id \\ "reflection-invocation-one") do
    %{
      id: id,
      operator_id: "operator-one",
      invocation_context: %{},
      representations: []
    }
  end

  defp submit_successful_reflection(invocation_id) do
    Application.put_env(:jido_gralkor, :destination_storage, OutputProbeStorage)

    agent_server =
      start_supervised!(
        {Jido.AgentServer, agent: AsyncConsumerAgent, id: invocation_id, register_global: false}
      )

    assert :ok = Runtime.replace(agent_server, async_reflection_configuration())

    test_pid = self()
    callback = &send(test_pid, {:successful_reflection_callback, &1})

    assert {:ok, ^invocation_id} =
             Client.reflect(
               agent_server,
               "review",
               async_reflection_invocation(invocation_id),
               callback,
               inference: fn _ -> {:ok, %{output: %{"summary" => "complete"}}} end
             )

    assert_receive {:destination_output_delivered, _output, "review", "operator-one", artefact}
    assert_receive {:successful_reflection_callback, result}
    {artefact, result}
  end

  defp submit_failed_reflection(invocation_id) do
    Application.put_env(:jido_gralkor, :destination_storage, OutputProbeStorage)

    agent_server =
      start_supervised!(
        {Jido.AgentServer, agent: AsyncConsumerAgent, id: invocation_id, register_global: false}
      )

    assert :ok = Runtime.replace(agent_server, async_reflection_configuration())

    test_pid = self()

    assert {:ok, ^invocation_id} =
             Client.reflect(
               agent_server,
               "review",
               async_reflection_invocation(invocation_id),
               &send(test_pid, {:failed_reflection_callback, &1}),
               inference: fn _ -> {:error, :provider_unavailable} end
             )

    assert_receive {:failed_reflection_callback, result}
    refute_receive {:destination_output_delivered, _, _, _, _}
    result
  end

  defp output_for(%{step: %{label: "gather"}}), do: {:ok, %{output: %{"facts" => ["fact one"]}}}

  defp output_for(%{step: %{label: "synthesise"}}),
    do: {:ok, %{output: %{"artefact" => "durable pattern"}}}

  defp output_for(%{step: %{label: "reflect"}}),
    do: {:ok, %{output: %{"artefact" => "durable pattern"}}}

  defp prepend_directions(reflection, label, text) do
    steps =
      Enum.map(reflection.chain_of_thought.steps, fn
        %{label: ^label} = step -> %{step | directions: text <> step.directions}
        step -> step
      end)

    put_in(reflection.chain_of_thought.steps, steps)
  end

  defp synthesise_directions(reflection, facts) do
    parent = self()

    inference = fn
      %{step: %{label: "gather"}} ->
        {:ok, %{output: %{"facts" => facts}}}

      %{step: %{label: "synthesise", directions: directions}} ->
        send(parent, {:synthesise_directions, directions})
        {:ok, %{output: %{"artefact" => "done"}}}
    end

    assert {:ok, _} =
             Runner.run(reflection, invocation(),
               inference: inference,
               artefact_id_for: fn _, _, _ -> "artefact" end
             )

    assert_receive {:synthesise_directions, directions}
    directions
  end

  defp run_and_collect_requests(reflection, invocation) do
    parent = self()

    inference = fn request ->
      send(parent, {:request, request})
      output_for(request)
    end

    assert {:ok, _} = Runner.run(reflection, invocation, inference: inference)
    collect_requests([])
  end

  defp collect_requests(acc) do
    receive do
      {:request, request} -> collect_requests(acc ++ [request])
    after
      0 -> acc
    end
  end

  defp tool_calling_inference(parent, total_calls) do
    fn request ->
      count = length(request.tool_results)

      if count < total_calls do
        call =
          if total_calls == 1,
            do: %{name: "memory_search", arguments: %{"query" => "pattern"}},
            else: %{name: "tool-#{count + 1}", arguments: %{}}

        {:ok, %{tool_calls: [call]}}
      else
        send(
          parent,
          {:continued, request.step.label, Enum.map(request.tool_results, &%{result: &1.result})}
        )

        send(parent, {:continued_tools, request.step.label, request.tools})
        {:ok, %{output: %{"artefact" => "done"}}}
      end
    end
  end

  defp stored_artefact(context) do
    reflection = reflection(context)
    {:ok, artefact} = Runner.run(reflection, invocation(), inference: &output_for/1)

    :ok =
      put_artefact(reflection, "operator-one", artefact,
        storage: Gralkor.Destination.Storage.InMemory
      )

    {reflection, artefact}
  end

  defp valid_definition(overrides \\ []) do
    Keyword.merge(
      [
        name: "generalisation",
        chain_of_thought: %{
          steps: [
            %{
              label: "gather",
              directions: "Gather facts.",
              output: %{"facts" => "Array<string>"}
            },
            %{
              label: "synthesise",
              directions: "Synthesise {{facts}}",
              output: %{"artefact" => "string"}
            }
          ]
        },
        outputs: [[kind: :destination, destination: "personal"]]
      ],
      overrides
    )
  end

  defp validate_reflections(reflections) do
    Runtime.validate(runtime_configuration(reflections))
  end

  defp resolve_reflection(definition) do
    with_runtime(runtime_configuration([definition]), fn owner ->
      Runtime.reflection!(owner, definition_name(definition))
    end)
  end

  defp definition_name(definition) when is_list(definition), do: Keyword.fetch!(definition, :name)

  defp definition_name(definition) when is_map(definition),
    do: Map.get(definition, :name) || Map.fetch!(definition, "name")

  defp with_runtime(configuration, fun) do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, runtime} = Runtime.start_link(owner: owner, configuration: configuration)

    try do
      fun.(owner)
    after
      GenServer.stop(runtime)
      send(owner, :stop)
    end
  end

  defp runtime_configuration(reflections) do
    %{
      destinations: [
        %{name: "reflection-test"},
        %{name: "observations"},
        %{name: "decisions"}
      ],
      lenses: [],
      reflections: reflections
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)

  defp expected_step_prompt(directions, representations, schema) do
    """
    #{directions}

    Lensed representations available to this Reflection step:
    #{Jason.encode!(representations)}

    Return only one JSON object satisfying this exact output contract:
    #{Jason.encode!(schema)}

    The quoted contract values are type declarations, not literal output
    values. Emit actual JSON values of those types. In particular, an object
    declaration such as "{ field: string }" requires a nested JSON object,
    and an Array<...> declaration requires a JSON array; do not quote either.
    """
  end

  defp scripted_reflection(turns) do
    schema = %{"answer" => "string"}

    first = %Gralkor.Reflection.ChainOfThought.Step{
      label: "inspect",
      directions: "Inspect evidence.",
      output: schema
    }

    last = %Gralkor.Reflection.ChainOfThought.Step{
      label: "finish",
      directions: "Conclude {{answer}}",
      output: %{"conclusion" => "string"}
    }

    reflection = %Gralkor.Reflection{
      name: "runtime-contract",
      outputs: [],
      chain_of_thought: %Gralkor.Reflection.ChainOfThought{steps: [first, last]}
    }

    Jido.AI.Test.ReActScript.new(%{
      user: expected_step_prompt(first.directions, [], schema),
      turns: turns
    })
    |> Jido.AI.Test.ReActScript.register()

    on_exit(fn -> Jido.AI.Test.ReActScript.clear_current_owner() end)
    {reflection, %{id: "runtime-contract", operator_id: "operator-one", representations: []}}
  end

  defp run_observed_reflection(turns, answer \\ "ready") do
    {reflection, invocation} = scripted_reflection(turns)

    register_step("Conclude " <> answer, [], %{"conclusion" => "string"}, [
      %{type: :answer, text: ~s({"conclusion":"done"})}
    ])

    Runner.run(reflection, invocation,
      tools: [ReflectionProbe],
      tool_context: %{test_pid: self(), operator_id: "wrong-operator", tenant: "kept"},
      inference: fn request ->
        Runner.default_inference(request, fn prompt, config, opts ->
          Jido.AI.Reasoning.ReAct.run(
            prompt,
            Map.put(config, :request_transformer, RequestProbe),
            opts
          )
        end)
      end
    )
  end

  defp step_request do
    %{
      directions: "Use memory.",
      output_schema: %{"artefact" => "string"},
      representations: [],
      tools: [],
      tool_context: %{},
      operator_id: "operator-one"
    }
  end

  defp step_call(request) do
    parent = self()

    call = fn prompt, config, _opts ->
      send(parent, {:step_call, %{prompt: prompt, model: config.model}})
      %{termination_reason: :final_answer, result: ~s({"artefact":"done"})}
    end

    assert {:ok, %{output: %{"artefact" => "done"}}} = Runner.default_inference(request, call)
    assert_receive {:step_call, observed}
    observed
  end

  defp step_config(request, opts) do
    parent = self()

    call = fn _prompt, config, _opts ->
      send(parent, {:step_config, config})
      %{termination_reason: :final_answer, result: ~s({"artefact":"done"})}
    end

    assert {:ok, %{output: %{"artefact" => "done"}}} =
             Runner.default_inference(request, call, opts)

    assert_receive {:step_config, config}
    config
  end

  defp register_step(directions, representations, schema, turns) do
    Jido.AI.Test.ReActScript.new(%{
      user: expected_step_prompt(directions, representations, schema),
      turns: turns
    })
    |> Jido.AI.Test.ReActScript.register()

    on_exit(fn -> Jido.AI.Test.ReActScript.clear_current_owner() end)
  end

  defp model_requests(acc \\ []) do
    receive do
      {:model_request, messages} -> model_requests([messages | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp tool_turn(value),
    do: %{type: :tool_call, name: "reflection_probe", arguments: %{value: value}}

  defp answer_turn(answer), do: %{type: :answer, text: Jason.encode!(%{answer: answer})}

  defp exhausted_turns,
    do: Enum.map(1..11, &tool_turn("round-#{&1}")) ++ [answer_turn("too late")]
end
