defmodule Gralkor.ReflectionSystemFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  alias Gralkor.Client
  alias Gralkor.CaptureBuffer
  alias Gralkor.Ingest
  alias Gralkor.Message
  alias Gralkor.Reflection.Registry
  alias Gralkor.Reflection.Runner
  alias Gralkor.Reflection.Scheduler
  alias Gralkor.Reflection.Store
  alias Gralkor.Search

  defmodule ReflectionEvidenceOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open
  end

  defmodule EvidenceIngestion do
    @behaviour Gralkor.Lens.Ingestion

    @impl true
    def ingest(request, store) do
      with :ok <-
             Gralkor.Lens.Store.add(
               store,
               "first lensed: #{request.content}",
               request.source_description
             ) do
        Gralkor.Lens.Store.add(
          store,
          "second lensed: #{request.content}",
          request.source_description
        )
      end
    end
  end

  defmodule FailingReflectionStorage do
    @behaviour Gralkor.Reflection.Store
    def put(_, _, _), do: {:error, :destination_unavailable}
    def search(_, _, _, _), do: {:error, :destination_unavailable}
    def get(_, _, _), do: {:error, :destination_unavailable}
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "gralkor-reflection-#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    start_supervised!(Gralkor.Reflection.Storage.InMemory)
    start_supervised!(Gralkor.Lens.Storage.InMemory)

    start_supervised!(
      {Scheduler,
       runner: fn reflection, ingestion, opts ->
         Runner.run(reflection, ingestion, Keyword.put_new(opts, :inference, &output_for/1))
       end}
    )

    previous =
      for key <- [
            :destinations,
            :destination_storage,
            :lenses,
            :lens_storage,
            :reflections,
            :reflection_storage
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
    Application.put_env(:jido_gralkor, :reflection_storage, Gralkor.Reflection.Storage.InMemory)

    on_exit(fn -> Enum.each(previous, fn {key, value} -> restore_env(key, value) end) end)
    %{root: root}
  end

  describe "when Reflection declarations are validated" do
    test("while every Reflection has a non-blank name", context, do: assert_valid(context))
    test("and every Reflection name is unique", context, do: assert_valid(context))

    test("and every Reflection references a repository YAML Chain of Thought", context,
      do: assert_valid(context)
    )

    test("and every referenced Chain of Thought contains one or more ordered steps", context,
      do: assert_valid(context)
    )

    test("and every step has a non-blank label and natural-language directions", context,
      do: assert_valid(context)
    )

    test("and every step declares one or more named structured outputs and their types", context,
      do: assert_valid(context)
    )

    test("and output names are unique across the Chain of Thought", context,
      do: assert_valid(context)
    )

    test("and every interpolation references an output from an earlier step", context,
      do: assert_valid(context)
    )

    test(
      "and every Reflection references a registered Destination by name then validation succeeds",
      context,
      do: assert_valid(context)
    )

    test "if the configured Reflection registry is not a list then validation fails identifying the configured value" do
      Application.put_env(:jido_gralkor, :reflections, :invalid_registry)

      assert_raise ArgumentError, ~r/invalid Reflection declarations: :invalid_registry/, fn ->
        Registry.configured!()
      end
    end

    test "if a Reflection name is blank then validation fails identifying the blank name", %{
      root: root
    } do
      assert {:error, {:blank_name, " "}} =
               Registry.load([valid_definition(root, name: " ")], root: root)

      Application.put_env(:jido_gralkor, :reflections, [
        %Gralkor.Reflection{
          name: " ",
          destination: %Gralkor.Destination{name: "global"},
          ontology: Gralkor.DefaultOntology,
          chain_of_thought: %Gralkor.Reflection.ChainOfThought{path: "loaded.yaml", steps: []}
        }
      ])

      assert_raise ArgumentError, ~r/blank_name.*" "/, fn -> Registry.configured!() end
    end

    test "if Reflection names are duplicated then validation fails identifying the duplicate name",
         %{root: root} do
      definition = valid_definition(root)

      assert {:error, {:duplicate_name, "generalisation"}} =
               Registry.load([definition, definition], root: root)
    end

    test "if a Reflection has no Chain of Thought then validation fails identifying that Reflection",
         %{root: root} do
      definition = valid_definition(root) |> Keyword.delete(:chain_of_thought)

      assert {:error, {:missing_chain_of_thought, "generalisation"}} =
               Registry.load([definition], root: root)
    end

    test "if a Reflection's Chain of Thought does not identify a repository YAML file then validation fails identifying that Reflection and file",
         %{root: root} do
      assert {:error, {:invalid_chain_of_thought_file, "generalisation", "../outside.yaml"}} =
               Registry.load([valid_definition(root, chain_of_thought: "../outside.yaml")],
                 root: root
               )
    end

    test "if a Reflection's Chain of Thought YAML cannot be loaded or parsed then validation fails identifying that Reflection, file, and parse failure",
         %{root: root} do
      write_cot(root, "broken.yaml", "steps: [")

      assert {:error, {:invalid_chain_of_thought, "generalisation", "broken.yaml", _}} =
               Registry.load([valid_definition(root, chain_of_thought: "broken.yaml")],
                 root: root
               )
    end

    test "if a Chain of Thought has no steps then validation fails identifying that Reflection and Chain of Thought",
         %{root: root} do
      write_cot(root, "empty.yaml", "steps: []")

      assert {:error, {:invalid_chain_of_thought, "generalisation", "empty.yaml", :missing_steps}} =
               Registry.load([valid_definition(root, chain_of_thought: "empty.yaml")], root: root)
    end

    test "if a Chain of Thought step has no non-blank label then validation fails identifying that Reflection and step",
         %{root: root} do
      write_cot(
        root,
        "blank-label.yaml",
        "steps:\n  - label: ' '\n    directions: Think.\n    output: {result: string}\n"
      )

      assert {:error,
              {:invalid_chain_of_thought, "generalisation", "blank-label.yaml",
               {:invalid_step_label, " "}}} =
               Registry.load([valid_definition(root, chain_of_thought: "blank-label.yaml")],
                 root: root
               )
    end

    test "if a Chain of Thought step has no natural-language directions then validation fails identifying that Reflection and step",
         %{root: root} do
      write_cot(
        root,
        "no-directions.yaml",
        "steps:\n  - label: think\n    output: {result: string}\n"
      )

      assert {:error,
              {:invalid_chain_of_thought, "generalisation", "no-directions.yaml",
               {:invalid_step_directions, "think"}}} =
               Registry.load([valid_definition(root, chain_of_thought: "no-directions.yaml")],
                 root: root
               )
    end

    test "if a Chain of Thought step has no structured-output declaration then validation fails identifying that Reflection and step",
         %{root: root} do
      write_cot(root, "no-output.yaml", "steps:\n  - label: think\n    directions: Think.\n")

      assert {:error,
              {:invalid_chain_of_thought, "generalisation", "no-output.yaml",
               {:invalid_step_output, "think"}}} =
               Registry.load([valid_definition(root, chain_of_thought: "no-output.yaml")],
                 root: root
               )
    end

    test "if a Chain of Thought step is not a map then validation fails identifying that Reflection and step",
         %{root: root} do
      write_cot(root, "invalid-step.yaml", "steps:\n  - not-a-step\n")

      assert {:error,
              {:invalid_chain_of_thought, "generalisation", "invalid-step.yaml",
               {:invalid_step, "not-a-step"}}} =
               Registry.load([valid_definition(root, chain_of_thought: "invalid-step.yaml")],
                 root: root
               )
    end

    test "if a Chain of Thought step declares an unsupported structured-output type then validation fails identifying that Reflection, step, and type",
         %{root: root} do
      write_cot(
        root,
        "invalid-type.yaml",
        "steps:\n  - label: think\n    directions: Think.\n    output: {result: mystery}\n"
      )

      assert {:error,
              {:invalid_chain_of_thought, "generalisation", "invalid-type.yaml",
               {:invalid_output_type, "think", "mystery"}}} =
               Registry.load([valid_definition(root, chain_of_thought: "invalid-type.yaml")],
                 root: root
               )
    end

    test "if an output name is declared by more than one step then validation fails identifying that Reflection, output name, and steps",
         %{root: root} do
      write_cot(
        root,
        "duplicate-output.yaml",
        "steps:\n  - {label: one, directions: First., output: {result: string}}\n  - {label: two, directions: Second., output: {result: string}}\n"
      )

      assert {:error,
              {:invalid_chain_of_thought, "generalisation", "duplicate-output.yaml",
               {:duplicate_output, "result", "one", "two"}}} =
               Registry.load([valid_definition(root, chain_of_thought: "duplicate-output.yaml")],
                 root: root
               )
    end

    test "if an interpolation references an output not declared by an earlier step then validation fails identifying that Reflection, step, and interpolation",
         %{root: root} do
      write_cot(
        root,
        "forward.yaml",
        "steps:\n  - label: one\n    directions: Use {{later}}.\n    output: {first: string}\n  - {label: two, directions: Later., output: {later: string}}\n"
      )

      assert {:error,
              {:invalid_chain_of_thought, "generalisation", "forward.yaml",
               {:unknown_interpolation, "later", "one"}}} =
               Registry.load([valid_definition(root, chain_of_thought: "forward.yaml")],
                 root: root
               )
    end

    test "if a Reflection has no Destination name then validation fails identifying that Reflection",
         %{root: root} do
      definition = valid_definition(root) |> Keyword.delete(:destination)

      assert {:error, {:missing_destination, "generalisation", nil}} =
               Registry.load([definition], root: root)
    end

    test "if a Reflection references an unknown Destination then validation fails identifying that Reflection and Destination",
         %{root: root} do
      assert_raise ArgumentError,
                   ~r/Reflection "generalisation" references unknown Destination "missing"/,
                   fn ->
                     Registry.load([valid_definition(root, destination: "missing")], root: root)
                   end
    end

    test "if a Reflection declares an invalid ontology then validation fails identifying that Reflection and ontology",
         %{root: root} do
      assert {:error, {:invalid_ontology, "generalisation", String}} =
               Registry.load([valid_definition(root, ontology: String)], root: root)
    end
  end

  describe "where the packaged default Reflections are used" do
    test "then ERL references the packaged `operator` Destination" do
      Application.delete_env(:jido_gralkor, :reflections)

      assert %Gralkor.Reflection{
               name: "erl",
               destination: %Gralkor.Destination{name: "operator"}
             } = Enum.find(Registry.configured!(), &(&1.name == "erl"))
    end

    test "and ERL carries jido_gralkor's built-in experiential-learning ontology" do
      Application.delete_env(:jido_gralkor, :reflections)
      erl = Enum.find(Registry.configured!(), &(&1.name == "erl"))

      assert erl.ontology == Gralkor.Reflection.ERLOntology
    end

    test "and generalisation references the packaged `global` Destination" do
      Application.delete_env(:jido_gralkor, :reflections)
      generalisation = Enum.find(Registry.configured!(), &(&1.name == "generalisations"))

      assert generalisation.destination.name == "global"
    end
  end

  describe "where an application-defined Reflection omits its ontology" do
    test "then its final artefact receives generic extraction",
         %{root: root} do
      reflection = Registry.load!([valid_definition(root)], root: root) |> List.first()
      assert reflection.ontology == Gralkor.DefaultOntology
    end
  end

  describe "where an application-defined Reflection declares an application ontology" do
    test "then its final artefact is extracted through that Reflection's ontology", %{root: root} do
      reflection =
        Registry.load!(
          [
            valid_definition(root,
              destination: "observations",
              ontology: ReflectionEvidenceOntology
            )
          ],
          root: root
        )
        |> List.first()

      assert reflection.ontology == ReflectionEvidenceOntology
    end
  end

  describe "when the default ERL Reflection stores its final artefact" do
    test "then extraction receives the built-in `Learning` entity type from ERL's ontology" do
      Application.delete_env(:jido_gralkor, :reflections)
      erl = Enum.find(Registry.configured!(), &(&1.name == "erl"))
      artefact = Gralkor.Reflection.Artefact.new("erl", erl_payload(), ["evidence-one"])
      caller = self()

      add_episode = fn group_id, content, source, ontology, opts ->
        send(caller, {:reflection_episode, group_id, content, source, ontology, opts})
        :ok
      end

      assert :ok =
               Gralkor.Reflection.Storage.Graphiti.put(
                 erl,
                 "operator-one",
                 artefact,
                 add_episode
               )

      assert_receive {:reflection_episode, _group_id, _content, "reflection:erl",
                      Gralkor.Reflection.ERLOntology, [uuid: artefact_id]}

      assert artefact_id == artefact.id
    end

    test "and the `Learning` extraction contract declares optional problem kind, approach, success, and reusable lesson fields" do
      [learning] = Gralkor.Reflection.ERLOntology.__ontology__().entity_types

      assert learning.name == "Learning"
      assert Enum.map(learning.fields, & &1.name) == [:problem_kind, :approach, :success, :lesson]
      assert Enum.all?(learning.fields, &(&1.required == false))
    end

    test "and the stored Learning payload contains exactly its problem kind, approach, success, and reusable lesson" do
      Application.delete_env(:jido_gralkor, :reflections)
      erl = Enum.find(Registry.configured!(), &(&1.name == "erl"))

      assert {:ok, artefact} = Runner.run(erl, ingestion(), inference: &erl_output_for/1)
      assert artefact.payload == erl_payload()
    end
  end

  describe "when an ingestion operation successfully stores information through one or more Lenses" do
    test "while Reflections are declared then every stored representation retains its own identifier, Lens identity, content, and storage result" do
      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "observations",
          destination: "observations",
          ingestion: EvidenceIngestion
        ]
      ])

      request = %Ingest{
        id: "reflection-lens-ingestion",
        operator_id: "operator-one",
        lens: "observations",
        source_kind: :document,
        content: "fact one",
        source_description: "functional"
      }

      assert {:ok, [first, second]} = Client.ingest_with_representation(request)

      first_id = first.id
      second_id = second.id

      assert Map.from_struct(first) == %{
               id: first_id,
               lens: "observations",
               content: "first lensed: fact one",
               result: :ok
             }

      assert Map.from_struct(second) == %{
               id: second_id,
               lens: "observations",
               content: "second lensed: fact one",
               result: :ok
             }

      assert is_binary(first_id) and first_id != ""
      assert is_binary(second_id) and second_id != ""
      refute first_id == second_id

      assert Enum.map(
               Gralkor.Lens.Storage.InMemory.episodes(
                 Gralkor.Destination.graph_id(
                   Gralkor.Destination.Registry.fetch!("observations"),
                   "operator-one"
                 )
               ),
               & &1.content
             ) == ["first lensed: fact one", "second lensed: fact one"]
    end

    test "and the ingestion caller receives success without waiting for Reflection", context do
      reflection = reflection(context)
      configure_reflections([reflection])

      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "observations",
          destination: "observations",
          ingestion: EvidenceIngestion
        ]
      ])

      started = System.monotonic_time(:millisecond)

      assert :ok =
               Client.ingest(%Ingest{
                 id: "reflection-direct-ingestion",
                 operator_id: "operator-one",
                 lens: "observations",
                 source_kind: :document,
                 content: "direct fact",
                 source_description: "functional"
               })

      assert System.monotonic_time(:millisecond) - started < 100
    end

    test "and every declared Reflection is scheduled once for the completed ingestion operation",
         context do
      reflections = [reflection(context, "one"), reflection(context, "two")]
      parent = self()

      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "observations",
          destination: "observations",
          ingestion: EvidenceIngestion
        ],
        [
          name: "decisions",
          destination: "decisions",
          ingestion: EvidenceIngestion
        ]
      ])

      start_supervised!(
        {CaptureBuffer,
         flush_callback: fn _, _, _, _, _ -> :ok end,
         lens_flush_callback: Gralkor.Application.build_lens_flush_callback(),
         reflection_callback: fn _reflections, ingestion ->
           send(parent, {:scheduled, Enum.map(reflections, & &1.name), ingestion})
           :ok
         end,
         reflections: reflections,
         retries: []}
      )

      :ok =
        CaptureBuffer.append_lenses(
          "session-once",
          "operator-one",
          "Susu",
          "Eli",
          ["observations", "decisions"],
          [Message.new("user", "remember")]
        )

      assert :ok = CaptureBuffer.flush_and_await("session-once", 1_000)

      assert_receive {:scheduled, ["one", "two"],
                      %{intended_lenses: ["observations", "decisions"], representations: reps}}

      assert Enum.map(reps, & &1.lens) == [
               "observations",
               "observations",
               "decisions",
               "decisions"
             ]

      assert reps |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 4
      refute_receive {:scheduled, _, _}
    end

    test "and no Reflection begins before every intended Lens ingestion has completed", context do
      parent = self()

      start_supervised!(
        {CaptureBuffer,
         flush_callback: fn _, _, _, _, _ -> :ok end,
         lens_flush_callback: representation_callback(parent),
         reflection_callback: fn _reflections, ingestion ->
           send(parent, {:scheduled_after_all, ingestion})
           :ok
         end,
         reflections: [reflection(context)],
         retries: []}
      )

      :ok =
        CaptureBuffer.append_lenses(
          "session-barrier",
          "operator-one",
          "Susu",
          "Eli",
          ["observations", "decisions"],
          [Message.new("user", "remember")]
        )

      assert :ok = CaptureBuffer.flush_and_await("session-barrier", 1_000)
      assert_receive {:lens_stored, "observations"}
      assert_receive {:lens_stored, "decisions"}
      assert_receive {:scheduled_after_all, %{representations: [_, _]}}
    end
  end

  describe "when a configured Reflection is loaded" do
    test "then its declared YAML is loaded as the programmatic Chain of Thought", context do
      assert %Gralkor.Reflection.ChainOfThought{path: path} = reflection(context).chain_of_thought
      assert String.ends_with?(path, ".yaml")
    end
  end

  describe "when a scheduled Reflection runs" do
    test "and starts its first step for the operator and completed ingestion operation",
         context do
      parent = self()

      inference = fn request ->
        send(parent, {:first, request.operator_id, request.step.label})
        output_for(request)
      end

      assert {:ok, _} = Runner.run(reflection(context), ingestion(), inference: inference)
      assert_receive {:first, "operator-one", "gather"}
    end

    test "and makes every ingested representation available with its identifier, Lens identity, content, and storage result",
         context do
      parent = self()

      inference = fn request ->
        send(parent, {:available, request.representations})
        output_for(request)
      end

      assert {:ok, _} = Runner.run(reflection(context), ingestion(), inference: inference)

      assert_receive {:available,
                      [
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
                      ]}
    end
  end

  describe "when a Chain of Thought step begins" do
    test "then built-in inference receives that step's interpolated natural-language directions",
         context do
      requests = run_and_collect_requests(reflection(context), ingestion())
      assert Enum.at(requests, 1).directions == "Synthesise [\"fact one\"]"
    end

    test "and receives that step's declared structured-output contract", context do
      assert [first | _] = run_and_collect_requests(reflection(context), ingestion())
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
        stored_information: [],
        tools: tools,
        tool_context: tool_context,
        operator_id: "operator-one"
      }

      call = fn Jido.AI.Actions.ToolCalling.CallWithTools, params, received ->
        send(self(), {:default_inference, params, received})
        {:ok, %{text: ~s({"artefact":"done"})}}
      end

      assert {:ok, %{output: %{"artefact" => "done"}}} = Runner.default_inference(request, call)

      assert_receive {:default_inference, %{auto_execute: true, model: model, prompt: prompt},
                      received_context}

      configured = Gralkor.Config.llm_model()
      assert model == "#{configured.provider}:#{configured.id}"
      assert prompt =~ ~s("lens":"observations")
      assert received_context.tools == tools

      assert Map.drop(received_context, [:tools]) ==
               Map.merge(tool_context, %{operator_id: "operator-one"})
    end

    test "and the current step is the only step exposed to inference", context do
      assert [first | _] = run_and_collect_requests(reflection(context), ingestion())
      assert first.step == %{label: "gather", directions: "Gather evidence."}
      refute Map.has_key?(first, :steps)
    end

    test "where the directions reference outputs from earlier steps then every referenced value is interpolated from the Chain of Thought's shared output space",
         context do
      assert [_first, second] = run_and_collect_requests(reflection(context), ingestion())
      assert second.directions =~ "fact one"
      refute second.directions =~ "{{facts}}"
    end

    @tag timeout: 120_000
    test "where inference directs a tool call then the requested tool is called with the model-produced arguments",
         context do
      parent = self()
      inference = tool_calling_inference(parent, 1)

      executor = fn call, _ ->
        send(parent, {:executed, call})
        {:ok, "found"}
      end

      assert {:ok, _} =
               Runner.run(one_step_reflection(context), ingestion(),
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
               Runner.run(one_step_reflection(context), ingestion(),
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
               Runner.run(one_step_reflection(context), ingestion(),
                 inference: inference,
                 tools: tools,
                 tool_executor: fn _, _ -> :ok end
               )

      assert_receive {:continued_tools, "reflect", ^tools}
    end

    test "where inference directs further tool calls then each requested call and result continues the same step in sequence",
         context do
      parent = self()
      inference = tool_calling_inference(parent, 2)

      executor = fn call, _ ->
        send(parent, {:tool_sequence, call.name})
        {:ok, call.name}
      end

      assert {:ok, _} =
               Runner.run(one_step_reflection(context), ingestion(),
                 inference: inference,
                 tool_executor: executor
               )

      assert_receive {:tool_sequence, "tool-1"}
      assert_receive {:tool_sequence, "tool-2"}
    end
  end

  describe "when inference returns a structured output for the current step" do
    test "while its keys and values satisfy that step's declared output contract then the output is added to the Chain of Thought's shared output space",
         context do
      assert [_first, second] = run_and_collect_requests(reflection(context), ingestion())
      assert second.directions =~ "fact one"
    end

    test "and the next step begins with those outputs available for interpolation", context do
      assert [_first, second] = run_and_collect_requests(reflection(context), ingestion())
      assert second.step.label == "synthesise"
      assert second.directions == "Synthesise [\"fact one\"]"
    end

    test "if a declared output key is missing then the Reflection fails identifying its name, current step, and missing key",
         context do
      assert {:error,
              %{reflection: "generalisation", step: "gather", reason: {:missing_output, "facts"}}} =
               Runner.run(reflection(context), ingestion(),
                 inference: fn _ -> {:ok, %{output: %{}}} end
               )
    end

    test "if an undeclared output key is returned then the Reflection fails identifying its name, current step, and unexpected key",
         context do
      assert {:error,
              %{
                reflection: "generalisation",
                step: "gather",
                reason: {:unexpected_output, "extra"}
              }} =
               Runner.run(reflection(context), ingestion(),
                 inference: fn _ -> {:ok, %{output: %{"facts" => [], "extra" => true}}} end
               )
    end

    test "if an output value does not satisfy its declared type then the Reflection fails identifying its name, current step, and type mismatch",
         context do
      assert {:error,
              %{
                reflection: "generalisation",
                step: "gather",
                reason: {:output_type_mismatch, "facts", "Array<string>"}
              }} =
               Runner.run(reflection(context), ingestion(),
                 inference: fn _ -> {:ok, %{output: %{"facts" => "not a list"}}} end
               )
    end
  end

  describe "when the final Chain of Thought step returns valid structured output" do
    test "then that structured output becomes the Reflection's single artefact", context do
      assert {:ok, artefact} =
               Runner.run(reflection(context), ingestion(), inference: &output_for/1)

      assert artefact.payload == %{"artefact" => "durable pattern"}
    end

    test "and the artefact is stored at the destination named by the Reflection", context do
      reflection = reflection(context)
      assert {:ok, artefact} = Runner.run(reflection, ingestion(), inference: &output_for/1)

      assert :ok =
               Store.put(reflection, "operator-one", artefact,
                 storage: Gralkor.Reflection.Storage.InMemory
               )

      assert {:ok, [%{destination: "operator", artefact: ^artefact}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "durable",
                 destinations: [reflection.destination.name],
                 result_type: :artefacts
               })
    end

    test "and the artefact identifies its declaring Reflection", context do
      assert {:ok, %{reflection: "generalisation"}} =
               Runner.run(reflection(context), ingestion(), inference: &output_for/1)
    end

    test "and the artefact consists of its stable identifier, declaring Reflection, and structured payload",
         context do
      assert {:ok, artefact} =
               Runner.run(reflection(context), ingestion(), inference: &output_for/1)

      assert Map.from_struct(artefact) == %{
               id: artefact.id,
               reflection: "generalisation",
               payload: %{"artefact" => "durable pattern"}
             }
    end

    test "where the referenced Destination is `operator` then the artefact is available only to the operator whose ingestion triggered the Reflection",
         context do
      reflection = reflection(context)
      {:ok, artefact} = Runner.run(reflection, ingestion(), inference: &output_for/1)

      :ok =
        Store.put(reflection, "operator-one", artefact,
          storage: Gralkor.Reflection.Storage.InMemory
        )

      assert {:ok, [_]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "durable",
                 destinations: [reflection.destination.name],
                 result_type: :artefacts
               })

      assert {:ok, []} =
               Client.search(%Search{
                 operator_id: "operator-two",
                 query: "durable",
                 destinations: [reflection.destination.name],
                 result_type: :artefacts
               })
    end

    test "where the referenced Destination is not `operator` then the artefact is available to every operator through that Destination's one graph",
         context do
      reflection = reflection(context, "generalisation", "global")
      {:ok, artefact} = Runner.run(reflection, ingestion(), inference: &output_for/1)

      :ok =
        Store.put(reflection, "operator-one", artefact,
          storage: Gralkor.Reflection.Storage.InMemory
        )

      assert {:ok, [%{destination: "global", artefact: ^artefact}]} =
               Client.search(%Search{
                 operator_id: "operator-two",
                 query: "durable",
                 destinations: [reflection.destination.name],
                 result_type: :artefacts
               })
    end
  end

  describe "when multiple declared Reflections process one completed ingestion operation" do
    test "then every Reflection runs independently", context do
      runner = fn reflection, _, _ ->
        send(self(), {:not_parent, reflection.name})
        {:error, :failure}
      end

      # The notification seam proves both isolated tasks finish regardless of outcome.
      assert {:ok, :scheduled} =
               Scheduler.schedule(
                 [reflection(context, "one"), reflection(context, "two")],
                 ingestion(),
                 runner: runner,
                 notify: self(),
                 retry_delays: []
               )

      assert_receive {:reflection_completed, "one", {:error, %{reason: :failure}}}
      assert_receive {:reflection_completed, "two", {:error, %{reason: :failure}}}
    end

    test "and failure of one Reflection does not prevent another Reflection from completing",
         context do
      runner = fn reflection, completed_ingestion, opts ->
        if reflection.name == "one",
          do: {:error, %{reflection: "one", reason: :failed}},
          else:
            Runner.run(
              reflection,
              completed_ingestion,
              Keyword.put(opts, :inference, &output_for/1)
            )
      end

      assert {:ok, :scheduled} =
               Scheduler.schedule(
                 [reflection(context, "one"), reflection(context, "two")],
                 ingestion(),
                 runner: runner,
                 notify: self(),
                 retry_delays: [],
                 store_opts: [storage: Gralkor.Reflection.Storage.InMemory]
               )

      assert_receive {:reflection_completed, "one", {:error, %{reason: %{reason: :failed}}}}
      assert_receive {:reflection_completed, "two", {:ok, _}}
    end
  end

  test "if any intended Lens ingestion fails then no Reflection is scheduled for the incomplete ingestion operation",
       context do
    parent = self()

    lens_flush = fn _operator_id, _agent_name, _user_name, lens, _turns ->
      send(parent, {:attempted_lens, lens})

      if lens == "observations" do
        {:error, :store_failed}
      else
        {:ok,
         [
           %{
             id: "representation-decisions",
             lens: lens,
             content: "stored decision",
             result: :ok
           }
         ]}
      end
    end

    start_supervised!(
      {CaptureBuffer,
       flush_callback: fn _, _, _, _, _ -> :ok end,
       lens_flush_callback: lens_flush,
       reflection_callback: fn _reflections, ingestion ->
         send(parent, {:scheduled_incomplete, ingestion})
         :ok
       end,
       reflections: [reflection(context)],
       retries: []}
    )

    :ok =
      CaptureBuffer.append_lenses(
        "session-failure",
        "operator-one",
        "Susu",
        "Eli",
        ["observations", "decisions"],
        [Message.new("user", "remember")]
      )

    assert {:error, :exhausted} = CaptureBuffer.flush_and_await("session-failure", 1_000)
    assert_receive {:attempted_lens, "observations"}
    assert_receive {:attempted_lens, "decisions"}

    refute_receive {:scheduled_incomplete, _}
  end

  describe "if a Reflection's Chain of Thought completes without a valid final structured output" do
    test "then the Reflection fails identifying its name and missing artefact", context do
      assert {:error, %{reflection: "generalisation", reason: :missing_artefact}} =
               Runner.run(one_step_reflection(context), ingestion(),
                 inference: fn _ -> {:ok, %{output: %{}}} end
               )
    end

    test "and the successful ingestion result remains unchanged", context do
      original = ingestion()

      _ =
        Runner.run(one_step_reflection(context), original,
          inference: fn _ -> {:ok, %{output: %{}}} end
        )

      assert original == ingestion()
    end
  end

  describe "if a Reflection's Chain of Thought fails" do
    test "then the Reflection failure identifies its name and reason", context do
      assert {:error, %{reflection: "generalisation", reason: :inference_failed}} =
               Runner.run(reflection(context), ingestion(),
                 inference: fn _ -> {:error, :inference_failed} end
               )
    end

    test "and the successful ingestion result remains unchanged", context do
      original = ingestion()
      _ = Runner.run(reflection(context), original, inference: fn _ -> {:error, :failed} end)
      assert original == ingestion()
    end

    test "and every other declared Reflection remains eligible to complete", context do
      runner = fn reflection, completed_ingestion, opts ->
        if reflection.name == "one",
          do: {:error, :failed},
          else:
            Runner.run(
              reflection,
              completed_ingestion,
              Keyword.put(opts, :inference, &output_for/1)
            )
      end

      assert {:ok, :scheduled} =
               Scheduler.schedule(
                 [reflection(context, "one"), reflection(context, "two")],
                 ingestion(),
                 runner: runner,
                 notify: self(),
                 store_opts: [storage: Gralkor.Reflection.Storage.InMemory]
               )

      assert_receive {:reflection_completed, "two", {:ok, _}}
    end
  end

  describe "if storing a Reflection artefact at its destination fails" do
    test "then the Reflection failure identifies its name, destination, and reason", context do
      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection(context)], ingestion(),
                 runner_opts: [inference: &output_for/1],
                 notify: self(),
                 retry_delays: [],
                 store_opts: [storage: FailingReflectionStorage]
               )

      assert_receive {:reflection_completed, "generalisation",
                      {:error,
                       %{
                         reflection: "generalisation",
                         destination: "operator",
                         reason: :destination_unavailable
                       }}}
    end

    test "and the successful ingestion result remains unchanged", context do
      original = ingestion()

      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection(context)], original,
                 runner_opts: [inference: &output_for/1],
                 store_opts: [storage: FailingReflectionStorage]
               )

      assert original == ingestion()
    end

    test "and every other declared Reflection remains eligible to complete", context do
      assert {:ok, :scheduled} =
               Scheduler.schedule(
                 [reflection(context, "one"), reflection(context, "two")],
                 ingestion(),
                 runner_opts: [inference: &output_for/1],
                 notify: self(),
                 retry_delays: [],
                 store_opts: [storage: FailingReflectionStorage]
               )

      assert_receive {:reflection_completed, "one", {:error, _}}
      assert_receive {:reflection_completed, "two", {:error, _}}
    end
  end

  describe "when a Destination is searched for artefacts" do
    test "then that Destination is searched", context do
      {reflection, artefact} = stored_artefact(context)

      assert {:ok, [%{destination: "operator", artefact: ^artefact}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "durable",
                 destinations: [reflection.destination.name],
                 result_type: :artefacts
               })
    end

    test "and relevant artefacts produced by any Reflection using that Destination are returned",
         context do
      one = reflection(context, "one")
      two = reflection(context, "two")
      {:ok, a1} = Runner.run(one, ingestion(), inference: &output_for/1)
      {:ok, a2} = Runner.run(two, ingestion(), inference: &output_for/1)
      :ok = Store.put(one, "operator-one", a1, storage: Gralkor.Reflection.Storage.InMemory)
      :ok = Store.put(two, "operator-one", a2, storage: Gralkor.Reflection.Storage.InMemory)

      assert {:ok,
              [
                %{destination: "operator", artefact: ^a1},
                %{destination: "operator", artefact: ^a2}
              ]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "",
                 destinations: [one.destination.name],
                 result_type: :artefacts
               })
    end

    test "and every result identifies its declaring Reflection", context do
      {reflection, _} = stored_artefact(context)

      assert {:ok, [%{artefact: %{reflection: "generalisation"}}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "durable",
                 destinations: [reflection.destination.name],
                 result_type: :artefacts
               })
    end

    test "and every result retains its structured payload", context do
      {reflection, _} = stored_artefact(context)

      assert {:ok, [%{artefact: %{payload: %{"artefact" => "durable pattern"}}}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "durable",
                 destinations: [reflection.destination.name],
                 result_type: :artefacts
               })
    end

    test "where the search also identifies one artefact then only that artefact is returned from the selected Destination",
         context do
      {reflection, artefact} = stored_artefact(context)
      {:ok, other} = Runner.run(reflection, ingestion(), inference: &output_for/1)

      :ok =
        Store.put(reflection, "operator-one", other, storage: Gralkor.Reflection.Storage.InMemory)

      assert {:ok, [%{destination: "operator", artefact: ^artefact}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "durable",
                 destinations: [reflection.destination.name],
                 result_type: :artefacts,
                 artefact_id: artefact.id
               })
    end
  end

  test "if memory is searched naming an unknown Destination then the search fails before any storage is searched" do
    Application.put_env(:jido_gralkor, :reflection_storage, FailingReflectionStorage)

    assert_raise ArgumentError, ~r/unknown Destination "missing"/, fn ->
      Client.search(%Search{
        operator_id: "operator-one",
        query: "query",
        destinations: ["missing"],
        result_type: :artefacts
      })
    end
  end

  defp assert_valid(%{root: root}) do
    assert {:ok,
            [
              %Gralkor.Reflection{
                name: "generalisation",
                destination: %Gralkor.Destination{name: "operator"}
              }
            ]} =
             Registry.load([valid_definition(root)], root: root)
  end

  defp reflection(
         %{root: root},
         name \\ "generalisation",
         destination \\ "operator"
       ) do
    [reflection] =
      Registry.load!([valid_definition(root, name: name, destination: destination)], root: root)

    reflection
  end

  defp one_step_reflection(%{root: root}) do
    write_cot(
      root,
      "one-step.yaml",
      "steps:\n  - label: reflect\n    directions: Reflect.\n    output: {artefact: string}\n"
    )

    [reflection] =
      Registry.load!([valid_definition(root, chain_of_thought: "one-step.yaml")], root: root)

    reflection
  end

  defp ingestion do
    %{
      id: "ingestion-1",
      operator_id: "operator-one",
      intended_lenses: ["observations", "decisions"],
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

  defp erl_payload do
    %{
      "problem_kind" => "overlapping schedules",
      "approach" => "move one job",
      "success" => true,
      "lesson" => "separate recurring jobs"
    }
  end

  defp output_for(%{step: %{label: "gather"}}), do: {:ok, %{output: %{"facts" => ["fact one"]}}}

  defp output_for(%{step: %{label: "synthesise"}}),
    do: {:ok, %{output: %{"artefact" => "durable pattern"}}}

  defp output_for(%{step: %{label: "reflect"}}),
    do: {:ok, %{output: %{"artefact" => "durable pattern"}}}

  defp erl_output_for(%{step: %{label: "inspect-reasoning"}}) do
    {:ok,
     %{
       output: %{
         "reasoning_assessment" => %{
           "problem_kind" => "overlapping schedules",
           "approach" => "move one job",
           "outcome" => "succeeded"
         }
       }
     }}
  end

  defp erl_output_for(%{step: %{label: "derive-lesson"}}) do
    {:ok,
     %{
       output: %{
         "learning_candidate" => erl_payload()
       }
     }}
  end

  defp erl_output_for(%{step: %{label: "synthesise-artefact"}}),
    do: {:ok, %{output: erl_payload()}}

  defp run_and_collect_requests(reflection, ingestion) do
    parent = self()

    inference = fn request ->
      send(parent, {:request, request})
      output_for(request)
    end

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

  defp representation_callback(parent) do
    fn _operator_id, _agent_name, _user_name, lens, _turns ->
      send(parent, {:lens_stored, lens})

      {:ok,
       [
         %{
           id: "representation-#{lens}",
           lens: lens,
           content: "stored through #{lens}",
           result: :ok
         }
       ]}
    end
  end

  defp stored_artefact(context) do
    reflection = reflection(context)
    {:ok, artefact} = Runner.run(reflection, ingestion(), inference: &output_for/1)

    :ok =
      Store.put(reflection, "operator-one", artefact,
        storage: Gralkor.Reflection.Storage.InMemory
      )

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
      [
        name: "generalisation",
        chain_of_thought: "valid.yaml",
        destination: "operator"
      ],
      overrides
    )
  end

  defp write_cot(root, name, body) do
    path = Path.join(root, name)
    File.write!(path, body)
    path
  end

  defp configure_reflections(reflections) do
    Application.put_env(:jido_gralkor, :reflections, reflections)
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
