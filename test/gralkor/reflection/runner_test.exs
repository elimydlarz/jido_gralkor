defmodule Gralkor.Reflection.RunnerTest do
  use ExUnit.Case, async: false

  alias Gralkor.Artefact
  alias Gralkor.Destination
  alias Gralkor.IngestedRepresentation
  alias Gralkor.Reflection
  alias Gralkor.Reflection.ChainOfThought
  alias Gralkor.Reflection.ChainOfThought.Step
  alias Gralkor.Reflection.Runner
  alias Gralkor.Search

  defmodule ProbeDestinationStorage do
    @behaviour Gralkor.Destination.Storage

    @impl true
    def search(destination, operator_id, query, result_type, max_results, opts) do
      send(
        :reflection_runner_test,
        {:destination_search, destination, operator_id, query, result_type, max_results, opts}
      )

      {:ok, []}
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

    test "and every step request carries the Reflection, operator, invocation identifier, and invocation context" do
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

  describe "when inference returns wrapped structured output satisfying the current step's exact contract" do
    test "then that output is added to the shared output space" do
      assert {:ok, %Artefact{}} = run_successful_sequence()
      assert_receive {:inference_request, %{step: %{label: "collect"}}}

      assert_receive {:inference_request,
                      %{step: %{label: "decide", directions: "Decide from gathered evidence."}}}
    end

    test "and the next step begins with it available for interpolation" do
      assert {:ok, %Artefact{}} = run_successful_sequence()
      assert_receive {:inference_request, %{step: %{label: "collect"}}}

      assert_receive {:inference_request,
                      %{directions: "Decide from gathered evidence.", step: %{label: "decide"}}}
    end
  end

  describe "if inference omits a declared output" do
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
              }} = Runner.run(reflection, invocation(), inference: fn _request -> {:ok, %{}} end)
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
                   {:ok, %{"summary" => "ready", "extra" => "undeclared"}}
                 end
               )
    end
  end

  describe "if inference returns a value of the wrong declared type" do
    test "then the Runner failure identifies the Reflection, step, key, and type" do
      reflection = reflection([step("score", "Score.", %{"count" => "integer"})])

      assert {:error,
              %{
                reflection: "review",
                step: "score",
                reason: {:output_type_mismatch, "count", "integer"}
              }} =
               Runner.run(reflection, invocation(),
                 inference: fn _request -> {:ok, %{"count" => "many"}} end
               )
    end
  end

  describe "when the final step returns valid wrapped structured output" do
    test "then the Runner returns one producer-independent artefact" do
      assert {:ok, %Artefact{id: id, payload: payload}} = run_successful_sequence()
      assert is_binary(id)
      assert payload == %{"answer" => "ship", "confidence" => 3}
    end

    test "and its identifier is derived from the operator, invocation, and Reflection identity" do
      assert {:ok, %Artefact{id: id}} = run_successful_sequence()
      assert id == Artefact.id_for("operator-one", "invocation-one", "review")
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

  describe "if the Chain of Thought completes without valid final structured output" do
    test "then the Runner failure identifies the Reflection and missing artefact" do
      reflection = reflection([])

      assert {:error, %{reflection: "review", reason: :missing_artefact}} =
               Runner.run(reflection, invocation(), inference: fn _request -> flunk() end)
    end
  end

  describe "if inference fails or returns an invalid response" do
    test "then the Runner failure identifies the Reflection, current step, and reason" do
      prove_inference_failures_are_identified()
    end
  end

  describe "when the packaged generalisation Reflection runs" do
    test "then one runtime-targeted related-memory episode search completes before inference" do
      prove_runtime_targeted_related_memory_search()
    end

    test "and the search query contains every completed representation's content" do
      prove_related_memory_query()
    end

    test "and the resulting stored information is available to every inference step" do
      prove_related_memory_reaches_every_step()
    end
  end

  describe "when the packaged generalisation Reflection runs > if related-memory search fails" do
    test "then the Runner fails before inference and identifies the search failure" do
      prove_related_memory_failure()
    end
  end

  describe "when another Reflection runs" do
    test "then no related-memory search is issued" do
      prove_other_reflection_skips_related_memory()
    end
  end

  describe "when built-in inference is invoked for a step" do
    test "then it requests the configured model with the directions, exact output contract, representations, and stored information" do
      prove_built_in_inference_request()
    end

    test "and it supplies the host tools and a tool context whose operator identity comes from the invocation while every other supplied field remains unchanged" do
      prove_built_in_inference_context()
    end

    test "and a final JSON object is returned as wrapped structured output" do
      request = default_inference_request()

      assert {:ok, %{output: %{"answer" => "ready"}}} =
               Runner.default_inference(request, fn _action, _args, _context ->
                 {:ok, %{text: ~s({"answer":"ready"})}}
               end)
    end
  end

  describe "when built-in inference is invoked for a step > if the provider fails or returns invalid JSON or a non-object JSON value" do
    test "then built-in inference returns the identified error" do
      prove_built_in_inference_errors()
    end
  end

  defp prove_step_request_identity do
    context = %{request_source: "scheduled"}

    assert {:ok, %Artefact{}} =
             run_successful_sequence(invocation_context: context, artefact_id: "fixed")

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
      %{tool_results: []} -> {:tool_calls, [call]}
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
             Runner.run(reflection, invocation(),
               inference: fn _request -> :not_a_response end
             )
  end

  defp prove_runtime_targeted_related_memory_search do
    test_pid = self()
    owner = self()

    search = fn received_owner, request ->
      send(test_pid, {:related_memory_search, received_owner, request})
      {:ok, [%{content: "stored information"}]}
    end

    inference = fn request ->
      assert_received {:related_memory_search, ^owner, %Search{result_type: :episodes}}
      {:ok, output_for(request)}
    end

    assert {:ok, %Artefact{}} =
             Runner.run(generalisation_reflection(), invocation(),
               runtime_owner: owner,
               related_memory_search: search,
               inference: inference
             )

    refute_receive {:related_memory_search, _, _}
  end

  defp prove_related_memory_query do
    test_pid = self()

    search = fn owner, request ->
      send(test_pid, {:related_memory_query, owner, request})
      {:ok, []}
    end

    representations = [
      representation(content: "First completed representation."),
      representation(id: "representation-two", content: "Second completed representation.")
    ]

    assert {:ok, %Artefact{}} =
             Runner.run(generalisation_reflection(), invocation(representations: representations),
               runtime_owner: :runtime_owner,
               related_memory_search: search,
               inference: &successful_inference/1
             )

    assert_receive {:related_memory_query, :runtime_owner,
                    %Search{
                      operator_id: "operator-one",
                      result_type: :episodes,
                      query: query
                    }}

    assert query == "First completed representation.\nSecond completed representation."
  end

  defp prove_related_memory_reaches_every_step do
    test_pid = self()
    stored = [%{content: "related observation"}, %{content: "prior generalisation"}]
    search = fn _owner, _request -> {:ok, stored} end

    inference = fn request ->
      send(test_pid, {:stored_information, request.step.label, request.stored_information})
      {:ok, output_for(request)}
    end

    assert {:ok, %Artefact{}} =
             Runner.run(generalisation_reflection(), invocation(),
               runtime_owner: self(),
               related_memory_search: search,
               inference: inference
             )

    assert_receive {:stored_information, "collect", ^stored}
    assert_receive {:stored_information, "decide", ^stored}
  end

  defp prove_related_memory_failure do
    test_pid = self()
    search = fn _owner, _request -> {:error, :unavailable} end
    inference = fn _request -> send(test_pid, :inference_started); {:ok, %{}} end

    assert {:error,
            %{reflection: "generalisations", reason: {:related_memory_search, :unavailable}}} =
             Runner.run(generalisation_reflection(), invocation(),
               runtime_owner: self(),
               related_memory_search: search,
               inference: inference
             )

    refute_receive :inference_started
  end

  defp prove_other_reflection_skips_related_memory do
    test_pid = self()
    search = fn _owner, _request -> send(test_pid, :related_memory_searched); {:ok, []} end

    assert {:ok, %Artefact{}} =
             Runner.run(single_step_reflection(), invocation(),
               runtime_owner: self(),
               related_memory_search: search,
               inference: &successful_inference/1
             )

    refute_receive :related_memory_searched
    refute_receive {:destination_search, _, _, _, _, _, _}
  end

  defp prove_built_in_inference_request do
    System.put_env("GRALKOR_LLM_MODEL", "openai:runner-contract-model")
    test_pid = self()

    caller = fn action, args, context ->
      send(test_pid, {:built_in_call, action, args, context})
      {:ok, %{text: ~s({"answer":"ready"})}}
    end

    assert {:ok, %{output: %{"answer" => "ready"}}} =
             Runner.default_inference(default_inference_request(), caller)

    assert_receive {:built_in_call, Jido.AI.Actions.ToolCalling.CallWithTools, args, _context}
    assert args.model == "openai:runner-contract-model"
    assert args.auto_execute
    assert args.prompt =~ "Use the evidence."
    assert args.prompt =~ ~s("answer":"string")
    assert args.prompt =~ "Deployment evidence."
    assert args.prompt =~ "stored observation"
    refute args.prompt =~ "must not leak"
  end

  defp prove_built_in_inference_context do
    test_pid = self()
    request = default_inference_request()

    caller = fn _action, _args, context ->
      send(test_pid, {:built_in_context, context})
      {:ok, %{text: ~s({"answer":"ready"})}}
    end

    assert {:ok, %{output: %{"answer" => "ready"}}} =
             Runner.default_inference(request, caller)

    assert_receive {:built_in_context, context}

    assert context == %{
             operator_id: "operator-one",
             session_id: "thread-one",
             tenant: "alpha",
             tools: [SampleTool]
           }
  end

  defp prove_built_in_inference_errors do
    request = default_inference_request()

    assert {:error, :provider_down} =
             Runner.default_inference(request, fn _action, _args, _context ->
               {:error, :provider_down}
             end)

    assert {:error, :provider_rejected} =
             Runner.default_inference(request, fn _action, _args, _context ->
               {:ok, %{type: :error, reason: :provider_rejected}}
             end)

    assert {:error, {:invalid_structured_output, %Jason.DecodeError{}}} =
             Runner.default_inference(request, fn _action, _args, _context ->
               {:ok, %{text: "not json"}}
             end)

    assert {:error, {:invalid_structured_output, ["not", "an", "object"]}} =
             Runner.default_inference(request, fn _action, _args, _context ->
               {:ok, %{text: ~s(["not","an","object"])} }
             end)
  end

  defp run_successful_sequence(opts \\ []) do
    test_pid = self()

    inference = fn request ->
      send(test_pid, {:inference_request, request})
      {:ok, output_for(request)}
    end

    runner_opts =
      opts
      |> Keyword.take([:tools, :tool_context, :artefact_id])
      |> Keyword.put(:inference, inference)

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

  defp generalisation_reflection,
    do: reflection(sequence_steps(), "generalisations")

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
      stored_information: [%{content: "stored observation"}],
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
