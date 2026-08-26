defmodule Gralkor.DestinationRegistrationFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  alias Gralkor.Client
  alias Gralkor.Reflection.Registry, as: ReflectionRegistry

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
      for key <- [:destinations, :lenses, :reflections], into: %{} do
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

    Application.put_env(:jido_gralkor, :reflections, [
      [
        name: "review",
        destination: "shared",
        ontology: MemoryOntology,
        chain_of_thought: "priv/reflections/erl.yaml"
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

      assert [%Gralkor.Reflection{destination: %Gralkor.Destination{name: "shared"}}] =
               ReflectionRegistry.configured!()
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
    test "and a blank Destination name is identified" do
      Application.put_env(:jido_gralkor, :destinations, [
        [name: " "]
      ])

      assert_raise ArgumentError, ~r/invalid Destination name " "/, fn ->
        Client.lens!("observations")
      end
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
end
