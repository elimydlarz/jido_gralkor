defmodule Gralkor.ReflectionSystemFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  alias Gralkor.Reflection.Registry
  alias Gralkor.Reflection.Runner
  alias Gralkor.Reflection.Scheduler
  alias Gralkor.Reflection.Store

  defmodule FailingReflectionStorage do
    @behaviour Gralkor.Reflection.Store
    def put(_, _, _), do: {:error, :destination_unavailable}
    def search(_, _, _, _), do: {:error, :destination_unavailable}
    def get(_, _, _), do: {:error, :destination_unavailable}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "gralkor-reflection-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    start_supervised!(Gralkor.Reflection.Storage.InMemory)
    start_supervised!(Scheduler)
    %{root: root}
  end

  describe "when Reflection declarations are validated" do
    test "while every Reflection has a non-blank name", context, do: assert_valid(context)
    test "and every Reflection name is unique", context, do: assert_valid(context)
    test "and every Reflection references a repository YAML Chain of Thought", context, do: assert_valid(context)
    test "and every referenced Chain of Thought contains one or more ordered steps", context, do: assert_valid(context)
    test "and every step has a non-blank label and natural-language directions", context, do: assert_valid(context)
    test "and every step declares one or more named structured outputs and their types", context, do: assert_valid(context)
    test "and output names are unique across the Chain of Thought", context, do: assert_valid(context)
    test "and every interpolation references an output from an earlier step", context, do: assert_valid(context)
    test "and every Reflection destination is named by its Reflection and has operator or global scope then validation succeeds", context,
      do: assert_valid(context)

    test "if a Reflection name is blank then validation fails identifying the blank name", %{root: root} do
      assert {:error, {:blank_name, " "}} = Registry.load([valid_definition(root, name: " ")], root: root)
    end

    test "if Reflection names are duplicated then validation fails identifying the duplicate name", %{root: root} do
      definition = valid_definition(root)
      assert {:error, {:duplicate_name, "generalisation"}} = Registry.load([definition, definition], root: root)
    end

    test "if a Reflection has no Chain of Thought then validation fails identifying that Reflection", %{root: root} do
      definition = valid_definition(root) |> Keyword.delete(:chain_of_thought)
      assert {:error, {:missing_chain_of_thought, "generalisation"}} = Registry.load([definition], root: root)
    end

    test "if a Reflection's Chain of Thought does not identify a repository YAML file then validation fails identifying that Reflection and file", %{root: root} do
      assert {:error, {:invalid_chain_of_thought_file, "generalisation", "../outside.yaml"}} =
               Registry.load([valid_definition(root, chain_of_thought: "../outside.yaml")], root: root)
    end

    test "if a Reflection's Chain of Thought YAML cannot be loaded or parsed then validation fails identifying that Reflection, file, and parse failure", %{root: root} do
      write_cot(root, "broken.yaml", "steps: [")
      assert {:error, {:invalid_chain_of_thought, "generalisation", "broken.yaml", _}} =
               Registry.load([valid_definition(root, chain_of_thought: "broken.yaml")], root: root)
    end

    test "if a Chain of Thought has no steps then validation fails identifying that Reflection and Chain of Thought", %{root: root} do
      write_cot(root, "empty.yaml", "steps: []")
      assert {:error, {:invalid_chain_of_thought, "generalisation", "empty.yaml", :missing_steps}} =
               Registry.load([valid_definition(root, chain_of_thought: "empty.yaml")], root: root)
    end

    test "if a Chain of Thought step has no non-blank label then validation fails identifying that Reflection and step", %{root: root} do
      write_cot(root, "blank-label.yaml", "steps:\n  - label: ' '\n    directions: Think.\n    output: {result: string}\n")
      assert {:error, {:invalid_chain_of_thought, "generalisation", "blank-label.yaml", {:invalid_step_label, " "}}} =
               Registry.load([valid_definition(root, chain_of_thought: "blank-label.yaml")], root: root)
    end

    test "if a Chain of Thought step has no natural-language directions then validation fails identifying that Reflection and step", %{root: root} do
      write_cot(root, "no-directions.yaml", "steps:\n  - label: think\n    output: {result: string}\n")
      assert {:error, {:invalid_chain_of_thought, "generalisation", "no-directions.yaml", {:invalid_step_directions, "think"}}} =
               Registry.load([valid_definition(root, chain_of_thought: "no-directions.yaml")], root: root)
    end

    test "if a Chain of Thought step has no structured-output declaration then validation fails identifying that Reflection and step", %{root: root} do
      write_cot(root, "no-output.yaml", "steps:\n  - label: think\n    directions: Think.\n")
      assert {:error, {:invalid_chain_of_thought, "generalisation", "no-output.yaml", {:invalid_step_output, "think"}}} =
               Registry.load([valid_definition(root, chain_of_thought: "no-output.yaml")], root: root)
    end

    test "if an output name is declared by more than one step then validation fails identifying that Reflection, output name, and steps", %{root: root} do
      write_cot(root, "duplicate-output.yaml", "steps:\n  - {label: one, directions: First., output: {result: string}}\n  - {label: two, directions: Second., output: {result: string}}\n")
      assert {:error, {:invalid_chain_of_thought, "generalisation", "duplicate-output.yaml", {:duplicate_output, "result", "two"}}} =
               Registry.load([valid_definition(root, chain_of_thought: "duplicate-output.yaml")], root: root)
    end

    test "if an interpolation references an output not declared by an earlier step then validation fails identifying that Reflection, step, and interpolation", %{root: root} do
      write_cot(root, "forward.yaml", "steps:\n  - label: one\n    directions: Use {{later}}.\n    output: {first: string}\n  - {label: two, directions: Later., output: {later: string}}\n")
      assert {:error, {:invalid_chain_of_thought, "generalisation", "forward.yaml", {:unknown_interpolation, "later", "one"}}} =
               Registry.load([valid_definition(root, chain_of_thought: "forward.yaml")], root: root)
    end

    test "if a Reflection has no destination scope then validation fails identifying that Reflection", %{root: root} do
      definition = valid_definition(root) |> Keyword.delete(:scope)
      assert {:error, {:invalid_destination_scope, "generalisation", nil}} = Registry.load([definition], root: root)
    end

    test "if a Reflection's destination scope is neither operator nor global then validation fails identifying that Reflection and destination scope", %{root: root} do
      assert {:error, {:invalid_destination_scope, "generalisation", :private}} =
               Registry.load([valid_definition(root, scope: :private)], root: root)
    end
  end

  describe "when an ingestion operation successfully stores information through one or more Lenses" do
    test "while Reflections are declared then every stored representation retains its evidence identifier and Lens identity", context do
      reflection = reflection(context)
      parent = self()
      inference = fn request -> send(parent, {:representations, request.representations}); output_for(request) end
      assert {:ok, _} = Runner.run(reflection, ingestion(), inference: inference)
      assert_receive {:representations, [%{evidence_id: "ev-1", lens: "observations"}, %{evidence_id: "ev-2", lens: "decisions"}]}
    end

    test "and the ingestion caller receives success without waiting for Reflection", context do
      reflection = reflection(context)
      slow = fn _, _, _ -> Process.sleep(150); {:error, :finished} end
      started = System.monotonic_time(:millisecond)
      assert {:ok, :scheduled} = Scheduler.schedule([reflection], ingestion(), runner: slow)
      assert System.monotonic_time(:millisecond) - started < 100
    end

    test "and every declared Reflection is scheduled once for the completed ingestion operation", context do
      reflections = [reflection(context, "one"), reflection(context, "two")]
      runner = notifying_runner(self())
      assert {:ok, :scheduled} = Scheduler.schedule(reflections, ingestion(), runner: runner)
      assert {:ok, :already_scheduled} = Scheduler.schedule(reflections, ingestion(), runner: runner)
      assert_receive {:ran, "one"}
      assert_receive {:ran, "two"}
      refute_receive {:ran, _}
    end

    test "and no Reflection begins before every intended Lens ingestion has completed", context do
      runner = notifying_runner(self())
      assert {:error, {:incomplete_ingestion, "ingestion-1"}} =
               Scheduler.schedule([reflection(context)], incomplete_ingestion(), runner: runner)
      refute_receive {:ran, _}
    end
  end

  describe "when a scheduled Reflection runs" do
    test "then its programmatic Chain of Thought runner loads the declared YAML", context do
      assert %Gralkor.Reflection.ChainOfThought{path: path} = reflection(context).chain_of_thought
      assert String.ends_with?(path, ".yaml")
    end

    test "and starts its first step for the operator and completed ingestion operation", context do
      parent = self()
      inference = fn request -> send(parent, {:first, request.operator_id, request.step.label}); output_for(request) end
      assert {:ok, _} = Runner.run(reflection(context), ingestion(), inference: inference)
      assert_receive {:first, "operator-one", "gather"}
    end

    test "and makes every ingested representation available with its evidence identifier and Lens identity", context do
      parent = self()
      inference = fn request -> send(parent, {:available, request.representations}); output_for(request) end
      assert {:ok, _} = Runner.run(reflection(context), ingestion(), inference: inference)
      assert_receive {:available, [%{evidence_id: "ev-1", lens: "observations"}, %{evidence_id: "ev-2", lens: "decisions"}]}
    end
  end

  describe "when a Chain of Thought step begins" do
    test "then built-in inference receives that step's interpolated natural-language directions", context do
      requests = run_and_collect_requests(reflection(context), ingestion())
      assert Enum.at(requests, 1).directions == "Synthesise [\"fact one\"]"
    end

    test "and receives that step's declared structured-output contract", context do
      assert [first | _] = run_and_collect_requests(reflection(context), ingestion())
      assert first.output_schema == %{"facts" => "Array<string>"}
    end

    test "and receives the complete tool set available to the host agent", context do
      tools = [JidoGralkor.Actions.MemorySearch, JidoGralkor.Actions.MemoryAdd]
      tool_context = %{session_id: "session-one", custom: "kept"}

      request = %{
        directions: "Use memory.",
        output_schema: %{"artefact" => "string"},
        tools: tools,
        tool_context: tool_context,
        operator_id: "operator-one"
      }

      call = fn Jido.AI.Actions.ToolCalling.CallWithTools, params, received ->
        send(self(), {:default_inference, params, received})
        {:ok, %{text: ~s({"artefact":"done"})}}
      end

      assert {:ok, %{output: %{"artefact" => "done"}}} = Runner.default_inference(request, call)
      assert_receive {:default_inference, %{auto_execute: true, model: model}, %{tools: ^tools, tool_context: received_context}}
      configured = Gralkor.Config.llm_model()
      assert model == "#{configured.provider}:#{configured.id}"
      assert received_context == Map.put(tool_context, :operator_id, "operator-one")
    end

    test "and the current step is the only step exposed to inference", context do
      assert [first | _] = run_and_collect_requests(reflection(context), ingestion())
      assert first.step == %{label: "gather", directions: "Gather evidence."}
      refute Map.has_key?(first, :steps)
    end

    test "where the directions reference outputs from earlier steps then every referenced value is interpolated from the Chain of Thought's shared output space", context do
      assert [_first, second] = run_and_collect_requests(reflection(context), ingestion())
      assert second.directions =~ "fact one"
      refute second.directions =~ "{{facts}}"
    end

    test "where inference directs a tool call then the requested tool is called with the model-produced arguments", context do
      parent = self()
      inference = tool_calling_inference(parent, 1)
      executor = fn call, _ -> send(parent, {:executed, call}); {:ok, "found"} end
      assert {:ok, _} = Runner.run(one_step_reflection(context), ingestion(), inference: inference, tool_executor: executor)
      assert_receive {:executed, %{name: "memory_search", arguments: %{"query" => "pattern"}}}
    end

    test "and the tool result is returned to inference within the same step", context do
      parent = self()
      inference = tool_calling_inference(parent, 1)
      executor = fn _, _ -> {:ok, "found"} end
      assert {:ok, _} = Runner.run(one_step_reflection(context), ingestion(), inference: inference, tool_executor: executor)
      assert_receive {:continued, "reflect", [%{result: {:ok, "found"}}]}
    end

    test "and inference continues within that step with access to the result and every configured tool", context do
      parent = self()
      tools = [:memory_search, :memory_add]
      inference = tool_calling_inference(parent, 1)
      assert {:ok, _} = Runner.run(one_step_reflection(context), ingestion(), inference: inference, tools: tools, tool_executor: fn _, _ -> :ok end)
      assert_receive {:continued_tools, "reflect", ^tools}
    end

    test "where inference directs further tool calls then each requested call and result continues the same step in sequence", context do
      parent = self()
      inference = tool_calling_inference(parent, 2)
      executor = fn call, _ -> send(parent, {:tool_sequence, call.name}); {:ok, call.name} end
      assert {:ok, _} = Runner.run(one_step_reflection(context), ingestion(), inference: inference, tool_executor: executor)
      assert_receive {:tool_sequence, "tool-1"}
      assert_receive {:tool_sequence, "tool-2"}
    end
  end

  describe "when inference returns a structured output for the current step" do
    test "while its keys and values satisfy that step's declared output contract then the output is added to the Chain of Thought's shared output space", context do
      assert [_first, second] = run_and_collect_requests(reflection(context), ingestion())
      assert second.directions =~ "fact one"
    end

    test "and the next step begins with those outputs available for interpolation", context do
      assert [_first, second] = run_and_collect_requests(reflection(context), ingestion())
      assert second.step.label == "synthesise"
      assert second.directions == "Synthesise [\"fact one\"]"
    end

    test "if a declared output key is missing then the Reflection fails identifying its name, current step, and missing key", context do
      assert {:error, %{reflection: "generalisation", step: "gather", reason: {:missing_output, "facts"}}} =
               Runner.run(reflection(context), ingestion(), inference: fn _ -> {:ok, %{output: %{}}} end)
    end

    test "if an undeclared output key is returned then the Reflection fails identifying its name, current step, and unexpected key", context do
      assert {:error, %{reflection: "generalisation", step: "gather", reason: {:unexpected_output, "extra"}}} =
               Runner.run(reflection(context), ingestion(), inference: fn _ -> {:ok, %{output: %{"facts" => [], "extra" => true}}} end)
    end

    test "if an output value does not satisfy its declared type then the Reflection fails identifying its name, current step, and type mismatch", context do
      assert {:error, %{reflection: "generalisation", step: "gather", reason: {:output_type_mismatch, "facts", "Array<string>"}}} =
               Runner.run(reflection(context), ingestion(), inference: fn _ -> {:ok, %{output: %{"facts" => "not a list"}}} end)
    end
  end

  describe "when the final Chain of Thought step returns valid structured output" do
    test "then that structured output becomes the Reflection's single artefact", context do
      assert {:ok, artefact} = Runner.run(reflection(context), ingestion(), inference: &output_for/1)
      assert artefact.payload == %{"artefact" => "durable pattern"}
    end

    test "and the artefact is stored at the destination named by the Reflection", context do
      reflection = reflection(context)
      assert {:ok, artefact} = Runner.run(reflection, ingestion(), inference: &output_for/1)
      assert :ok = Store.put(reflection, "operator-one", artefact, storage: Gralkor.Reflection.Storage.InMemory)
      assert {:ok, [^artefact]} = Store.search([reflection], "operator-one", reflection.name, "durable", storage: Gralkor.Reflection.Storage.InMemory)
    end

    test "and the artefact identifies its declaring Reflection", context do
      assert {:ok, %{reflection: "generalisation"}} = Runner.run(reflection(context), ingestion(), inference: &output_for/1)
    end

    test "and the artefact retains its supporting evidence identifiers", context do
      assert {:ok, %{evidence_ids: ["ev-1", "ev-2"]}} = Runner.run(reflection(context), ingestion(), inference: &output_for/1)
    end

    test "where the declared destination is operator-scoped then the artefact is available only to the operator whose ingestion triggered the Reflection", context do
      reflection = reflection(context)
      {:ok, artefact} = Runner.run(reflection, ingestion(), inference: &output_for/1)
      :ok = Store.put(reflection, "operator-one", artefact, storage: Gralkor.Reflection.Storage.InMemory)
      assert {:ok, [_]} = Store.search([reflection], "operator-one", reflection.name, "durable", storage: Gralkor.Reflection.Storage.InMemory)
      assert {:ok, []} = Store.search([reflection], "operator-two", reflection.name, "durable", storage: Gralkor.Reflection.Storage.InMemory)
    end

    test "where the declared destination is global then the artefact is available through the shared global destination", context do
      reflection = reflection(context, "generalisation", :global)
      {:ok, artefact} = Runner.run(reflection, ingestion(), inference: &output_for/1)
      :ok = Store.put(reflection, "operator-one", artefact, storage: Gralkor.Reflection.Storage.InMemory)
      assert {:ok, [^artefact]} = Store.search([reflection], "operator-two", reflection.name, "durable", storage: Gralkor.Reflection.Storage.InMemory)
    end
  end

  describe "when multiple declared Reflections process one completed ingestion operation" do
    test "then every Reflection runs independently", context do
      runner = fn reflection, _, _ -> send(self(), {:not_parent, reflection.name}); {:error, :failure} end
      # The notification seam proves both isolated tasks finish regardless of outcome.
      assert {:ok, :scheduled} = Scheduler.schedule([reflection(context, "one"), reflection(context, "two")], ingestion(), runner: runner, notify: self())
      assert_receive {:reflection_completed, "one", {:error, :failure}}
      assert_receive {:reflection_completed, "two", {:error, :failure}}
    end

    test "and failure of one Reflection does not prevent another Reflection from completing", context do
      runner = fn reflection, _, _ ->
        if reflection.name == "one", do: {:error, %{reflection: "one", reason: :failed}}, else: Runner.run(reflection, ingestion(), inference: &output_for/1)
      end
      assert {:ok, :scheduled} = Scheduler.schedule([reflection(context, "one"), reflection(context, "two")], ingestion(), runner: runner, notify: self(), store_opts: [storage: Gralkor.Reflection.Storage.InMemory])
      assert_receive {:reflection_completed, "one", {:error, %{reason: :failed}}}
      assert_receive {:reflection_completed, "two", {:ok, _}}
    end
  end

  test "if any intended Lens ingestion fails then no Reflection is scheduled for the incomplete ingestion operation", context do
    runner = notifying_runner(self())
    assert {:error, {:incomplete_ingestion, "ingestion-1"}} = Scheduler.schedule([reflection(context)], failed_ingestion(), runner: runner)
    refute_receive {:ran, _}
  end

  describe "if a Reflection's Chain of Thought completes without a valid final structured output" do
    test "then the Reflection fails identifying its name and missing artefact", context do
      assert {:error, %{reflection: "generalisation", reason: :missing_artefact}} =
               Runner.run(one_step_reflection(context), ingestion(), inference: fn _ -> {:ok, %{output: %{}}} end)
    end

    test "and the successful ingestion result remains unchanged", context do
      original = ingestion()
      _ = Runner.run(one_step_reflection(context), original, inference: fn _ -> {:ok, %{output: %{}}} end)
      assert original == ingestion()
    end
  end

  describe "if a Reflection's Chain of Thought fails" do
    test "then the Reflection failure identifies its name and reason", context do
      assert {:error, %{reflection: "generalisation", reason: :inference_failed}} = Runner.run(reflection(context), ingestion(), inference: fn _ -> {:error, :inference_failed} end)
    end

    test "and the successful ingestion result remains unchanged", context do
      original = ingestion()
      _ = Runner.run(reflection(context), original, inference: fn _ -> {:error, :failed} end)
      assert original == ingestion()
    end

    test "and every other declared Reflection remains eligible to complete", context do
      runner = fn reflection, _, _ -> if reflection.name == "one", do: {:error, :failed}, else: Runner.run(reflection, ingestion(), inference: &output_for/1) end
      assert {:ok, :scheduled} = Scheduler.schedule([reflection(context, "one"), reflection(context, "two")], ingestion(), runner: runner, notify: self(), store_opts: [storage: Gralkor.Reflection.Storage.InMemory])
      assert_receive {:reflection_completed, "two", {:ok, _}}
    end
  end

  describe "if storing a Reflection artefact at its destination fails" do
    test "then the Reflection failure identifies its name, destination, and reason", context do
      assert {:ok, :scheduled} = Scheduler.schedule([reflection(context)], ingestion(), runner_opts: [inference: &output_for/1], notify: self(), store_opts: [storage: FailingReflectionStorage])
      assert_receive {:reflection_completed, "generalisation", {:error, %{reflection: "generalisation", destination: "generalisation", reason: :destination_unavailable}}}
    end

    test "and the successful ingestion result remains unchanged", context do
      original = ingestion()
      assert {:ok, :scheduled} = Scheduler.schedule([reflection(context)], original, runner_opts: [inference: &output_for/1], store_opts: [storage: FailingReflectionStorage])
      assert original == ingestion()
    end

    test "and every other declared Reflection remains eligible to complete", context do
      assert {:ok, :scheduled} = Scheduler.schedule([reflection(context, "one"), reflection(context, "two")], ingestion(), runner_opts: [inference: &output_for/1], notify: self(), store_opts: [storage: FailingReflectionStorage])
      assert_receive {:reflection_completed, "one", {:error, _}}
      assert_receive {:reflection_completed, "two", {:error, _}}
    end
  end

  describe "when memory is searched naming a Reflection" do
    test "then that Reflection's destination is searched", context do
      {reflection, artefact} = stored_artefact(context)
      assert {:ok, [^artefact]} = Store.search([reflection], "operator-one", reflection.name, "durable", storage: Gralkor.Reflection.Storage.InMemory)
    end

    test "and only artefacts produced by that Reflection are returned", context do
      one = reflection(context, "one")
      two = reflection(context, "two")
      {:ok, a1} = Runner.run(one, ingestion(), inference: &output_for/1)
      {:ok, a2} = Runner.run(two, ingestion(), inference: &output_for/1)
      :ok = Store.put(one, "operator-one", a1, storage: Gralkor.Reflection.Storage.InMemory)
      :ok = Store.put(two, "operator-one", a2, storage: Gralkor.Reflection.Storage.InMemory)
      assert {:ok, [^a1]} = Store.search([one, two], "operator-one", "one", "", storage: Gralkor.Reflection.Storage.InMemory)
    end

    test "and every result identifies the named Reflection rather than a Lens", context do
      {reflection, _} = stored_artefact(context)
      assert {:ok, [%{reflection: "generalisation"} = result]} = Store.search([reflection], "operator-one", reflection.name, "durable", storage: Gralkor.Reflection.Storage.InMemory)
      refute Map.has_key?(Map.from_struct(result), :lens)
    end

    test "and every result retains its supporting evidence identifiers", context do
      {reflection, _} = stored_artefact(context)
      assert {:ok, [%{evidence_ids: ["ev-1", "ev-2"]}]} = Store.search([reflection], "operator-one", reflection.name, "durable", storage: Gralkor.Reflection.Storage.InMemory)
    end

    test "where the search also identifies one artefact then only that artefact is returned from the named Reflection's destination", context do
      {reflection, artefact} = stored_artefact(context)
      {:ok, other} = Runner.run(reflection, ingestion(), inference: &output_for/1)
      :ok = Store.put(reflection, "operator-one", other, storage: Gralkor.Reflection.Storage.InMemory)
      assert {:ok, [^artefact]} = Store.search([reflection], "operator-one", reflection.name, "durable", artefact_id: artefact.id, storage: Gralkor.Reflection.Storage.InMemory)
    end
  end

  test "if memory is searched naming an unknown Reflection then the search fails identifying the unknown Reflection before any destination is searched" do
    assert {:error, {:unknown_reflection, "missing"}} = Store.search([], "operator-one", "missing", "query", storage: FailingReflectionStorage)
  end

  defp assert_valid(%{root: root}) do
    assert {:ok, [%Gralkor.Reflection{name: "generalisation", scope: :operator}]} =
             Registry.load([valid_definition(root)], root: root)
  end

  defp reflection(%{root: root}, name \\ "generalisation", scope \\ :operator) do
    [reflection] = Registry.load!([valid_definition(root, name: name, scope: scope)], root: root)
    reflection
  end

  defp one_step_reflection(%{root: root}) do
    write_cot(root, "one-step.yaml", "steps:\n  - label: reflect\n    directions: Reflect.\n    output: {artefact: string}\n")
    [reflection] = Registry.load!([valid_definition(root, chain_of_thought: "one-step.yaml")], root: root)
    reflection
  end

  defp ingestion do
    %{
      id: "ingestion-1",
      operator_id: "operator-one",
      intended_lenses: ["observations", "decisions"],
      representations: [
        %{evidence_id: "ev-1", lens: "observations", result: :ok},
        %{evidence_id: "ev-2", lens: "decisions", result: :ok}
      ]
    }
  end

  defp incomplete_ingestion do
    ingestion() |> Map.put(:representations, [%{evidence_id: "ev-1", lens: "observations", result: :ok}])
  end

  defp failed_ingestion do
    ingestion() |> Map.update!(:representations, fn [first, second] -> [first, %{second | result: {:error, :failed}}] end)
  end

  defp output_for(%{step: %{label: "gather"}}), do: {:ok, %{output: %{"facts" => ["fact one"]}}}
  defp output_for(%{step: %{label: "synthesise"}}), do: {:ok, %{output: %{"artefact" => "durable pattern"}}}
  defp output_for(%{step: %{label: "reflect"}}), do: {:ok, %{output: %{"artefact" => "durable pattern"}}}

  defp run_and_collect_requests(reflection, ingestion) do
    parent = self()
    inference = fn request -> send(parent, {:request, request}); output_for(request) end
    assert {:ok, _} = Runner.run(reflection, ingestion, inference: inference)
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
        call = if total_calls == 1, do: %{name: "memory_search", arguments: %{"query" => "pattern"}}, else: %{name: "tool-#{count + 1}", arguments: %{}}
        {:ok, %{tool_calls: [call]}}
      else
        send(parent, {:continued, request.step.label, Enum.map(request.tool_results, &%{result: &1.result})})
        send(parent, {:continued_tools, request.step.label, request.tools})
        {:ok, %{output: %{"artefact" => "done"}}}
      end
    end
  end

  defp notifying_runner(parent), do: fn reflection, _, _ -> send(parent, {:ran, reflection.name}); {:error, :done} end

  defp stored_artefact(context) do
    reflection = reflection(context)
    {:ok, artefact} = Runner.run(reflection, ingestion(), inference: &output_for/1)
    :ok = Store.put(reflection, "operator-one", artefact, storage: Gralkor.Reflection.Storage.InMemory)
    {reflection, artefact}
  end

  defp valid_definition(root, overrides \\ []) do
    unless File.exists?(Path.join(root, "valid.yaml")) do
      write_cot(root, "valid.yaml", """
      steps:
        - label: gather
          directions: Gather evidence.
          output:
            facts: Array<string>
        - label: synthesise
          directions: "Synthesise {{facts}}"
          output:
            artefact: string
      """)
    end

    Keyword.merge(
      [name: "generalisation", chain_of_thought: "valid.yaml", scope: :operator],
      overrides
    )
  end

  defp write_cot(root, name, body) do
    path = Path.join(root, name)
    File.write!(path, body)
    path
  end
end
