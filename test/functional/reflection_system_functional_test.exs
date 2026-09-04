defmodule Gralkor.ReflectionSystemFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  alias Gralkor.Client
  alias Gralkor.Reflection.Registry
  alias Gralkor.Reflection.Runner
  alias Gralkor.Search

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

  defmodule ReflectionOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open
  end

  defmodule FailingReflectionStorage do
    def put_artefact(_, _, _, _), do: {:error, :destination_unavailable}
    def get_artefact(_, _, _, _), do: {:error, :not_found}
  end

  defmodule OutputProbeStorage do
    @behaviour Gralkor.Destination.Storage

    @impl true
    def search(_, _, _, _, _, _), do: {:ok, []}

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

  defmodule NonRetryableOutputStorage do
    @behaviour Gralkor.Destination.Storage

    @impl true
    def search(_, _, _, _, _, _), do: {:ok, []}

    @impl true
    def put_artefact(_, _, _, artefact) do
      send(
        Application.fetch_env!(:jido_gralkor, :reflection_output_test_pid),
        {:non_retryable_destination_attempt, artefact}
      )

      {:error, %{status: 422, reason: :invalid_output}}
    end

    @impl true
    def get_artefact(_, _, _, _), do: {:error, :not_found}
  end

  defmodule RetryableOutputStorage do
    @behaviour Gralkor.Destination.Storage

    @impl true
    def search(_, _, _, _, _, _), do: {:ok, []}

    @impl true
    def put_artefact(_, _, _, artefact) do
      counter = Application.fetch_env!(:jido_gralkor, :reflection_retry_counter)
      :counters.add(counter, 1, 1)
      attempt = :counters.get(counter, 1)

      send(
        Application.fetch_env!(:jido_gralkor, :reflection_output_test_pid),
        {:retryable_destination_attempt, attempt, artefact}
      )

      if attempt < 4, do: {:error, %{status: 503}}, else: :ok
    end

    @impl true
    def get_artefact(_, _, _, _), do: {:error, :not_found}
  end

  defmodule AlwaysRetryableOutputStorage do
    @behaviour Gralkor.Destination.Storage

    @impl true
    def search(_, _, _, _, _, _), do: {:ok, []}

    @impl true
    def put_artefact(_, _, _, artefact) do
      send(
        Application.fetch_env!(:jido_gralkor, :reflection_output_test_pid),
        {:retryable_destination_attempt, artefact}
      )

      {:error, %{status: 503, reason: :temporarily_unavailable}}
    end

    @impl true
    def get_artefact(_, _, _, _), do: {:error, :not_found}
  end

  defmodule OutputProbeReturnHandler do
    @behaviour Gralkor.Artefact.ReturnHandler

    @impl true
    def return(operator_id, invocation_id, artefact) do
      send(
        Application.fetch_env!(:jido_gralkor, :reflection_output_test_pid),
        {:return_output_delivered, operator_id, invocation_id, artefact}
      )

      :ok
    end
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "gralkor-reflection-#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
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
            :reflection_output_test_pid,
            :reflection_retry_counter
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

    test "and every Reflection declares an `outputs` list", %{root: root} do
      definition =
        valid_definition(root,
          outputs: [
            [
              kind: :destination,
              destination: "operator",
              ontology: ReflectionOntology
            ]
          ]
        )

      assert {:ok, [reflection]} = Registry.load([definition], root: root)

      assert reflection.outputs == [
               %{
                 kind: :destination,
                 destination: %Gralkor.Destination{name: "operator"},
                 ontology: ReflectionOntology
               }
             ]
    end

    test("and exactly one output has kind `:destination`", context, do: assert_valid(context))

    test("and at most one output has kind `:return`", context, do: assert_valid(context))

    test("and every Destination output references a registered Destination by name", context,
      do: assert_valid(context)
    )

    test("and every Destination output declares a valid extraction ontology", context,
      do: assert_valid(context)
    )

    test(
      "and every return output names a loaded handler implementing `Gralkor.Artefact.ReturnHandler`",
      context,
      do: assert_valid(context)
    )

    test("then validation succeeds", context, do: assert_valid(context))
  end

  describe "when Reflection declarations are validated > if the configured Reflection registry is not a list" do
    test "then validation fails identifying the configured value" do
      Application.put_env(:jido_gralkor, :reflections, :invalid_registry)

      assert_raise ArgumentError, ~r/invalid Reflection declarations: :invalid_registry/, fn ->
        Registry.configured!()
      end
    end
  end

  describe "when Reflection declarations are validated > if a Reflection's `outputs` value is not a list" do
    test "then validation fails identifying that Reflection and outputs value",
         %{root: root} do
      definition = valid_definition(root, outputs: :invalid)

      assert {:error, {:invalid_outputs, "generalisation", :invalid}} =
               Registry.load([definition], root: root)
    end
  end

  describe "when Reflection declarations are validated > if a Reflection declares no Destination output" do
    test "then validation fails identifying that Reflection and missing Destination output",
         %{root: root} do
      definition = valid_definition(root, outputs: [])

      assert {:error, {:missing_destination_output, "generalisation"}} =
               Registry.load([definition], root: root)
    end
  end

  describe "when Reflection declarations are validated > if a Reflection declares more than one Destination output" do
    test "then validation fails identifying that Reflection and duplicate Destination output kind",
         %{root: root} do
      output = [kind: :destination, destination: "operator"]
      definition = valid_definition(root, outputs: [output, output])

      assert {:error, {:duplicate_output, "generalisation", :destination}} =
               Registry.load([definition], root: root)
    end
  end

  describe "when Reflection declarations are validated > if a Reflection declares more than one return output" do
    test "then validation fails identifying that Reflection and duplicate return output kind",
         %{root: root} do
      outputs = [
        [kind: :destination, destination: "operator"],
        [kind: :return, handler: __MODULE__],
        [kind: :return, handler: __MODULE__]
      ]

      assert {:error, {:duplicate_output, "generalisation", :return}} =
               Registry.load([valid_definition(root, outputs: outputs)], root: root)
    end
  end

  describe "when Reflection declarations are validated > if a Reflection declares an unsupported output kind" do
    test "then validation fails identifying that Reflection and output kind",
         %{root: root} do
      outputs = [
        [kind: :destination, destination: "operator"],
        [kind: :webhook]
      ]

      assert {:error, {:unsupported_output, "generalisation", :webhook}} =
               Registry.load([valid_definition(root, outputs: outputs)], root: root)
    end
  end

  describe "when Reflection declarations are validated > if a return output has no loaded handler implementing `Gralkor.Artefact.ReturnHandler`" do
    test "then validation fails identifying that Reflection and handler",
         %{root: root} do
      outputs = [
        [kind: :destination, destination: "operator"],
        [kind: :return, handler: String]
      ]

      assert {:error, {:invalid_return_handler, "generalisation", String}} =
               Registry.load([valid_definition(root, outputs: outputs)], root: root)
    end
  end

  describe "when Reflection declarations are validated > if a Reflection name is blank" do
    test "then validation fails identifying the blank name", %{
      root: root
    } do
      assert {:error, {:blank_name, " "}} =
               Registry.load([valid_definition(root, name: " ")], root: root)

      Application.put_env(:jido_gralkor, :reflections, [
        %Gralkor.Reflection{
          name: " ",
          outputs: [
            %{
              kind: :destination,
              destination: %Gralkor.Destination{name: "global"},
              ontology: Gralkor.DefaultOntology
            }
          ],
          chain_of_thought: %Gralkor.Reflection.ChainOfThought{path: "loaded.yaml", steps: []}
        }
      ])

      assert_raise ArgumentError, ~r/blank_name.*" "/, fn -> Registry.configured!() end
    end
  end

  describe "when Reflection declarations are validated > if a Reflection name contains the reserved provenance delimiter ` [lens: `" do
    test "then validation fails identifying the Reflection and reserved provenance syntax",
         %{root: root} do
      name = "review [lens: observations]"

      assert {:error, {:reserved_provenance_syntax, ^name, " [lens: "}} =
               Registry.load([valid_definition(root, name: name)], root: root)
    end
  end

  describe "when Reflection declarations are validated > if Reflection names are duplicated" do
    test "then validation fails identifying the duplicate name",
         %{root: root} do
      definition = valid_definition(root)

      assert {:error, {:duplicate_name, "generalisation"}} =
               Registry.load([definition, definition], root: root)
    end
  end

  describe "when Reflection declarations are validated > if a Reflection has no Chain of Thought" do
    test "then validation fails identifying that Reflection",
         %{root: root} do
      definition = valid_definition(root) |> Keyword.delete(:chain_of_thought)

      assert {:error, {:missing_chain_of_thought, "generalisation"}} =
               Registry.load([definition], root: root)
    end
  end

  describe "when Reflection declarations are validated > if a Reflection's Chain of Thought does not identify a repository YAML file" do
    test "then validation fails identifying that Reflection and file",
         %{root: root} do
      assert {:error, {:invalid_chain_of_thought_file, "generalisation", "../outside.yaml"}} =
               Registry.load([valid_definition(root, chain_of_thought: "../outside.yaml")],
                 root: root
               )
    end
  end

  describe "when Reflection declarations are validated > if a Reflection's Chain of Thought YAML cannot be loaded or parsed" do
    test "then validation fails identifying that Reflection, file, and parse failure",
         %{root: root} do
      write_cot(root, "broken.yaml", "steps: [")

      assert {:error, {:invalid_chain_of_thought, "generalisation", "broken.yaml", _}} =
               Registry.load([valid_definition(root, chain_of_thought: "broken.yaml")],
                 root: root
               )
    end
  end

  describe "when Reflection declarations are validated > if a Chain of Thought has no steps" do
    test "then validation fails identifying that Reflection and Chain of Thought",
         %{root: root} do
      write_cot(root, "empty.yaml", "steps: []")

      assert {:error, {:invalid_chain_of_thought, "generalisation", "empty.yaml", :missing_steps}} =
               Registry.load([valid_definition(root, chain_of_thought: "empty.yaml")], root: root)
    end
  end

  describe "when Reflection declarations are validated > if a Chain of Thought step has no non-blank label" do
    test "then validation fails identifying that Reflection and step",
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
  end

  describe "when Reflection declarations are validated > if a Chain of Thought step has no natural-language directions" do
    test "then validation fails identifying that Reflection and step",
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
  end

  describe "when Reflection declarations are validated > if a Chain of Thought step has no structured-output declaration" do
    test "then validation fails identifying that Reflection and step",
         %{root: root} do
      write_cot(root, "no-output.yaml", "steps:\n  - label: think\n    directions: Think.\n")

      assert {:error,
              {:invalid_chain_of_thought, "generalisation", "no-output.yaml",
               {:invalid_step_output, "think"}}} =
               Registry.load([valid_definition(root, chain_of_thought: "no-output.yaml")],
                 root: root
               )
    end
  end

  describe "when Reflection declarations are validated > if a Chain of Thought step is not a map" do
    test "then validation fails identifying that Reflection and step",
         %{root: root} do
      write_cot(root, "invalid-step.yaml", "steps:\n  - not-a-step\n")

      assert {:error,
              {:invalid_chain_of_thought, "generalisation", "invalid-step.yaml",
               {:invalid_step, "not-a-step"}}} =
               Registry.load([valid_definition(root, chain_of_thought: "invalid-step.yaml")],
                 root: root
               )
    end
  end

  describe "when Reflection declarations are validated > if a Chain of Thought step declares an unsupported structured-output type" do
    test "then validation fails identifying that Reflection, step, and type",
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
  end

  describe "when Reflection declarations are validated > if an output name is declared by more than one step" do
    test "then validation fails identifying that Reflection, output name, and steps",
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
  end

  describe "when Reflection declarations are validated > if an interpolation references an output not declared by an earlier step" do
    test "then validation fails identifying that Reflection, step, and interpolation",
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
  end

  describe "when Reflection declarations are validated > if a Destination output has no Destination name" do
    test "then validation fails identifying that Reflection and missing Destination",
         %{root: root} do
      definition = valid_definition(root, outputs: [[kind: :destination]])

      assert {:error, {:missing_destination, "generalisation", nil}} =
               Registry.load([definition], root: root)
    end
  end

  describe "when Reflection declarations are validated > if a Destination output references an unknown Destination" do
    test "then validation fails identifying that Reflection and Destination",
         %{root: root} do
      assert_raise ArgumentError,
                   ~r/Reflection "generalisation" references unknown Destination "missing"/,
                   fn ->
                     Registry.load(
                       [
                         valid_definition(root,
                           outputs: [[kind: :destination, destination: "missing"]]
                         )
                       ],
                       root: root
                     )
                   end
    end
  end

  describe "when Reflection declarations are validated > if a Destination output declares an invalid ontology" do
    test "then validation fails identifying that Reflection and ontology",
         %{root: root} do
      assert {:error, {:invalid_ontology, "generalisation", String}} =
               Registry.load(
                 [
                   valid_definition(root,
                     outputs: [
                       [kind: :destination, destination: "operator", ontology: String]
                     ]
                   )
                 ],
                 root: root
               )
    end
  end

  describe "where the packaged default Reflections are used" do
    test "then ERL declares one Destination output referencing the packaged `operator` Destination" do
      Application.delete_env(:jido_gralkor, :reflections)

      erl = Enum.find(Registry.configured!(), &(&1.name == "erl"))

      assert [%{kind: :destination, destination: %Gralkor.Destination{name: "operator"}}] =
               erl.outputs
    end

    test "and ERL's Destination output carries jido_gralkor's built-in experiential-learning ontology" do
      Application.delete_env(:jido_gralkor, :reflections)
      erl = Enum.find(Registry.configured!(), &(&1.name == "erl"))

      assert destination_output(erl).ontology == Gralkor.Reflection.ERLOntology
    end

    test "and generalisation declares one Destination output referencing the packaged `global` Destination" do
      Application.delete_env(:jido_gralkor, :reflections)
      generalisation = Enum.find(Registry.configured!(), &(&1.name == "generalisations"))

      assert destination_output(generalisation).destination.name == "global"
    end

    test "and neither packaged Reflection declares a return output" do
      Application.delete_env(:jido_gralkor, :reflections)

      assert Enum.all?(Registry.configured!(), fn reflection ->
               Enum.all?(reflection.outputs, &(&1.kind != :return))
             end)
    end
  end

  describe "where an application-defined Destination output omits its ontology" do
    test "then the output selects generic extraction for a consumer-delivered artefact",
         %{root: root} do
      reflection = Registry.load!([valid_definition(root)], root: root) |> List.first()
      assert destination_output(reflection).ontology == Gralkor.DefaultOntology
    end
  end

  describe "where an application-defined Destination output declares an application ontology" do
    test "then the output selects that ontology for a consumer-delivered artefact", %{root: root} do
      reflection =
        Registry.load!(
          [
            valid_definition(root,
              outputs: [
                [
                  kind: :destination,
                  destination: "observations",
                  ontology: ReflectionOntology
                ]
              ]
            )
          ],
          root: root
        )
        |> List.first()

      assert destination_output(reflection).ontology == ReflectionOntology
    end
  end

  describe "when a consumer stores the default ERL Reflection's artefact through its Destination output" do
    test "then extraction receives the built-in `Learning` entity type from that output's ontology" do
      Application.delete_env(:jido_gralkor, :reflections)
      erl = Enum.find(Registry.configured!(), &(&1.name == "erl"))
      artefact = Gralkor.Artefact.new("erl-artefact", erl_payload())
      caller = self()

      add_episode = fn group_id, content, source, ontology, opts ->
        send(caller, {:reflection_episode, group_id, content, source, ontology, opts})
        :ok
      end

      assert :ok =
               Gralkor.Destination.Storage.Graphiti.put_artefact(
                 destination_output(erl),
                 erl.name,
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

    test "and the Runner-returned Learning payload contains exactly its problem kind, approach, success, and reusable lesson" do
      Application.delete_env(:jido_gralkor, :reflections)
      erl = Enum.find(Registry.configured!(), &(&1.name == "erl"))

      assert {:ok, artefact} = Runner.run(erl, invocation(), inference: &erl_output_for/1)
      assert artefact.payload == erl_payload()
    end
  end

  describe "when a configured Reflection is loaded" do
    test "then its declared YAML is loaded as the Reflection's Chain of Thought", context do
      assert %Gralkor.Reflection.ChainOfThought{path: path} = reflection(context).chain_of_thought
      assert String.ends_with?(path, ".yaml")
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
      assert [first | _] = run_and_collect_requests(reflection(context), invocation())
      assert first.step == %{label: "gather", directions: "Gather facts."}
      refute Map.has_key?(first, :steps)
    end
  end

  describe "when a Chain of Thought step begins > where the directions reference outputs from earlier steps" do
    test "then every referenced value is interpolated from the Chain of Thought's shared output space",
         context do
      assert [_first, second] = run_and_collect_requests(reflection(context), invocation())
      assert second.directions =~ "fact one"
      refute second.directions =~ "{{facts}}"
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

  describe "when inference returns a structured output for the current step > if a declared output key is missing" do
    test "then the Reflection fails identifying its name, current step, and missing key",
         context do
      assert {:error,
              %{reflection: "generalisation", step: "gather", reason: {:missing_output, "facts"}}} =
               Runner.run(reflection(context), invocation(),
                 inference: fn _ -> {:ok, %{output: %{}}} end
               )
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

    test "and the Runner does not deliver any declared Destination or return output", context do
      reflection = reflection(context)

      reflection = %{
        reflection
        | outputs: reflection.outputs ++ [%{kind: :return, handler: OutputProbeReturnHandler}]
      }

      Application.put_env(:jido_gralkor, :destination_storage, OutputProbeStorage)

      assert {:ok, %Gralkor.Artefact{}} =
               Runner.run(reflection, invocation(), inference: &output_for/1)

      refute_receive {:destination_output_delivered, _, _, _, _}
      refute_receive {:return_output_delivered, _, _, _}
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

  describe "when an admitted Reflection completes successfully" do
    test "then its artefact is delivered and the invocation callback eventually receives that success" do
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

  describe "when runtime configuration is replaced after a Reflection is admitted" do
    test "then admitted work retains its Reflection and later submissions use the replacement" do
      Application.put_env(:jido_gralkor, :destination_storage, OutputProbeStorage)

      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: AsyncConsumerAgent, id: "reflection-admission-snapshot", register_global: false}
        )

      assert :ok =
               JidoGralkor.Runtime.replace(
                 agent_server,
                 async_reflection_configuration("first-reviews")
               )

      test_pid = self()
      release = make_ref()

      blocked_inference = fn _request ->
        send(test_pid, {:snapshot_reflection_started, self()})

        receive do
          {^release, :continue} -> {:ok, %{output: %{"summary" => "first"}}}
        end
      end

      callback = fn result -> send(test_pid, {:reflection_callback, result}) end

      assert {:ok, "first-submission"} =
               Client.reflect(
                 agent_server,
                 "review",
                 async_reflection_invocation("first-submission"),
                 callback,
                 inference: blocked_inference
               )

      assert_receive {:snapshot_reflection_started, blocked_process}

      assert :ok =
               JidoGralkor.Runtime.replace(
                 agent_server,
                 async_reflection_configuration("second-reviews")
               )

      send(blocked_process, {release, :continue})

      assert_receive {:destination_output_delivered, first_output, "review", _, first_artefact}
      assert first_output.destination.name == "first-reviews"

      assert_receive {:reflection_callback,
                      %{invocation_id: "first-submission", artefact: ^first_artefact}}

      assert {:ok, "second-submission"} =
               Client.reflect(
                 agent_server,
                 "review",
                 async_reflection_invocation("second-submission"),
                 callback,
                 inference: fn _ -> {:ok, %{output: %{"summary" => "second"}}} end
               )

      assert_receive {:destination_output_delivered, second_output, "review", _, second_artefact}
      assert second_output.destination.name == "second-reviews"

      assert_receive {:reflection_callback,
                      %{invocation_id: "second-submission", artefact: ^second_artefact}}
    end
  end

  describe "when the consuming agent terminates with unfinished Reflection work" do
    test "then that unfinished work terminates with the agent and delivers no callback" do
      previous_trap_exit = Process.flag(:trap_exit, true)
      on_exit(fn -> Process.flag(:trap_exit, previous_trap_exit) end)

      {:ok, agent_server} =
        Jido.AgentServer.start_link(
          agent: AsyncConsumerAgent,
          id: "reflection-work-owned-by-agent",
          register_global: false
        )

      assert :ok =
               JidoGralkor.Runtime.replace(agent_server, async_reflection_configuration())

      test_pid = self()

      inference = fn _request ->
        send(test_pid, {:unfinished_reflection_started, self()})

        receive do
          :never_sent -> {:ok, %{output: %{"summary" => "impossible"}}}
        end
      end

      callback = fn result -> send(test_pid, {:reflection_callback, result}) end

      assert {:ok, "reflection-invocation-one"} =
               Client.reflect(
                 agent_server,
                 "review",
                 async_reflection_invocation(),
                 callback,
                 inference: inference
               )

      assert_receive {:unfinished_reflection_started, reflection_process}
      monitor = Process.monitor(reflection_process)

      Process.exit(agent_server, :shutdown)

      assert_receive {:DOWN, ^monitor, :process, ^reflection_process, _reason}
      refute_receive {:reflection_callback, _}
    end
  end

  describe "if Reflection production fails" do
    test "then no Destination output is attempted and the callback eventually receives the failure" do
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
  end

  describe "if a produced artefact cannot be delivered before delivery is abandoned" do
    test "then the callback eventually receives the artefact and non-retryable abandonment outcome" do
      Application.put_env(:jido_gralkor, :destination_storage, NonRetryableOutputStorage)

      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: AsyncConsumerAgent,
           id: "reflection-async-delivery-abandonment",
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
                 inference: fn _ -> {:ok, %{output: %{"summary" => "complete"}}} end
               )

      assert_receive {:non_retryable_destination_attempt, artefact}

      assert_receive {:reflection_callback,
                      %{
                        invocation_id: "reflection-invocation-one",
                        artefact: ^artefact,
                        outcome:
                          {:abandoned,
                           %{
                             stage: :delivery,
                             reason: %{status: 422, reason: :invalid_output}
                           }}
                      }}

      refute_receive {:non_retryable_destination_attempt, _}
    end
  end

  describe "when Reflection Destination delivery reports a retryable server failure" do
    test "then delivery retries with exponential backoff and eventually reports success" do
      Application.put_env(:jido_gralkor, :destination_storage, RetryableOutputStorage)
      Application.put_env(:jido_gralkor, :reflection_retry_counter, :counters.new(1, []))

      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: AsyncConsumerAgent,
           id: "reflection-async-delivery-retry",
           register_global: false}
        )

      assert :ok =
               JidoGralkor.Runtime.replace(agent_server, async_reflection_configuration())

      test_pid = self()
      callback = fn result -> send(test_pid, {:reflection_callback, result}) end
      sleep = fn delay -> send(test_pid, {:reflection_retry_backoff, delay}) end

      assert {:ok, "reflection-invocation-one"} =
               Client.reflect(
                 agent_server,
                 "review",
                 async_reflection_invocation(),
                 callback,
                 inference: fn _ -> {:ok, %{output: %{"summary" => "complete"}}} end,
                 sleep: sleep
               )

      assert_receive {:retryable_destination_attempt, 1, artefact}
      assert_receive {:reflection_retry_backoff, 1_000}
      assert_receive {:retryable_destination_attempt, 2, ^artefact}
      assert_receive {:reflection_retry_backoff, 2_000}
      assert_receive {:retryable_destination_attempt, 3, ^artefact}
      assert_receive {:reflection_retry_backoff, 4_000}
      assert_receive {:retryable_destination_attempt, 4, ^artefact}

      assert_receive {:reflection_callback,
                      %{
                        invocation_id: "reflection-invocation-one",
                        artefact: ^artefact,
                        outcome: :delivered
                      }}
    end
  end

  describe "when a retryable Reflection failure reaches twenty-four hours" do
    test "then the invocation is abandoned without another retry and its callback receives that outcome" do
      Application.put_env(:jido_gralkor, :destination_storage, AlwaysRetryableOutputStorage)

      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: AsyncConsumerAgent, id: "reflection-retry-deadline", register_global: false}
        )

      assert :ok =
               JidoGralkor.Runtime.replace(agent_server, async_reflection_configuration())

      test_pid = self()
      clock_calls = :counters.new(1, [])

      clock = fn ->
        :counters.add(clock_calls, 1, 1)

        case :counters.get(clock_calls, 1) do
          call when call <= 2 -> 0
          _ -> 86_400_000
        end
      end

      callback = fn result -> send(test_pid, {:reflection_callback, result}) end

      assert {:ok, "reflection-invocation-one"} =
               Client.reflect(
                 agent_server,
                 "review",
                 async_reflection_invocation(),
                 callback,
                 inference: fn _ -> {:ok, %{output: %{"summary" => "complete"}}} end,
                 clock: clock,
                 sleep: fn delay -> send(test_pid, {:unexpected_retry_sleep, delay}) end
               )

      assert_receive {:retryable_destination_attempt, artefact}

      assert_receive {:reflection_callback,
                      %{
                        artefact: ^artefact,
                        outcome:
                          {:abandoned,
                           %{
                             stage: :delivery,
                             reason: %{status: 503, reason: :temporarily_unavailable}
                           }}
                      }}

      refute_receive {:unexpected_retry_sleep, _}
      refute_receive {:retryable_destination_attempt, _}
    end
  end

  describe "when Reflection production reports a retryable server failure" do
    test "then production retries with exponential backoff before output delivery" do
      Application.put_env(:jido_gralkor, :destination_storage, OutputProbeStorage)

      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: AsyncConsumerAgent,
           id: "reflection-async-production-retry",
           register_global: false}
        )

      assert :ok =
               JidoGralkor.Runtime.replace(agent_server, async_reflection_configuration())

      test_pid = self()
      counter = :counters.new(1, [])

      inference = fn _ ->
        :counters.add(counter, 1, 1)
        attempt = :counters.get(counter, 1)
        send(test_pid, {:retryable_production_attempt, attempt})

        if attempt < 3,
          do: {:error, %{status: 503}},
          else: {:ok, %{output: %{"summary" => "complete"}}}
      end

      callback = fn result -> send(test_pid, {:reflection_callback, result}) end
      sleep = fn delay -> send(test_pid, {:reflection_retry_backoff, delay}) end

      assert {:ok, "reflection-invocation-one"} =
               Client.reflect(
                 agent_server,
                 "review",
                 async_reflection_invocation(),
                 callback,
                 inference: inference,
                 sleep: sleep
               )

      assert_receive {:retryable_production_attempt, 1}
      assert_receive {:reflection_retry_backoff, 1_000}
      assert_receive {:retryable_production_attempt, 2}
      assert_receive {:reflection_retry_backoff, 2_000}
      assert_receive {:retryable_production_attempt, 3}
      assert_receive {:destination_output_delivered, _, "review", "operator-one", artefact}
      assert_receive {:reflection_callback, %{artefact: ^artefact, outcome: :delivered}}
    end
  end

  describe "if a Reflection's Chain of Thought completes without a valid final structured output" do
    test "then the Reflection fails identifying its name and missing artefact", context do
      assert {:error, %{reflection: "generalisation", reason: :missing_artefact}} =
               Runner.run(one_step_reflection(context), invocation(),
                 inference: fn _ -> {:ok, %{output: %{}}} end
               )
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

  describe "when a Destination is searched for artefacts" do
    test "then that Destination is searched", context do
      {reflection, artefact} = stored_artefact(context)

      assert {:ok, [%{destination: "operator", artefact: ^artefact}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "durable",
                 destinations: [destination_output(reflection).destination.name],
                 result_type: :artefacts
               })
    end

    test "and relevant artefacts written through any Destination output using that Destination are returned",
         context do
      one = reflection(context, "one")
      two = reflection(context, "two")
      {:ok, a1} = Runner.run(one, invocation(), inference: &output_for/1)
      {:ok, a2} = Runner.run(two, invocation(), inference: &output_for/1)
      :ok = put_artefact(one, "operator-one", a1, storage: Gralkor.Destination.Storage.InMemory)
      :ok = put_artefact(two, "operator-one", a2, storage: Gralkor.Destination.Storage.InMemory)

      assert {:ok,
              [
                %{destination: "operator", artefact: ^a1},
                %{destination: "operator", artefact: ^a2}
              ]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "",
                 destinations: [destination_output(one).destination.name],
                 result_type: :artefacts
               })
    end

    test "and every artefact contains exactly its stable identifier and structured payload",
         context do
      {reflection, _} = stored_artefact(context)

      assert {:ok, [%{artefact: artefact}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "durable",
                 destinations: [destination_output(reflection).destination.name],
                 result_type: :artefacts
               })

      assert Map.from_struct(artefact) == %{
               id: artefact.id,
               payload: %{"artefact" => "durable pattern"}
             }
    end
  end

  describe "when a Destination is searched for artefacts > where the search also identifies one artefact" do
    test "then only that artefact is returned from the selected Destination",
         context do
      {reflection, artefact} = stored_artefact(context)
      {:ok, other} = Runner.run(reflection, invocation(), inference: &output_for/1)

      :ok =
        put_artefact(reflection, "operator-one", other,
          storage: Gralkor.Destination.Storage.InMemory
        )

      assert {:ok, [%{destination: "operator", artefact: ^artefact}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "durable",
                 destinations: [destination_output(reflection).destination.name],
                 result_type: :artefacts,
                 artefact_id: artefact.id
               })
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

  defp assert_valid(%{root: root}) do
    assert {:ok,
            [
              %Gralkor.Reflection{
                name: "generalisation",
                outputs: [
                  %{kind: :destination, destination: %Gralkor.Destination{name: "operator"}}
                ]
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
      Registry.load!(
        [
          valid_definition(root,
            name: name,
            outputs: [[kind: :destination, destination: destination]]
          )
        ],
        root: root
      )

    reflection
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

  defp valid_definition(root, overrides \\ []) do
    unless File.exists?(Path.join(root, "valid.yaml")) do
      write_cot(root, "valid.yaml", """
      steps:
        - label: gather
          directions: Gather facts.
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
        outputs: [[kind: :destination, destination: "operator"]]
      ],
      overrides
    )
  end

  defp write_cot(root, name, body) do
    path = Path.join(root, name)
    File.write!(path, body)
    path
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
