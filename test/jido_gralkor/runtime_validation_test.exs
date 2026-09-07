defmodule JidoGralkor.RuntimeValidationTest do
  use ExUnit.Case, async: true
  alias JidoGralkor.Runtime

  defmodule EntityOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open

    entity Entity do
      field(:value, :string)
    end
  end

  defmodule EpisodicOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open

    entity Episodic do
      field(:value, :string)
    end
  end

  defmodule CommunityOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open

    entity Community do
      field(:value, :string)
    end
  end

  defmodule PersonOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open

    entity Person do
      field(:value, :string)
    end
  end

  describe "if runtime configuration is not a map" do
    test "then validation identifies the configured value" do
      assert {:error, {:invalid_configuration, :not_a_map}} = validate(:not_a_map)
    end
  end

  describe "if a Destination, Lens, or Reflection name is missing, blank, or duplicated" do
    test "then validation identifies the collection and invalid name" do
      for collection <- [:destinations, :lenses, :reflections], value <- [nil, false, "", "  "] do
        assert {:error, {:blank_definition_name, ^collection, ^value}} =
                 validate(named(collection, value))
      end

      for collection <- [:destinations, :lenses, :reflections] do
        assert {:error, {:duplicate_definition_name, ^collection, "same"}} =
                 validate(named(collection, "same", true))
      end
    end
  end

  describe "if runtime configuration contains an unknown top-level field" do
    test "then validation identifies every unknown field" do
      assert {:error, {:unknown_configuration_fields, [:extra, :other]}} =
               validate(Map.merge(config(), %{extra: 1, other: 2}))
    end
  end

  describe "if a required Destination, Lens, or Reflection collection is absent" do
    test "then validation identifies the missing collection" do
      for collection <- [:destinations, :lenses, :reflections] do
        assert {:error, {:missing_collection, ^collection}} =
                 validate(Map.delete(config(), collection))
      end
    end
  end

  describe "if a Destination, Lens, or Reflection collection is not a list" do
    test "then validation identifies the collection and configured value" do
      for collection <- [:destinations, :lenses, :reflections] do
        assert {:error, {:invalid_collection, ^collection, :bad}} =
                 validate(Map.put(config(), collection, :bad))
      end
    end
  end

  describe "if a definition is neither a map nor a keyword list" do
    test "then validation identifies its collection and configured value" do
      assert {:error, {:invalid_definition, :destinations, :bad}} =
               validate(Map.put(config(), :destinations, [:bad]))
    end
  end

  describe "if a definition contains unknown fields" do
    test "then validation identifies its collection, name, and unknown fields" do
      for {collection, name} <- [destinations: "memory", lenses: "notes", reflections: "review"] do
        c = update_in(config(), [collection, Access.at(0)], &Keyword.put(&1, :extra, true))

        assert {:error, {:unknown_definition_fields, ^collection, ^name, [:extra]}} =
                 validate(c)
      end
    end
  end

  describe "if a consumer definition uses a name reserved by a package-owned definition" do
    test "then validation identifies its collection and reserved name" do
      assert {:error, {:reserved_definition_name, :destinations, "operator"}} =
               validate(Map.put(config(), :destinations, [[name: "operator"]]))
    end
  end

  describe "if a Destination name uses the reserved `operator/` namespace or a Lens uses the retired `default` name" do
    test "then validation identifies the reserved or retired name" do
      assert {:error, {:reserved_destination_namespace, "operator/custom"}} =
               validate(Map.put(config(), :destinations, [[name: "operator/custom"]]))

      lens = [
        [
          name: "default",
          destination: "memory",
          write: :append,
          ingestion: Gralkor.Lens.Ingestion.Store,
          ontology: Gralkor.DefaultOntology
        ]
      ]

      assert {:error, {:retired_definition_name, :lenses, "default", "operator"}} =
               validate(Map.put(config(), :lenses, lens))
    end
  end

  describe "if a Lens or Reflection name contains the reserved provenance delimiter ` [lens: `" do
    test "then validation identifies the collection and name" do
      lens = [
        [
          name: "notes [lens: old",
          destination: "memory",
          write: :append,
          ingestion: Gralkor.Lens.Ingestion.Store,
          ontology: Gralkor.DefaultOntology
        ]
      ]

      assert {:error, {:reserved_provenance_syntax, :lenses, "notes [lens: old"}} =
               validate(Map.put(config(), :lenses, lens))
    end
  end

  describe "if a Lens or Reflection references an unknown Destination" do
    test "then validation identifies the definition and Destination" do
      c = update_in(config(), [:lenses, Access.at(0)], &Keyword.put(&1, :destination, "missing"))
      assert {:error, {:unknown_destination, :lenses, "notes", "missing"}} = validate(c)

      c = update_in(config(), [:reflections, Access.at(0)], fn reflection ->
        Keyword.put(reflection, :outputs, [kind: :destination, destination: "missing", ontology: Gralkor.DefaultOntology])
      end)

      assert {:error, {:unknown_destination, :reflections, "review", "missing"}} = validate(c)
    end
  end

  describe "when an appending Lens declares `write: :append`, a Destination, and a valid ingestion module" do
    test "then it resolves as an appending Lens" do
      {:ok, pid} = Runtime.start_link(owner: self(), configuration: config())
      on_exit(fn -> GenServer.stop(pid) end)
      assert %Gralkor.Lens{name: "notes"} = Runtime.lens!(self(), "notes")
    end

    test "and an omitted ontology resolves to `Gralkor.DefaultOntology`" do
      c = update_in(config(), [:lenses, Access.at(0)], &Keyword.delete(&1, :ontology))
      {:ok, pid} = Runtime.start_link(owner: self(), configuration: c)
      on_exit(fn -> GenServer.stop(pid) end)
      assert %Gralkor.Lens{ontology: Gralkor.DefaultOntology} = Runtime.lens!(self(), "notes")
    end
  end

  describe "if an appending Lens has a missing or invalid ingestion module or an invalid ontology" do
    test "then validation identifies the Lens and invalid field" do
      c = update_in(config(), [:lenses, Access.at(0)], &Keyword.put(&1, :ingestion, String))
      assert {:error, {:invalid_lens_ingestion, "notes", String}} = validate(c)
      c = update_in(config(), [:lenses, Access.at(0)], &Keyword.put(&1, :ontology, String))
      assert {:error, {:invalid_lens_ontology, "notes", String}} = validate(c)
    end
  end

  describe "if a map supplies an atom-keyed ontology value and a string-keyed ontology value" do
    test "then the atom-keyed value remains authoritative even when it is false" do
      c =
        Map.put(config(), :lenses, [
          %{
            "ontology" => Gralkor.DefaultOntology,
            name: "notes",
            destination: "memory",
            write: :append,
            ingestion: Gralkor.Lens.Ingestion.Store,
            ontology: false
          }
        ])

      assert {:error, {:invalid_lens_ontology, "notes", false}} = validate(c)
    end
  end

  describe "when a replaceable Lens declares `write: :replace_graph` and a Destination" do
    test "then it resolves as a replaceable Lens" do
      lens = [[name: "notes", destination: "memory", write: :replace_graph]]

      {:ok, pid} =
        Runtime.start_link(owner: self(), configuration: Map.put(config(), :lenses, lens))

      on_exit(fn -> GenServer.stop(pid) end)
      assert %Gralkor.Lens.Replaceable{name: "notes"} = Runtime.lens!(self(), "notes")
    end
  end

  describe "if a replaceable Lens also declares ingestion or ontology fields" do
    test "then validation identifies the incompatible Lens definition" do
      lens = [
        [
          name: "notes",
          destination: "memory",
          write: :replace_graph,
          ontology: Gralkor.DefaultOntology
        ]
      ]

      assert {:error, {:incompatible_lens_definition, "notes"}} =
               validate(Map.put(config(), :lenses, lens))
    end
  end

  describe "if a Lens declares any other write mode" do
    test "then validation identifies the Lens and write value" do
      c = update_in(config(), [:lenses, Access.at(0)], &Keyword.put(&1, :write, :other))
      assert {:error, {:invalid_lens_write, "notes", :other}} = validate(c)
    end
  end

  describe "if a Reflection's outputs value is not a list or contains a malformed output" do
    test "then validation identifies the Reflection and invalid output" do
      c = update_in(config(), [:reflections, Access.at(0)], &Keyword.put(&1, :outputs, :bad))
      assert {:error, {:invalid_reflection_outputs, "review", :bad}} = validate(c)
      c = update_in(config(), [:reflections, Access.at(0)], &Keyword.put(&1, :outputs, [:bad]))
      assert {:error, {:invalid_reflection_output, "review"}} = validate(c)
    end
  end

  describe "if a Reflection declares no Destination output or more than one Destination output" do
    test "then validation identifies the Reflection and output count failure" do
      c = update_in(config(), [:reflections, Access.at(0)], &Keyword.put(&1, :outputs, []))
      assert {:error, {:missing_destination_output, "review"}} = validate(c)

      outputs = [
        [kind: :destination, destination: "memory", ontology: Gralkor.DefaultOntology],
        [kind: :destination, destination: "memory", ontology: Gralkor.DefaultOntology]
      ]

      c = update_in(config(), [:reflections, Access.at(0)], &Keyword.put(&1, :outputs, outputs))
      assert {:error, {:duplicate_destination_output, "review"}} = validate(c)
    end
  end

  describe "if a Reflection declares an unsupported output kind" do
    test "then validation identifies the Reflection and output kind" do
      c =
        update_in(
          config(),
          [:reflections, Access.at(0)],
          &Keyword.put(&1, :outputs, [[kind: :other]])
        )

      assert {:error, {:unsupported_reflection_output, "review", :other}} = validate(c)
    end
  end

  describe "if a Reflection output has a missing or unknown Destination or invalid ontology" do
    test "then validation identifies the Reflection and invalid output field" do
      c =
        update_in(
          config(),
          [:reflections, Access.at(0)],
          &Keyword.put(&1, :outputs, [[kind: :destination, ontology: Gralkor.DefaultOntology]])
        )

      assert {:error, {:missing_reflection_destination, "review", nil}} = validate(c)

      c =
        update_in(
          config(),
          [:reflections, Access.at(0)],
          &Keyword.put(&1, :outputs, [
            [kind: :destination, destination: "missing", ontology: Gralkor.DefaultOntology]
          ])
        )

      assert {:error, {:unknown_destination, :reflections, "review", "missing"}} = validate(c)

      c =
        update_in(
          config(),
          [:reflections, Access.at(0)],
          &Keyword.put(&1, :outputs, [
            [kind: :destination, destination: "memory", ontology: String]
          ])
        )

      assert {:error, {:invalid_reflection_ontology, "review", String}} = validate(c)
    end
  end

  describe "if a Reflection's Chain of Thought is missing, unstructured, empty, or contains a malformed step" do
    test "then validation identifies the Reflection and Chain of Thought failure" do
      c =
        update_in(config(), [:reflections, Access.at(0)], &Keyword.delete(&1, :chain_of_thought))

      assert {:error, {:missing_chain_of_thought, "review"}} = validate(c)

      c =
        update_in(
          config(),
          [:reflections, Access.at(0)],
          &Keyword.put(&1, :chain_of_thought, :bad)
        )

      assert {:error, {:invalid_chain_of_thought, "review", :bad}} = validate(c)

      c =
        update_in(
          config(),
          [:reflections, Access.at(0)],
          &Keyword.put(&1, :chain_of_thought, steps: [])
        )

      assert {:error, {:invalid_chain_of_thought, "review", :missing_steps}} = validate(c)

      c =
        update_in(
          config(),
          [:reflections, Access.at(0)],
          &Keyword.put(&1, :chain_of_thought, steps: [:bad])
        )

      assert {:error, {:invalid_chain_of_thought, "review", {:invalid_step, :bad}}} = validate(c)
    end
  end

  describe "if a Chain of Thought or one of its steps contains unknown fields" do
    test "then validation identifies the Reflection, step when applicable, and unknown fields" do
      c =
        update_in(
          config(),
          [:reflections, Access.at(0)],
          &Keyword.put(&1, :chain_of_thought, steps: [], extra: true)
        )

      assert {:error, {:unknown_chain_of_thought_fields, "review", [:extra]}} = validate(c)

      c =
        update_in(
          config(),
          [:reflections, Access.at(0)],
          &Keyword.put(&1, :chain_of_thought,
            steps: [
              [
                label: "inspect",
                directions: "Inspect.",
                output: %{"summary" => "string"},
                extra: true
              ]
            ]
          )
        )

      assert {:error, {:unknown_chain_of_thought_step_fields, "review", "inspect", [:extra]}} =
               validate(c)
    end
  end

  describe "if a configured ontology declares `Entity`, `Episodic`, or `Community`" do
    test "then validation identifies the entity kind reserved by Graphiti" do
      for {kind, ontology} <- [
            {"Entity", EntityOntology},
            {"Episodic", EpisodicOntology},
            {"Community", CommunityOntology}
          ] do
        c = ontology_configuration(ontology)
        assert {:error, {:reserved_entity_kind, ^kind}} = validate(c)
      end
    end
  end

  describe "when a configured ontology declares another entity kind" do
    test "then it remains eligible for configuration" do
      c = ontology_configuration(PersonOntology)
      assert :ok = validate(c)
    end
  end

  defp validate(configuration),
    do:
      Runtime.validate(configuration,
        packaged_reflections: fn -> [] end,
        parse_chain_of_thought: &parse_chain_of_thought/1
      )

  defp config do
    %{
      destinations: [[name: "memory"]],
      lenses: [
        [
          name: "notes",
          destination: "memory",
          write: :append,
          ingestion: Gralkor.Lens.Ingestion.Store,
          ontology: Gralkor.DefaultOntology
        ]
      ],
      reflections: [
        [
          name: "review",
          outputs: [
            [kind: :destination, destination: "memory", ontology: Gralkor.DefaultOntology]
          ],
          chain_of_thought: [
            steps: [[label: "inspect", directions: "Inspect.", output: %{"summary" => "string"}]]
          ]
        ]
      ]
    }
  end

  defp named(collection, value, duplicate \\ false) do
    definition = Keyword.put(List.first(Map.fetch!(config(), collection)), :name, value)
    Map.put(config(), collection, if(duplicate, do: [definition, definition], else: [definition]))
  end

  defp ontology_configuration(ontology) do
    %{
      config()
      | lenses: [
          [
            name: "notes",
            destination: "memory",
            write: :append,
            ingestion: Gralkor.Lens.Ingestion.Store,
            ontology: ontology
          ]
        ],
        reflections: []
    }
  end

  defp parse_chain_of_thought(
         steps: [[label: "inspect", directions: "Inspect.", output: %{"summary" => "string"}]]
       ) do
    {:ok,
     %Gralkor.Reflection.ChainOfThought{
       steps: [
         %Gralkor.Reflection.ChainOfThought.Step{
           label: "inspect",
           directions: "Inspect.",
           output: %{"summary" => "string"}
         }
       ]
     }}
  end

  defp parse_chain_of_thought(%{
         steps: [%{label: "inspect", directions: "Inspect.", output: %{"summary" => "string"}}]
       }) do
    {:ok,
     %Gralkor.Reflection.ChainOfThought{
       steps: [
         %Gralkor.Reflection.ChainOfThought.Step{
           label: "inspect",
           directions: "Inspect.",
           output: %{"summary" => "string"}
         }
       ]
     }}
  end
end
