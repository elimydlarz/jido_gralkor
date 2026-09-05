defmodule Gralkor.DestinationRegistrationFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  alias Gralkor.Client
  alias JidoGralkor.Runtime

  defmodule MemoryOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open
  end

  defmodule StoreIngestion do
    @behaviour Gralkor.Lens.Ingestion

    @impl true
    def ingest(_request, _store), do: :ok
  end

  setup do
    previous =
      for key <- [
            :destinations,
            :lenses,
            :reflections,
            :lens_storage,
            :destination_storage,
            :reflection_storage
          ],
          into: %{} do
        {key, Application.get_env(:jido_gralkor, key)}
      end

    Application.put_env(:jido_gralkor, :destinations, [
      [name: "shared"]
    ])

    Application.put_env(:jido_gralkor, :lenses, [
      [
        name: "observations",
        destination: "shared",
        ontology: MemoryOntology,
        ingestion: StoreIngestion
      ]
    ])

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:jido_gralkor, key)
        {key, value} -> Application.put_env(:jido_gralkor, key, value)
      end)
    end)

    :ok
  end

  describe "when an application registers a valid Destination" do
    test "then Lenses and Reflections can reference that Destination by name" do
      assert %Gralkor.Lens{destination: %Gralkor.Destination{name: "shared"}} =
               Client.lens!("observations")

      assert [%Gralkor.Reflection{outputs: [output]}] =
               configured_reflections!([reflection_definition()])

      assert output.destination == %Gralkor.Destination{name: "shared"}
    end

    test "and the Destination name identifies the graph where their results are saved" do
      destination = Client.lens!("observations").destination

      assert Gralkor.Destination.graph_id(destination, "operator-one") ==
               "shared"
    end
  end

  describe "where the packaged Destinations are used" do
    test "then operator memory references the Destination named `operator`" do
      assert Client.lens!("operator").destination.name == "operator"
    end

    test "and globally shared memory references the Destination named `global`" do
      assert Gralkor.Destination.Registry.fetch!("global").name == "global"
    end
  end

  describe "when multiple Lenses or Reflections reference the same Destination" do
    test "then their results are saved to the same Destination" do
      lens_destination = Client.lens!("observations").destination
      [reflection] = configured_reflections!([reflection_definition()])

      destination_output = Enum.find(reflection.outputs, &(&1.kind == :destination))
      assert destination_output.destination == lens_destination
    end
  end

  describe "where a replaceable Lens references a shared Destination" do
    test "then replacement changes only graph content previously written by that Lens" do
      start_supervised!(Gralkor.Lens.Storage.InMemory)
      Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)

      Application.put_env(:jido_gralkor, :lenses, [
        replaceable_lens("systems"),
        replaceable_lens("catalogue")
      ])

      assert :ok = Client.replace(replacement("catalogue", "catalogue"))
      assert :ok = Client.replace(replacement("systems-old", "systems"))
      assert :ok = Client.replace(replacement("systems-new", "systems"))

      assert Enum.map(Gralkor.Lens.Storage.InMemory.graph("shared").nodes, & &1.id) == [
               "catalogue",
               "systems-new"
             ]
    end

    test "and information saved through every other Lens or Reflection remains unchanged" do
      start_supervised!(Gralkor.Lens.Storage.InMemory)
      start_supervised!(Gralkor.Destination.Storage.InMemory)
      Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)

      Application.put_env(
        :jido_gralkor,
        :destination_storage,
        Gralkor.Destination.Storage.InMemory
      )

      Application.put_env(:jido_gralkor, :lenses, [
        replaceable_lens("systems"),
        replaceable_lens("catalogue")
      ])

      assert :ok = Client.replace(replacement("catalogue", "catalogue"))

      reflection = configured_reflections!([reflection_definition()]) |> List.first()

      artefact = %Gralkor.Artefact{
        id: "review-one",
        payload: %{"lesson" => "preserve"}
      }

      assert :ok =
               Gralkor.Destination.Storage.put_artefact(
                 Enum.find(reflection.outputs, &(&1.kind == :destination)),
                 reflection.name,
                 "operator-one",
                 artefact,
                 storage: Gralkor.Destination.Storage.InMemory
               )

      assert :ok = Client.replace(replacement("systems", "systems"))

      assert Enum.any?(Gralkor.Lens.Storage.InMemory.graph("shared").nodes, fn node ->
               node.id == "catalogue"
             end)

      assert {:ok, [%{destination: "shared", artefact: ^artefact}]} =
               Client.search(%Gralkor.Search{
                 operator_id: "operator-two",
                 query: "preserve",
                 destinations: ["shared"],
                 result_type: :artefacts
               })
    end
  end

  describe "if the Destination registry is not a list" do
    test "then configuration resolution raises `ArgumentError` naming what it found instead" do
      Application.put_env(:jido_gralkor, :destinations, %{not: "a list"})

      assert_raise ArgumentError, ~r/Destination registry must be a list.*%{not: "a list"}/, fn ->
        Client.lens!("observations")
      end
    end
  end

  describe "if an application registers an invalid Destination" do
    test "then configuration resolution raises `ArgumentError` before ingestion, Reflection, or search begins" do
      Application.put_env(:jido_gralkor, :destinations, [[name: " "]])

      assert_raise ArgumentError, fn ->
        Client.ingest(%Gralkor.Ingest{
          id: "invalid-destination-ingestion",
          operator_id: "operator-one",
          lens: "observations",
          source_kind: :document,
          content: "must not land",
          source_description: "functional"
        })
      end

      assert_raise ArgumentError, fn ->
        configured_reflections!([reflection_definition()])
      end

      assert_raise ArgumentError, fn ->
        Client.search(%Gralkor.Search{operator_id: "operator-one", query: "must not run"})
      end
    end

    test "and a blank Destination name is identified" do
      Application.put_env(:jido_gralkor, :destinations, [
        [name: " "]
      ])

      assert_raise ArgumentError, ~r/invalid Destination name " "/, fn ->
        Client.lens!("observations")
      end
    end

    test "and a Destination name beginning `operator/` is identified as reserved" do
      Application.put_env(:jido_gralkor, :destinations, [
        [name: "operator/shared"]
      ])

      assert_raise ArgumentError,
                   ~r/invalid Destination "operator\/shared".*reserved.*"operator\/"/,
                   fn -> Gralkor.Destination.Registry.configured!() end
    end

    test "and a duplicate Destination name is identified" do
      Application.put_env(:jido_gralkor, :destinations, [
        [name: "shared"],
        [name: "shared"]
      ])

      assert_raise ArgumentError, ~r/duplicate Destination "shared"/, fn ->
        Client.lens!("observations")
      end
    end

    test "and an invalid Destination definition shape is identified" do
      Application.put_env(:jido_gralkor, :destinations, [%{name: "shared"}])

      assert_raise ArgumentError, ~r/invalid Destination definition/, fn ->
        Client.lens!("observations")
      end
    end

    test "and an address setting is identified as unsupported with its Destination" do
      Application.put_env(:jido_gralkor, :destinations, [
        [name: "shared", address: "tenant/shared"]
      ])

      assert_raise ArgumentError, ~r/shared.*address/, fn ->
        Client.lens!("observations")
      end
    end

    test "and an ontology setting is identified as unsupported with its Destination" do
      Application.put_env(:jido_gralkor, :destinations, [
        [name: "shared", ontology: MemoryOntology]
      ])

      assert_raise ArgumentError, ~r/shared.*ontology/, fn ->
        Client.lens!("observations")
      end
    end
  end

  defp replaceable_lens(name) do
    [name: name, destination: "shared", write: :replace_graph]
  end

  defp replacement(node_id, lens) do
    %Gralkor.Replace{
      operator_id: "operator-one",
      lens: lens,
      graph: %Gralkor.Graph{
        nodes: [%{id: node_id, labels: ["Thing"], properties: %{}}],
        relationships: []
      }
    }
  end

  describe "if a Lens or Reflection references an unknown Destination" do
    test "then configuration resolution raises `ArgumentError` identifying the Lens or Reflection and Destination" do
      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "observations",
          destination: "missing",
          ontology: MemoryOntology,
          ingestion: StoreIngestion
        ]
      ])

      assert_raise ArgumentError, ~r/observations.*Destination.*missing/, fn ->
        Client.lens!("observations")
      end

      assert_raise ArgumentError, ~r/unknown_destination.*review.*missing/, fn ->
        configured_reflections!([
          reflection_definition(
            outputs: [
              [kind: :destination, destination: "missing", ontology: MemoryOntology]
            ]
          )
        ])
      end
    end
  end

  defp configured_reflections!(definitions) do
    configuration = %{
      destinations: Application.fetch_env!(:jido_gralkor, :destinations),
      lenses: [],
      reflections: definitions
    }

    JidoGralkor.Plugin.mount(%{},
      agent_name: "Destination registration",
      runtime_config: configuration
    )

    start_supervised!({Runtime, owner: self(), configuration: configuration})

    Enum.map(definitions, &Runtime.reflection!(self(), Keyword.fetch!(&1, :name)))
  end

  defp reflection_definition(overrides \\ []) do
    Keyword.merge(
      [
        name: "review",
        outputs: [
          [kind: :destination, destination: "shared", ontology: MemoryOntology]
        ],
        chain_of_thought: %{
          steps: [
            %{
              label: "review",
              directions: "Review the supplied evidence.",
              output: %{"summary" => "string"}
            }
          ]
        }
      ],
      overrides
    )
  end
end
