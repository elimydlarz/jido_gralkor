defmodule Gralkor.Reflection.RunnerTest do
  use ExUnit.Case, async: false

  alias Gralkor.Artefact
  alias Gralkor.Destination
  alias Gralkor.IngestedRepresentation
  alias Gralkor.Reflection
  alias Gralkor.Reflection.ChainOfThought
  alias Gralkor.Reflection.ChainOfThought.Step

  defmodule Runner do
    def run(reflection, invocation, opts \\ []) do
      Gralkor.Reflection.Runner.run(
        reflection,
        invocation,
        Keyword.merge(
          [
            type_matcher: fn
              "ready", "string" -> true
              "collected", "string" -> true
              "gathered evidence", "string" -> true
              "ship", "string" -> true
              3, "integer" -> true
              _value, _type -> false
            end,
            artefact_id_for: fn
              "operator-one", "invocation-one", "review" -> "unit-artefact-id"
            end
          ],
          opts
        )
      )
    end

    def default_inference(request, caller),
      do: Gralkor.Reflection.Runner.default_inference(request, caller, model_options())

    def default_inference(request, caller, opts),
      do:
        Gralkor.Reflection.Runner.default_inference(
          request,
          caller,
          Keyword.merge(model_options(), opts)
        )

    defp model_options,
      do: [model_resolver: fn -> %{provider: "openai", id: "runner-contract-model"} end]
  end

  defmodule LookupTool do
    use Jido.Action,
      name: "lookup",
      description: "Looks up stored evidence.",
      schema: [query: [type: :string, required: true]]

    @impl true
    def run(%{query: query}, _context), do: {:ok, %{evidence: query}}
  end

  defmodule EvidenceTool do
    use Jido.Action,
      name: "lookup_evidence",
      description: "Looks up stored evidence.",
      schema: [query: [type: :string, required: true]]

    @impl true
    def run(%{query: query}, _context) do
      send(:reflection_runner_test, {:tool_ran, query})
      {:ok, %{evidence: "stored-evidence"}}
    end
  end

  defmodule DroppingOpenAI do
    def run(request) do
      send(:reflection_runner_test, :model_call)
      body = IO.iodata_to_binary(request.body)

      cond do
        not String.contains?(body, "stored-evidence") ->
          {request,
           response(%{
             "type" => "function_call",
             "id" => "fc-1",
             "call_id" => "call-1",
             "name" => "lookup_evidence",
             "arguments" => ~s({"query":"deploys"}),
             "status" => "completed"
           })}

        Agent.get_and_update(__MODULE__, &{&1, &1 - 1}) > 0 ->
          {request, Req.TransportError.exception(reason: :closed)}

        true ->
          {request,
           response(%{
             "type" => "message",
             "id" => "msg-1",
             "role" => "assistant",
             "status" => "completed",
             "content" => [
               %{"type" => "output_text", "text" => ~s({"answer":"ready"}), "annotations" => []}
             ]
           })}
      end
    end

    defp response(output) do
      Req.Response.new(
        status: 200,
        headers: [{"content-type", "application/json"}],
        body:
          Jason.encode!(%{
            "id" => "resp-1",
            "object" => "response",
            "model" => "gpt-4.1",
            "status" => "completed",
            "output" => [output],
            "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
          })
      )
    end
  end

  defmodule ProbeDestinationStorage do
    @behaviour Gralkor.Destination.Storage

    @impl true
    def search(destination, operator_id, query, opts) do
      send(:reflection_runner_test, {:destination_search, destination, operator_id, query, opts})

      {:ok, %{facts: [], nodes: [], episodes: []}}
    end

    @impl true
    def put_artefact(output, reflection_name, operator_id, artefact) do
      send(
        :reflection_runner_test,
        {:destination_delivery, output, reflection_name, operator_id, artefact}
      )

      :ok
    end
  end

  setup do
    Process.register(self(), :reflection_runner_test)
    previous_storage = Application.get_env(:jido_gralkor, :destination_storage)
    previous_model = System.get_env("GRALKOR_LLM_MODEL")
    Application.put_env(:jido_gralkor, :destination_storage, ProbeDestinationStorage)

    on_exit(fn ->
      restore_application_env(:destination_storage, previous_storage)
      restore_system_env("GRALKOR_LLM_MODEL", previous_model)
    end)

    :ok
  end

  describe "when the Reflection Runner receives a valid Reflection and invocation" do
    test "then the first ordered Chain of Thought step begins" do
      assert {:ok, %Artefact{}} = run_successful_sequence()
      assert_receive {:inference_request, %{step: %{label: "collect"}}}
      assert_receive {:inference_request, %{step: %{label: "decide"}}}
    end

    test "and every step request carries the Reflection name, operator, invocation identifier, and invocation context" do
      prove_step_request_identity()
    end

    test "and completed representations retain exactly their identifier, Lens, content, and storage result" do
      prove_step_request_representations()
    end

    test "and the request carries the supplied tools and tool context" do
      prove_step_request_tools()
    end

    test "and only the current step is exposed to inference" do
      prove_only_current_step_is_exposed()
    end
  end

  describe "when the Reflection Runner receives a valid Reflection and invocation > where a model resolver is supplied without a consumer inference function" do
    test "then every step's built-in inference runs the model that resolver names" do
      test_pid = self()

      reflection = %Reflection{
        name: "resolved-model",
        outputs: [],
        chain_of_thought: %ChainOfThought{
          steps: [
            %Step{label: "gather", directions: "Gather.", output: %{"facts" => "string"}},
            %Step{
              label: "conclude",
              directions: "Conclude from {{facts}}.",
              output: %{"answer" => "string"}
            }
          ]
        }
      }

      script_step("Gather.", %{"facts" => "string"}, ~s({"facts":"known"}))
      script_step("Conclude from known.", %{"answer" => "string"}, ~s({"answer":"ready"}))

      resolver = fn ->
        send(test_pid, :model_resolved)
        %{provider: "openai", id: "gpt-6-luna"}
      end

      assert {:ok, %Artefact{payload: %{"answer" => "ready"}}} =
               Gralkor.Reflection.Runner.run(
                 reflection,
                 %{id: "resolved-model-run", operator_id: "operator-one", representations: []},
                 model_resolver: resolver
               )

      assert_received :model_resolved
      assert_received :model_resolved
    end
  end

  describe "when the Reflection Runner receives a valid Reflection and invocation > where a step names a model without a consumer inference function" do
    test "then that step's built-in inference runs the model the step names instead of the resolver's" do
      test_pid = self()

      reflection = %Reflection{
        name: "step-model",
        outputs: [],
        chain_of_thought: %ChainOfThought{
          steps: [
            %Step{
              label: "gather",
              directions: "Gather.",
              output: %{"facts" => "string"},
              model: %{provider: "openai", id: "step-model"}
            },
            %Step{
              label: "conclude",
              directions: "Conclude from {{facts}}.",
              output: %{"answer" => "string"}
            }
          ]
        }
      }

      script_step("Gather.", %{"facts" => "string"}, ~s({"facts":"known"}))
      script_step("Conclude from known.", %{"answer" => "string"}, ~s({"answer":"ready"}))

      resolver = fn ->
        send(test_pid, :model_resolved)
        %{provider: "openai", id: "gpt-6-luna"}
      end

      assert {:ok, %Artefact{payload: %{"answer" => "ready"}}} =
               Gralkor.Reflection.Runner.run(
                 reflection,
                 %{id: "step-model-run", operator_id: "operator-one", representations: []},
                 model_resolver: resolver
               )

      assert_received :model_resolved
      refute_received :model_resolved
    end
  end

  describe "when the Reflection Runner receives a valid Reflection and invocation > where a step names a model or a reasoning effort" do
    test "then that step's request carries the model and reasoning effort it names" do
      test_pid = self()
      model = %{provider: "openai", id: "step-model"}

      steps = [
        %Step{
          label: "collect",
          directions: "Collect evidence.",
          output: %{"evidence" => "string"},
          model: model,
          reasoning_effort: :high
        },
        %Step{
          label: "decide",
          directions: "Decide from {{evidence}}.",
          output: %{"answer" => "string", "confidence" => "integer"}
        }
      ]

      inference = fn request ->
        send(test_pid, {:step_request, request.step})
        {:ok, output_for(request)}
      end

      assert {:ok, %Artefact{}} =
               Runner.run(reflection(steps), invocation(), inference: inference)

      assert_received {:step_request, first}

      assert first == %{
               label: "collect",
               directions: "Collect evidence.",
               model: model,
               reasoning_effort: :high
             }

      assert_received {:step_request, second}
      assert second == %{label: "decide", directions: "Decide from gathered evidence."}
    end
  end

  describe "when the Reflection Runner receives a valid Reflection and invocation > where an observer is supplied" do
    test "then the observer is told each step's label as that step starts" do
      assert {:ok, %Artefact{}} = run_successful_sequence(observer: observer())

      assert observed_sequence() == [
               {:observed, {:step_started, "collect"}},
               {:inference, "collect"},
               {:observed, {:step_finished, "collect"}},
               {:observed, {:step_started, "decide"}},
               {:inference, "decide"},
               {:observed, {:step_finished, "decide"}}
             ]
    end

    test "and every step's built-in inference tells the observer of its tool calls" do
      reflection = %Reflection{
        name: "tool-observed",
        outputs: [],
        chain_of_thought: %ChainOfThought{
          steps: [
            %Step{label: "look", directions: "Look it up.", output: %{"answer" => "string"}}
          ]
        }
      }

      script_tool_step("Look it up.", %{"answer" => "string"}, "deploys", ~s({"answer":"ready"}))

      assert {:ok, %Artefact{payload: %{"answer" => "ready"}}} =
               Gralkor.Reflection.Runner.run(
                 reflection,
                 %{id: "tool-observed-run", operator_id: "operator-one", representations: []},
                 model_resolver: fn -> %{provider: "openai", id: "runner-contract-model"} end,
                 tools: [LookupTool],
                 observer: observer(),
                 type_matcher: fn "ready", "string" -> true end,
                 artefact_id_for: fn _operator, _invocation, _name -> "tool-observed-artefact" end
               )

      assert_received {:observed, {:tool_started, %{name: "lookup", arguments: arguments}}}
      assert arguments["query"] == "deploys"
      assert_received {:observed, {:tool_completed, %{name: "lookup", ok?: true}}}
    end
  end

  describe "when the Reflection Runner receives a valid Reflection and invocation > where an observer is supplied > when a step's output satisfies its contract" do
    test "then the observer is told that step's label as it finishes" do
      assert {:ok, %Artefact{}} = run_successful_sequence(observer: observer())

      sequence = observed_sequence()

      assert Enum.find_index(sequence, &(&1 == {:observed, {:step_finished, "collect"}})) ==
               Enum.find_index(sequence, &(&1 == {:inference, "collect"})) + 1
    end
  end

  describe "when the Reflection Runner receives a valid Reflection and invocation > where an observer is supplied > if a step fails" do
    test "then the observer is told that step's label as it fails" do
      test_pid = self()

      inference = fn
        %{step: %{label: "collect"}} = request ->
          send(test_pid, {:inference_request, request})
          {:ok, output_for(request)}

        %{step: %{label: "decide"}} = request ->
          send(test_pid, {:inference_request, request})
          {:error, :provider_down}
      end

      assert {:error, %{step: "decide", reason: :provider_down}} =
               Runner.run(reflection(sequence_steps()), invocation(),
                 inference: inference,
                 observer: observer()
               )

      assert observed_sequence() == [
               {:observed, {:step_started, "collect"}},
               {:inference, "collect"},
               {:observed, {:step_finished, "collect"}},
               {:observed, {:step_started, "decide"}},
               {:inference, "decide"},
               {:observed, {:step_failed, "decide"}}
             ]

      assert {:error, %{step: "collect", reason: {:unexpected_output, "extra"}}} =
               Runner.run(reflection(sequence_steps()), invocation(),
                 inference:
                   inference_answering(%{"evidence" => "gathered evidence", "extra" => "x"}),
                 observer: observer()
               )

      assert [
               {:observed, {:step_started, "collect"}},
               {:inference, "collect"},
               {:observed, {:step_failed, "collect"}}
             ] =
               observed_sequence()

      assert {:error, %{reason: :missing_artefact}} =
               Runner.run(single_step_reflection(), invocation(),
                 inference: inference_answering(%{}),
                 observer: observer()
               )

      assert [
               {:observed, {:step_started, "finish"}},
               {:inference, "finish"},
               {:observed, {:step_failed, "finish"}}
             ] =
               observed_sequence()
    end
  end

  describe "where a step's directions reference earlier outputs" do
    test "then those values are interpolated from the shared output space" do
      assert {:ok, %Artefact{}} = run_successful_sequence()
      assert_receive {:inference_request, %{step: %{label: "collect"}}}

      assert_receive {:inference_request,
                      %{
                        step: %{
                          label: "decide",
                          directions: "Decide from gathered evidence."
                        }
                      }}
    end
  end

  describe "where inference returns wrapped tool calls" do
    test "then each call is executed with its model-produced arguments and the current tool context" do
      prove_tool_call_execution()
    end

    test "and each result is returned to inference within the same step" do
      prove_tool_result_return()
    end

    test "and further calls continue that step in sequence" do
      prove_sequential_tool_calls()
    end
  end

  describe "where inference returns wrapped tool calls > if a requested tool is not among the supplied tools" do
    test "then the unknown tool name is returned to inference as that call's result" do
      test_pid = self()
      call = %{name: "missing_tool", arguments: %{"query" => "deployment"}}

      inference = fn
        %{tool_results: []} ->
          {:ok, %{tool_calls: [call]}}

        %{tool_results: results} ->
          send(test_pid, {:returned_tool_results, results})
          {:ok, %{output: %{"answer" => "ready"}}}
      end

      assert {:ok, %Artefact{}} =
               Runner.run(single_step_reflection(), invocation(),
                 inference: inference,
                 tools: [LookupTool],
                 tool_context: %{session_id: "thread-one"}
               )

      assert_receive {:returned_tool_results,
                      [%{call: ^call, result: {:error, {:unknown_tool, "missing_tool"}}}]}
    end
  end

  describe "when inference returns wrapped structured output satisfying the current step's exact contract" do
    test "then that output is added to the shared output space" do
      test_pid = self()

      reflection =
        reflection([
          step("collect", "Collect evidence.", %{"evidence" => "string"}),
          step("decide", "Decide.", %{"answer" => "string"}),
          step("finish", "Finish with {{ evidence }} and {{ answer }}.", %{
            "confidence" => "integer"
          })
        ])

      inference = fn
        %{step: %{label: "collect"}} ->
          {:ok, %{output: %{"evidence" => "gathered evidence"}}}

        %{step: %{label: "decide"}} ->
          {:ok, %{output: %{"answer" => "ship"}}}

        %{step: %{label: "finish", directions: directions}} ->
          send(test_pid, {:finish_directions, directions})
          {:ok, %{output: %{"confidence" => 3}}}
      end

      assert {:ok, %Artefact{payload: %{"confidence" => 3}}} =
               Runner.run(reflection, invocation(), inference: inference)

      assert_receive {:finish_directions, "Finish with gathered evidence and ship."}
    end

    test "and the next step begins with it available for interpolation" do
      assert {:ok, %Artefact{}} = run_successful_sequence()
      assert_receive {:inference_request, %{step: %{label: "collect"}}}

      assert_receive {:inference_request,
                      %{directions: "Decide from gathered evidence.", step: %{label: "decide"}}}
    end
  end

  describe "if inference omits a declared output > while the step is not the final step" do
    test "then the Runner failure identifies the Reflection, step, and missing key" do
      reflection =
        reflection([
          step("collect", "Collect.", %{"required" => "string"}),
          step("finish", "Finish.", %{"answer" => "string"})
        ])

      assert {:error,
              %{
                reflection: "review",
                step: "collect",
                reason: {:missing_output, "required"}
              }} =
               Runner.run(reflection, invocation(),
                 inference: fn _request -> {:ok, %{output: %{}}} end
               )
    end
  end

  describe "if inference omits a declared output > while the step is the final step" do
    test "then the Runner failure identifies the Reflection and missing artefact" do
      inference = fn
        %{step: %{label: "collect"}} -> {:ok, %{output: %{"evidence" => "gathered evidence"}}}
        %{step: %{label: "decide"}} -> {:ok, %{output: %{"confidence" => 3}}}
      end

      assert {:error, failure} =
               Runner.run(reflection(sequence_steps()), invocation(), inference: inference)

      assert failure == %{reflection: "review", reason: :missing_artefact}
    end
  end

  describe "if inference returns an undeclared output" do
    test "then the Runner failure identifies the Reflection, step, and unexpected key" do
      reflection = reflection([step("collect", "Collect.", %{"summary" => "string"})])

      assert {:error,
              %{
                reflection: "review",
                step: "collect",
                reason: {:unexpected_output, "extra"}
              }} =
               Runner.run(reflection, invocation(),
                 inference: fn _request ->
                   {:ok, %{output: %{"summary" => "ready", "extra" => "undeclared"}}}
                 end
               )
    end
  end

  describe "if inference returns a value of the wrong declared type" do
    test "then the Runner failure identifies the Reflection, step, key, and type" do
      reflection = reflection([step("score", "Score.", %{"count" => "integer"})])
      test_pid = self()

      assert {:error,
              %{
                reflection: "review",
                step: "score",
                reason: {:output_type_mismatch, "count", "integer"}
              }} =
               Runner.run(reflection, invocation(),
                 inference: fn _request -> {:ok, %{output: %{"count" => "many"}}} end,
                 type_matcher: fn value, type ->
                   send(test_pid, {:type_match, value, type})
                   false
                 end
               )

      assert_receive {:type_match, "many", "integer"}
    end
  end

  describe "when the final step returns valid wrapped structured output" do
    test "then the Runner returns one producer-independent artefact" do
      assert {:ok, %Artefact{id: id, payload: payload}} = run_successful_sequence()
      assert is_binary(id)
      assert payload == %{"answer" => "ship", "confidence" => 3}
    end

    test "and its identifier is derived from the operator, invocation, and Reflection identity" do
      test_pid = self()

      assert {:ok, %Artefact{id: "injected-id"}} =
               run_successful_sequence(
                 artefact_id_for: fn operator_id, invocation_id, reflection_name ->
                   send(test_pid, {:artefact_id_for, operator_id, invocation_id, reflection_name})
                   "injected-id"
                 end
               )

      assert_receive {:artefact_id_for, "operator-one", "invocation-one", "review"}
    end

    test "and its payload contains exactly the final step's outputs" do
      assert {:ok, %Artefact{payload: payload}} = run_successful_sequence()
      assert payload == %{"answer" => "ship", "confidence" => 3}
      refute Map.has_key?(payload, "evidence")
    end

    test "and the Runner performs no Destination delivery" do
      assert {:ok, %Artefact{}} = run_successful_sequence()
      refute_receive {:destination_delivery, _, _, _, _}
    end
  end

  describe "if inference fails or returns an invalid response" do
    test "then the Runner failure identifies the Reflection, current step, and reason" do
      prove_inference_failures_are_identified()
    end
  end

  describe "when built-in inference is invoked for a step" do
    test "then it runs through Jido's standalone ReAct runtime with the directions, exact output contract, and representations" do
      prove_built_in_inference_request()
    end

    test "and the representations and output contract remain JSON" do
      prove_representations_and_contract_json()
    end

    test "and it supplies the host tools and a tool context whose operator identity comes from the invocation while every other supplied field remains unchanged" do
      prove_built_in_inference_context()
    end

    test "and a final JSON object is returned as wrapped structured output" do
      prove_wrapped_structured_output()
    end

    test "and each model call may produce up to 32,768 output tokens" do
      assert built_in_config(default_inference_request(), []).max_tokens == 32_768
    end
  end

  describe "when built-in inference is invoked for a step > where a model resolver is supplied" do
    test "then it runs the model that resolver names" do
      assert built_in_config(default_inference_request(),
               model_resolver: fn -> %{provider: "openai", id: "runner-contract-model"} end
             ).model == "openai:runner-contract-model"
    end
  end

  describe "when built-in inference is invoked for a step > where no model resolver is supplied" do
    test "then it runs Gralkor's configured LLM model" do
      configured = Gralkor.Config.llm_model()

      assert built_in_config(default_inference_request(), []).model ==
               "#{configured.provider}:#{configured.id}"
    end
  end

  describe "when built-in inference is invoked for a step > where a reasoning effort is supplied" do
    test "then every model call asks the model for that reasoning effort" do
      assert built_in_config(default_inference_request(), reasoning_effort: :low).llm_opts ==
               [reasoning_effort: :low]
    end
  end

  describe "when built-in inference is invoked for a step > where no reasoning effort is supplied" do
    test "then no model call names a reasoning effort" do
      refute Map.has_key?(built_in_config(default_inference_request(), []), :llm_opts)
    end
  end

  describe "when built-in inference is invoked for a step > where the step names a model" do
    test "then it runs the model the step names" do
      request =
        Map.put(default_inference_request(), :step, %{
          label: "use",
          directions: "Use the evidence.",
          model: %{provider: "openai", id: "step-model"}
        })

      assert built_in_config(request,
               model_resolver: fn -> %{provider: "openai", id: "runner-contract-model"} end
             ).model == "openai:step-model"
    end
  end

  describe "when built-in inference is invoked for a step > where the step names a reasoning effort" do
    test "then every model call asks the model for the reasoning effort the step names" do
      request =
        Map.put(default_inference_request(), :step, %{
          label: "use",
          directions: "Use the evidence.",
          reasoning_effort: :high
        })

      assert built_in_config(request, reasoning_effort: :low).llm_opts ==
               [reasoning_effort: :high]
    end
  end

  describe "when built-in inference is invoked for a step > if the provider fails or returns invalid JSON or a non-object JSON value" do
    test "then built-in inference returns the identified error" do
      prove_built_in_inference_errors()
    end
  end

  describe "when built-in inference is invoked for a step > where an observer is supplied > when the ReAct runtime starts a tool call" do
    test "then the observer is told the call's identifier, tool name, and arguments" do
      emit_through_built_in_inference(
        react_event(:tool_started, data: %{arguments: %{"query" => "deploys"}})
      )

      assert_received {:observed,
                       {:tool_started,
                        %{id: "call-1", name: "lookup", arguments: %{"query" => "deploys"}}}}
    end
  end

  describe "when built-in inference is invoked for a step > where an observer is supplied > when the ReAct runtime completes a tool call" do
    test "then the observer is told the call's identifier, tool name, duration, and whether it succeeded" do
      emit_through_built_in_inference(
        react_event(:tool_completed,
          data: %{result: {:ok, %{evidence: "x"}, []}, duration_ms: 12}
        )
      )

      emit_through_built_in_inference(
        react_event(:tool_completed, data: %{result: {:error, :timeout}, duration_ms: 30})
      )

      assert_received {:observed,
                       {:tool_completed,
                        %{id: "call-1", name: "lookup", duration_ms: 12, ok?: true}}}

      assert_received {:observed,
                       {:tool_completed,
                        %{id: "call-1", name: "lookup", duration_ms: 30, ok?: false}}}
    end
  end

  describe "when built-in inference is invoked for a step > where an observer is supplied > when the ReAct runtime emits any other event" do
    test "then the observer is told nothing" do
      emit_through_built_in_inference(react_event(:llm_delta, data: %{delta: "thinking"}))

      refute_received {:observed, _event}
    end
  end

  describe "when built-in inference is invoked for a step > if the ReAct runtime ends without a final answer" do
    test "then built-in inference returns its termination reason as an error" do
      request = default_inference_request()

      for termination_reason <- [:max_iterations, :cancelled, :completed, nil] do
        assert {:error, ^termination_reason} =
                 Runner.default_inference(request, fn _action, _args, _context ->
                   %{termination_reason: termination_reason, result: nil}
                 end)
      end
    end
  end

  describe "when built-in inference is invoked for a step > if a model call's connection is closed, times out, or is refused before any HTTP status arrives" do
    test "then that model call is made again after 1 second, then 2, then 4, at most three more times" do
      substitute_retry_sleep()

      for reason <- [:closed, :timeout, :econnrefused] do
        assert {:error, _} =
                 Runner.default_inference(
                   default_inference_request(),
                   failing_model_call(dropped_connection(reason))
                 )

        assert drain_messages() == [
                 :model_call,
                 {:retry_sleep, 1_000},
                 :model_call,
                 {:retry_sleep, 2_000},
                 :model_call,
                 {:retry_sleep, 4_000},
                 :model_call
               ]
      end
    end

    test "and the model calls and tool calls that already finished in that step are not repeated" do
      substitute_retry_sleep()

      start_supervised!(%{
        id: DroppingOpenAI,
        start: {Agent, :start_link, [fn -> 4 end, [name: DroppingOpenAI]]}
      })

      caller = fn input, config, opts ->
        Gralkor.Reflection.Runner.react(
          input,
          Map.merge(config, %{
            req_http_options: [adapter: DroppingOpenAI],
            llm_opts: [api_key: "runner-contract-key"]
          }),
          opts
        )
      end

      assert {:ok, %{output: %{"answer" => "ready"}}} =
               Runner.default_inference(
                 %{default_inference_request() | tools: [EvidenceTool]},
                 caller,
                 model_resolver: fn -> %{provider: "openai", id: "gpt-4.1"} end
               )

      assert drain_messages() == [
               :model_call,
               {:tool_ran, "deploys"},
               :model_call,
               :model_call,
               :model_call,
               :model_call,
               {:retry_sleep, 1_000},
               :model_call
             ]
    end
  end

  describe "when built-in inference is invoked for a step > if a model call's connection is closed, times out, or is refused before any HTTP status arrives > if the connection fails on every attempt" do
    test "then built-in inference returns the connection error" do
      substitute_retry_sleep()
      error = dropped_connection(:closed)

      assert {:error, ^error} =
               Runner.default_inference(default_inference_request(), failing_model_call(error))
    end
  end

  describe "when built-in inference is invoked for a step > if a model call fails with an HTTP status" do
    test "then built-in inference returns the error without calling the model again" do
      substitute_retry_sleep()

      for status <- [429, 500, 503] do
        error =
          ReqLLM.Error.API.Request.exception(reason: "HTTP #{status}", status: status, cause: nil)

        assert {:error, ^error} =
                 Runner.default_inference(default_inference_request(), failing_model_call(error))

        assert drain_messages() == [:model_call]
      end
    end
  end

  defp dropped_connection(reason) do
    ReqLLM.Error.API.Request.exception(
      reason: Exception.message(Req.TransportError.exception(reason: reason)),
      status: nil,
      cause: Req.TransportError.exception(reason: reason)
    )
  end

  defp failing_model_call(error) do
    test_pid = self()

    fn _input, _config, _opts ->
      send(test_pid, :model_call)
      %{termination_reason: :failed, result: error, trace: []}
    end
  end

  defp substitute_retry_sleep do
    test_pid = self()
    previous = Application.get_env(:jido_gralkor, :reflection_retry_sleep)

    Application.put_env(:jido_gralkor, :reflection_retry_sleep, fn ms ->
      send(test_pid, {:retry_sleep, ms})
    end)

    on_exit(fn -> restore_application_env(:reflection_retry_sleep, previous) end)
  end

  defp drain_messages(messages \\ []) do
    receive do
      {:DOWN, _ref, :process, _pid, :normal} -> drain_messages(messages)
      message -> drain_messages([message | messages])
    after
      0 -> Enum.reverse(messages)
    end
  end

  defp prove_step_request_identity do
    context = %{request_source: "scheduled"}

    assert {:ok, %Artefact{}} =
             run_successful_sequence(invocation_context: context)

    assert_receive {:inference_request,
                    %{
                      reflection: "review",
                      operator_id: "operator-one",
                      invocation_id: "invocation-one",
                      invocation_context: ^context
                    }}

    assert_receive {:inference_request,
                    %{
                      reflection: "review",
                      operator_id: "operator-one",
                      invocation_id: "invocation-one",
                      invocation_context: ^context
                    }}
  end

  defp prove_step_request_representations do
    representation = representation()
    assert {:ok, %Artefact{}} = run_successful_sequence(representations: [representation])

    assert_receive {:inference_request, %{representations: [received]}}

    assert Map.from_struct(received) == %{
             id: "representation-one",
             lens: "observations",
             content: "Deployment evidence.",
             result: :ok
           }
  end

  defp prove_step_request_tools do
    tools = [SampleTool]
    tool_context = %{session_id: "thread-one", tenant: "alpha"}

    assert {:ok, %Artefact{}} =
             run_successful_sequence(tools: tools, tool_context: tool_context)

    assert_receive {:inference_request, %{tools: ^tools, tool_context: ^tool_context}}
  end

  defp prove_only_current_step_is_exposed do
    assert {:ok, %Artefact{}} = run_successful_sequence()

    assert_receive {:inference_request, first}
    assert first.step == %{label: "collect", directions: "Collect evidence."}
    assert first.output_schema == %{"evidence" => "string"}
    refute Map.has_key?(first, :chain_of_thought)

    assert_receive {:inference_request, second}
    assert second.step == %{label: "decide", directions: "Decide from gathered evidence."}
    assert second.output_schema == %{"answer" => "string", "confidence" => "integer"}
  end

  defp prove_tool_call_execution do
    test_pid = self()
    call = %{name: "lookup", arguments: %{"query" => "deployment"}}

    inference = fn
      %{tool_results: []} -> {:ok, %{tool_calls: [call]}}
      %{tool_results: [_result]} -> {:ok, %{output: %{"answer" => "ready"}}}
    end

    executor = fn received_call, context ->
      send(test_pid, {:tool_execution, received_call, context})
      {:ok, "stored evidence"}
    end

    assert {:ok, %Artefact{}} =
             Runner.run(single_step_reflection(), invocation(),
               inference: inference,
               tool_executor: executor,
               tools: [SampleTool],
               tool_context: %{session_id: "thread-one"}
             )

    assert_receive {:tool_execution, ^call,
                    %{
                      reflection: "review",
                      operator_id: "operator-one",
                      tools: [SampleTool],
                      tool_context: %{session_id: "thread-one"}
                    }}
  end

  defp prove_tool_result_return do
    test_pid = self()
    call = %{name: "lookup", arguments: %{"query" => "deployment"}}

    inference = fn
      %{tool_results: []} ->
        {:ok, %{tool_calls: [call]}}

      %{tool_results: results} ->
        send(test_pid, {:returned_tool_results, results})
        {:ok, %{output: %{"answer" => "ready"}}}
    end

    executor = fn _received_call, _context -> {:ok, %{content: "evidence"}} end

    assert {:ok, %Artefact{}} =
             Runner.run(single_step_reflection(), invocation(),
               inference: inference,
               tool_executor: executor
             )

    assert_receive {:returned_tool_results,
                    [%{call: ^call, result: {:ok, %{content: "evidence"}}}]}
  end

  defp prove_sequential_tool_calls do
    test_pid = self()
    first = %{name: "lookup", arguments: %{"query" => "first"}}
    second = %{name: "lookup", arguments: %{"query" => "second"}}

    inference = fn
      %{step: %{label: label}, tool_results: []} ->
        send(test_pid, {:step_continued, label})
        {:ok, %{tool_calls: [first]}}

      %{step: %{label: label}, tool_results: [_]} ->
        send(test_pid, {:step_continued, label})
        {:ok, %{tool_calls: [second]}}

      %{step: %{label: label}, tool_results: [_, _]} ->
        send(test_pid, {:step_continued, label})
        {:ok, %{output: %{"answer" => "ready"}}}
    end

    executor = fn call, _context ->
      send(test_pid, {:executed, call.arguments["query"]})
      {:ok, call.arguments["query"]}
    end

    assert {:ok, %Artefact{}} =
             Runner.run(single_step_reflection(), invocation(),
               inference: inference,
               tool_executor: executor
             )

    assert_receive {:step_continued, "finish"}
    assert_receive {:executed, "first"}
    assert_receive {:step_continued, "finish"}
    assert_receive {:executed, "second"}
    assert_receive {:step_continued, "finish"}
  end

  defp prove_inference_failures_are_identified do
    reflection = single_step_reflection()

    assert {:error, %{reflection: "review", step: "finish", reason: :provider_down}} =
             Runner.run(reflection, invocation(),
               inference: fn _request -> {:error, :provider_down} end
             )

    assert {:error,
            %{
              reflection: "review",
              step: "finish",
              reason: {:invalid_inference_response, :not_a_response}
            }} =
             Runner.run(reflection, invocation(), inference: fn _request -> :not_a_response end)

    assert {:error,
            %{
              reflection: "review",
              step: "finish",
              reason: {:invalid_inference_response, {:ok, %{"answer" => "ready"}}}
            }} =
             Runner.run(reflection, invocation(),
               inference: fn _request -> {:ok, %{"answer" => "ready"}} end
             )

    assert {:error,
            %{
              reflection: "review",
              step: "finish",
              reason: {:invalid_inference_response, {:tool_calls, [%{name: "lookup"}]}}
            }} =
             Runner.run(reflection, invocation(),
               inference: fn _request -> {:tool_calls, [%{name: "lookup"}]} end
             )
  end

  defp prove_built_in_inference_request do
    test_pid = self()

    caller = fn prompt, config, opts ->
      send(test_pid, {:built_in_call, prompt, config, opts})
      %{termination_reason: :final_answer, result: ~s({"answer":"ready"})}
    end

    assert {:ok, %{output: %{"answer" => "ready"}}} =
             Runner.default_inference(default_inference_request(), caller,
               model_resolver: fn -> %{provider: "openai", id: "runner-contract-model"} end
             )

    assert_receive {:built_in_call, prompt, config, _opts}

    assert config == %{
             model: "openai:runner-contract-model",
             tools: [SampleTool],
             streaming: false,
             max_iterations: 10,
             max_tokens: 32_768,
             temperature: 0.7,
             tool_concurrency: 1,
             tool_max_retries: 0,
             tool_timeout_ms: 30_000
           }

    assert prompt =~ "Use the evidence."

    assert prompt_json(
             prompt,
             "Lensed representations available to this Reflection step:",
             nil
           ) == [
             %{
               "content" => "Deployment evidence.",
               "id" => "representation-one",
               "lens" => "observations",
               "result" => "ok"
             }
           ]

    assert prompt_json(
             prompt,
             "Return only one JSON object satisfying this exact output contract:",
             nil
           ) == %{"answer" => "string"}

    refute prompt =~ "must not leak"
  end

  defp prove_representations_and_contract_json do
    prompt = built_in_prompt(default_inference_request())

    assert prompt_json(
             prompt,
             "Lensed representations available to this Reflection step:",
             nil
           ) == [
             %{
               "content" => "Deployment evidence.",
               "id" => "representation-one",
               "lens" => "observations",
               "result" => "ok"
             }
           ]

    assert prompt_json(
             prompt,
             "Return only one JSON object satisfying this exact output contract:",
             nil
           ) == %{"answer" => "string"}
  end

  defp prove_wrapped_structured_output do
    request = default_inference_request()

    assert {:ok, %{output: %{"answer" => "ready"}}} =
             Runner.default_inference(request, fn _action, _args, _context ->
               %{termination_reason: :final_answer, result: ~s({"answer":"ready"})}
             end)
  end

  defp emit_through_built_in_inference(event) do
    caller = fn _prompt, _config, opts ->
      Keyword.fetch!(opts, :on_event).(event)
      %{termination_reason: :final_answer, result: ~s({"answer":"ready"})}
    end

    assert {:ok, _} =
             Gralkor.Reflection.Runner.default_inference(default_inference_request(), caller,
               model_resolver: fn -> %{provider: "openai", id: "runner-contract-model"} end,
               observer: observer()
             )
  end

  defp react_event(kind, fields) do
    struct!(
      Jido.AI.Runtime.Event,
      Keyword.merge(
        [
          id: "event-1",
          seq: 1,
          at_ms: 0,
          run_id: "run-1",
          request_id: "request-1",
          iteration: 1,
          kind: kind,
          tool_call_id: "call-1",
          tool_name: "lookup",
          data: %{}
        ],
        fields
      )
    )
  end

  defp script_tool_step(directions, schema, query, answer) do
    Jido.AI.Test.ReActScript.new(%{
      user: """
      #{directions}

      Lensed representations available to this Reflection step:
      []

      Return only one JSON object satisfying this exact output contract:
      #{Jason.encode!(schema)}

      The quoted contract values are type declarations, not literal output
      values. Emit actual JSON values of those types. In particular, an object
      declaration such as "{ field: string }" requires a nested JSON object,
      and an Array<...> declaration requires a JSON array; do not quote either.
      """,
      turns: [
        %{type: :tool_call, name: "lookup", arguments: %{"query" => query}},
        %{type: :answer, text: answer}
      ]
    })
    |> Jido.AI.Test.ReActScript.register()

    on_exit(fn -> Jido.AI.Test.ReActScript.clear_current_owner() end)
  end

  defp script_step(directions, schema, answer) do
    Jido.AI.Test.ReActScript.new(%{
      user: """
      #{directions}

      Lensed representations available to this Reflection step:
      []

      Return only one JSON object satisfying this exact output contract:
      #{Jason.encode!(schema)}

      The quoted contract values are type declarations, not literal output
      values. Emit actual JSON values of those types. In particular, an object
      declaration such as "{ field: string }" requires a nested JSON object,
      and an Array<...> declaration requires a JSON array; do not quote either.
      """,
      turns: [%{type: :answer, text: answer}]
    })
    |> Jido.AI.Test.ReActScript.register()

    on_exit(fn -> Jido.AI.Test.ReActScript.clear_current_owner() end)
  end

  defp built_in_config(request, opts) do
    test_pid = self()

    caller = fn _prompt, config, _opts ->
      send(test_pid, {:built_in_config, config})
      %{termination_reason: :final_answer, result: ~s({"answer":"ready"})}
    end

    assert {:ok, _} = Gralkor.Reflection.Runner.default_inference(request, caller, opts)
    assert_receive {:built_in_config, config}
    config
  end

  defp built_in_prompt(request) do
    test_pid = self()

    caller = fn prompt, _config, _opts ->
      send(test_pid, {:built_in_prompt, prompt})
      %{termination_reason: :final_answer, result: ~s({"answer":"ready"})}
    end

    assert {:ok, _} =
             Runner.default_inference(request, caller,
               model_resolver: fn -> %{provider: "openai", id: "runner-contract-model"} end
             )

    assert_receive {:built_in_prompt, prompt}
    prompt
  end

  defp prompt_json(prompt, heading, _next_heading) do
    [_, rest] = String.split(prompt, heading <> "\n", parts: 2)
    [encoded | _] = String.split(rest, "\n\n", parts: 2)
    Jason.decode!(String.trim(encoded))
  end

  defp prove_built_in_inference_context do
    test_pid = self()
    request = default_inference_request()

    caller = fn _action, _args, context ->
      send(test_pid, {:built_in_context, Keyword.fetch!(context, :context)})
      %{termination_reason: :final_answer, result: ~s({"answer":"ready"})}
    end

    assert {:ok, %{output: %{"answer" => "ready"}}} =
             Runner.default_inference(request, caller,
               model_resolver: fn -> %{provider: "openai", id: "runner-contract-model"} end
             )

    assert_receive {:built_in_context, context}

    assert context == %{
             operator_id: "operator-one",
             session_id: "thread-one",
             tenant: "alpha"
           }
  end

  defp prove_built_in_inference_errors do
    request = default_inference_request()

    assert {:error, :provider_down} =
             Runner.default_inference(request, fn _action, _args, _context ->
               %{termination_reason: :failed, result: :provider_down}
             end)

    assert {:error, :provider_rejected} =
             Runner.default_inference(request, fn _action, _args, _context ->
               %{termination_reason: :failed, result: :provider_rejected}
             end)

    assert {:error, {:invalid_structured_output, %Jason.DecodeError{}}} =
             Runner.default_inference(request, fn _action, _args, _context ->
               %{termination_reason: :final_answer, result: "not json"}
             end)

    assert {:error, {:invalid_structured_output, ["not", "an", "object"]}} =
             Runner.default_inference(request, fn _action, _args, _context ->
               %{termination_reason: :final_answer, result: ~s(["not","an","object"])}
             end)
  end

  defp inference_answering(output) do
    test_pid = self()

    fn request ->
      send(test_pid, {:inference_request, request})
      {:ok, %{output: output}}
    end
  end

  defp observer do
    test_pid = self()
    fn event -> send(test_pid, {:observed, event}) end
  end

  defp observed_sequence(sequence \\ []) do
    receive do
      {:observed, event} ->
        observed_sequence([{:observed, event} | sequence])

      {:inference_request, %{step: %{label: label}}} ->
        observed_sequence([{:inference, label} | sequence])
    after
      0 -> Enum.reverse(sequence)
    end
  end

  defp run_successful_sequence(opts \\ []) do
    test_pid = self()

    inference = fn request ->
      send(test_pid, {:inference_request, request})
      {:ok, output_for(request)}
    end

    runner_opts =
      opts
      |> Keyword.take([:tools, :tool_context, :artefact_id_for, :type_matcher, :observer])
      |> Keyword.put(:inference, inference)

    runner_opts =
      runner_opts
      |> Keyword.put_new(:type_matcher, fn
        "ready", "string" -> true
        "collected", "string" -> true
        "gathered evidence", "string" -> true
        "ship", "string" -> true
        3, "integer" -> true
        _value, _type -> false
      end)
      |> Keyword.put_new(:artefact_id_for, fn
        "operator-one", "invocation-one", "review" -> "unit-artefact-id"
      end)

    Runner.run(
      reflection(sequence_steps()),
      invocation(
        invocation_context: Keyword.get(opts, :invocation_context, %{trigger: "manual"}),
        representations: Keyword.get(opts, :representations, [representation()])
      ),
      runner_opts
    )
  end

  defp successful_inference(request), do: {:ok, output_for(request)}

  defp output_for(%{step: %{label: "collect"}}),
    do: %{output: %{"evidence" => "gathered evidence"}}

  defp output_for(%{step: %{label: "decide"}}),
    do: %{output: %{"answer" => "ship", "confidence" => 3}}

  defp output_for(%{step: %{label: "finish"}}),
    do: %{output: %{"answer" => "ready"}}

  defp sequence_steps do
    [
      step("collect", "Collect evidence.", %{"evidence" => "string"}),
      step("decide", "Decide from {{ evidence }}.", %{
        "answer" => "string",
        "confidence" => "integer"
      })
    ]
  end

  defp single_step_reflection,
    do: reflection([step("finish", "Finish.", %{"answer" => "string"})])

  defp reflection(steps, name \\ "review") do
    %Reflection{
      name: name,
      chain_of_thought: %ChainOfThought{steps: steps},
      outputs: [
        %{
          kind: :destination,
          destination: %Destination{name: "global"},
          ontology: Gralkor.DefaultOntology
        }
      ]
    }
  end

  defp step(label, directions, output),
    do: %Step{label: label, directions: directions, output: output}

  defp invocation(overrides \\ []) do
    Map.merge(
      %{
        id: "invocation-one",
        operator_id: "operator-one",
        invocation_context: %{trigger: "manual"},
        representations: [representation()]
      },
      Map.new(overrides)
    )
  end

  defp representation(overrides \\ []) do
    struct!(
      IngestedRepresentation,
      Keyword.merge(
        [
          id: "representation-one",
          lens: "observations",
          content: "Deployment evidence.",
          result: :ok
        ],
        overrides
      )
    )
  end

  defp default_inference_request do
    %{
      directions: "Use the evidence.",
      operator_id: "operator-one",
      output_schema: %{"answer" => "string"},
      representations: [
        %{
          id: "representation-one",
          lens: "observations",
          content: "Deployment evidence.",
          result: :ok,
          internal_note: "must not leak"
        }
      ],
      tools: [SampleTool],
      tool_context: %{
        operator_id: "conflicting-operator",
        session_id: "thread-one",
        tenant: "alpha"
      }
    }
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_application_env(key, value), do: Application.put_env(:jido_gralkor, key, value)

  defp restore_system_env(name, nil), do: System.delete_env(name)
  defp restore_system_env(name, value), do: System.put_env(name, value)
end
