defmodule Gralkor.LensRegistrationFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  alias Gralkor.Client
  alias Gralkor.Ingest
  alias Gralkor.Search
  alias JidoGralkor.Plugin

  defmodule MemoryOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open

    entity Memory do
      field(:content, :string, required: true)
    end
  end

  defmodule StoreIngestion do
    @behaviour Gralkor.Lens.Ingestion

    @impl true
    def ingest(request, store) do
      Gralkor.Lens.Store.add(store, request.content, request.source_description)
    end
  end

  defmodule UnexpectedStorage do
    @behaviour Gralkor.Lens.Storage

    @impl true
    def add_episode(_store, _content, _source_description), do: raise("ingestion started")

    @impl true
    def search(_store, _query, _max_results), do: raise("search started")
  end

  setup do
    previous_lenses = Application.get_env(:jido_gralkor, :lenses)
    previous_storage = Application.get_env(:jido_gralkor, :lens_storage)

    Application.put_env(:jido_gralkor, :lenses, [valid_lens("observations")])
    Application.put_env(:jido_gralkor, :lens_storage, UnexpectedStorage)

    on_exit(fn ->
      restore_env(:lenses, previous_lenses)
      restore_env(:lens_storage, previous_storage)
    end)

    :ok
  end

  describe "when an application registers a valid Lens" do
    test "then direct callers and mounted memory plugins can select that Lens by name" do
      assert %Gralkor.Lens{name: "observations"} = Client.lens!("observations")

      assert {:ok, %{default_lens: "observations"}} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 default_lens: "observations"
               )
    end

    test "and every consumer observes the same application-owned Lens definition" do
      assert %Gralkor.Lens{
               name: "observations",
               ontology: MemoryOntology,
               scope: :operator,
               ingestion: StoreIngestion
             } = Client.lens!("observations")

      assert {:ok, %{lens: plugin_lens}} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 default_lens: "observations"
               )

      assert plugin_lens == Client.lens!("observations")
    end
  end

  describe "if an application registers an invalid Lens" do
    test "then configuration resolution raises `ArgumentError` before ingestion or search begins" do
      Application.put_env(:jido_gralkor, :lenses, [valid_lens("observations"), :invalid])

      assert_raise ArgumentError, fn ->
        Client.ingest(%Ingest{
          operator_id: "operator-one",
          lens: "observations",
          content: "must not land",
          source_description: "functional"
        })
      end

      assert_raise ArgumentError, fn ->
        Client.search(%Search{
          operator_id: "operator-one",
          query: "must not run",
          targets: ["observations"]
        })
      end
    end

    test "where the Lens name is blank, then the error identifies the invalid name" do
      Application.put_env(:jido_gralkor, :lenses, [valid_lens(" ")])

      assert_raise ArgumentError, ~r/invalid Lens name " "/, fn -> Client.lens!(" ") end
    end

    test "where the Lens name duplicates another registered Lens, then the error identifies the duplicate name" do
      Application.put_env(:jido_gralkor, :lenses, [
        valid_lens("observations"),
        valid_lens("observations")
      ])

      assert_raise ArgumentError, ~r/duplicate Lens "observations"/, fn ->
        Client.lens!("observations")
      end
    end

    test "where the Lens name is reserved as `default` or `global`, then the error identifies the reserved name" do
      for name <- ["default", "global"] do
        Application.put_env(:jido_gralkor, :lenses, [valid_lens(name)])

        assert_raise ArgumentError, ~r/#{name}.*reserved/, fn -> Client.lens!(name) end
      end
    end

    test "where the Lens definition has an invalid shape, then the error identifies the invalid definition" do
      Application.put_env(:jido_gralkor, :lenses, [%{name: "observations"}])

      assert_raise ArgumentError, ~r/invalid Lens definition/, fn ->
        Client.lens!("observations")
      end
    end

    test "where the Lens ontology is invalid, then the error identifies the Lens and invalid ontology" do
      Application.put_env(:jido_gralkor, :lenses, [
        valid_lens("observations") |> Keyword.put(:ontology, String)
      ])

      assert_raise ArgumentError, ~r/observations.*ontology.*String/, fn ->
        Client.lens!("observations")
      end
    end

    test "where the Lens scope is invalid, then the error identifies the Lens and invalid scope" do
      Application.put_env(:jido_gralkor, :lenses, [
        valid_lens("observations") |> Keyword.put(:scope, :tenant)
      ])

      assert_raise ArgumentError, ~r/observations.*scope.*tenant/, fn ->
        Client.lens!("observations")
      end
    end

    test "where the Lens ingestion process is invalid, then the error identifies the Lens and invalid ingestion process" do
      Application.put_env(:jido_gralkor, :lenses, [
        valid_lens("observations") |> Keyword.put(:ingestion, String)
      ])

      assert_raise ArgumentError, ~r/observations.*ingestion.*String/, fn ->
        Client.lens!("observations")
      end
    end
  end

  defp valid_lens(name) do
    [
      name: name,
      ontology: MemoryOntology,
      scope: :operator,
      ingestion: StoreIngestion
    ]
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
