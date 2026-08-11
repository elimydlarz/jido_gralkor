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
      [name: "shared", address: "operator/shared", ontology: MemoryOntology]
    ])

    Application.put_env(:jido_gralkor, :lenses, [
      [name: "observations", destination: "shared", ingestion: StoreIngestion]
    ])

    Application.put_env(:jido_gralkor, :reflections, [
      [
        name: "review",
        destination: "shared",
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
  end
end
