defmodule Gralkor.LensRegistrationFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  alias Gralkor.Client
  alias Gralkor.Ingest
  alias Gralkor.Search

  defmodule MemoryOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open

    entity Memory do
      field(:content, :string, required: true)
    end
  end

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
    previous_destinations = Application.get_env(:jido_gralkor, :destinations)
    previous_storage = Application.get_env(:jido_gralkor, :lens_storage)

    Application.put_env(:jido_gralkor, :destinations, [
      [name: "memory"]
    ])

    Application.put_env(:jido_gralkor, :lenses, [valid_lens("observations")])
    Application.put_env(:jido_gralkor, :lens_storage, UnexpectedStorage)

    on_exit(fn ->
      restore_env(:lenses, previous_lenses)
      restore_env(:destinations, previous_destinations)
      restore_env(:lens_storage, previous_storage)
    end)

    :ok
  end

  describe "when the application compatibility registry contains a valid appending or replaceable Lens" do
    test "then direct compatibility operations can select the Lens by name" do
      assert %Gralkor.Lens{name: "observations"} = Client.lens!("observations")

      Application.put_env(:jido_gralkor, :lenses, [valid_replaceable_lens("systems")])

      assert %Gralkor.Lens.Replaceable{name: "systems"} = Client.lens!("systems")
    end

    test "and each selected name resolves to the same application-owned Lens definition" do
      assert %Gralkor.Lens{
               name: "observations",
               destination: %Gralkor.Destination{name: "memory"},
               ontology: MemoryOntology,
               ingestion: StoreIngestion
             } = Client.lens!("observations")

      Application.put_env(:jido_gralkor, :lenses, [valid_replaceable_lens("systems")])

      assert %Gralkor.Lens.Replaceable{name: "systems"} = Client.lens!("systems")
    end

    test "and the Lens uses its referenced registered Destination" do
      assert Client.lens!("observations").destination.name == "memory"
    end
  end

  describe "where an appending Lens definition provides `write: :append`, a Destination name, and an ingestion process" do
    test "then the Lens uses its declared ingestion behaviour" do
      assert %Gralkor.Lens{
               name: "observations",
               destination: %Gralkor.Destination{name: "memory"},
               ontology: MemoryOntology,
               ingestion: StoreIngestion
             } = Client.lens!("observations")
    end
  end

  describe "where an application compatibility Lens omits its write mode" do
    test "then the Lens defaults to `write: :append`" do
      Application.put_env(:jido_gralkor, :lenses, [
        valid_lens("observations") |> Keyword.delete(:write)
      ])

      assert %Gralkor.Lens{ingestion: StoreIngestion} = Client.lens!("observations")
    end
  end

  describe "where an appending Lens omits its ontology" do
    test "then the Lens uses jido_gralkor's built-in default ontology" do
      Application.put_env(:jido_gralkor, :lenses, [
        valid_lens("observations") |> Keyword.delete(:ontology)
      ])

      assert Client.lens!("observations").ontology == Gralkor.DefaultOntology
    end
  end

  describe "if an application compatibility Lens's ontology declares a custom entity kind named `Entity`, `Episodic`, or `Community`" do
    test "then validation fails identifying the entity kind reserved by Graphiti" do
      for {kind, ontology} <- [
            {"Entity", EntityOntology},
            {"Episodic", EpisodicOntology},
            {"Community", CommunityOntology}
          ] do
        Application.put_env(:jido_gralkor, :lenses, [
          valid_lens("observations") |> Keyword.put(:ontology, ontology)
        ])

        assert_raise ArgumentError, ~r/#{kind}.*reserved by Graphiti/, fn ->
          Client.lens!("observations")
        end
      end
    end
  end

  describe "when an application compatibility Lens's ontology declares a custom entity kind named `Person`" do
    test "then validation accepts that entity kind" do
      Application.put_env(:jido_gralkor, :lenses, [
        valid_lens("people") |> Keyword.put(:ontology, PersonOntology)
      ])

      assert %Gralkor.Lens{ontology: PersonOntology} = Client.lens!("people")
    end
  end

  describe "if a Lens definition retains a top-level scope or address setting" do
    test "then validation fails identifying the unsupported Lens setting" do
      for legacy_setting <- [[scope: :operator], [address: "global/observations"]] do
        Application.put_env(
          :jido_gralkor,
          :lenses,
          [Keyword.merge(valid_lens("observations"), legacy_setting)]
        )

        assert_raise ArgumentError, ~r/scope.*address.*unsupported/, fn ->
          Client.lens!("observations")
        end
      end
    end
  end

  describe "if the application compatibility Lens registry is not a list" do
    test "then validation fails naming what it found instead" do
      Application.put_env(:jido_gralkor, :lenses, %{not: "a list"})

      assert_raise ArgumentError, ~r/Lens registry must be a list, got %{not: "a list"}/, fn ->
        Client.lens!("observations")
      end
    end
  end

  describe "if the application compatibility registry contains an invalid Lens" do
    test "then validation fails before ingestion or search begins" do
      Application.put_env(:jido_gralkor, :lenses, [valid_lens("observations"), :invalid])

      assert_raise ArgumentError, fn ->
        Client.ingest(%Ingest{
          id: "unregistered-lens-ingestion",
          operator_id: "operator-one",
          lens: "observations",
          source_kind: :document,
          content: "must not land",
          source_description: "functional"
        })
      end

      assert_raise ArgumentError, fn ->
        Client.search(%Search{
          operator_id: "operator-one",
          query: "must not run",
          destinations: ["memory"]
        })
      end
    end

    test "and a blank Lens name is identified" do
      Application.put_env(:jido_gralkor, :lenses, [valid_lens(" ")])

      assert_raise ArgumentError, ~r/invalid Lens name " "/, fn -> Client.lens!(" ") end
    end

    test "and a Lens name containing the reserved provenance delimiter ` [lens: ` is identified" do
      name = "review [lens: observations]"
      Application.put_env(:jido_gralkor, :lenses, [valid_lens(name)])

      assert_raise ArgumentError,
                   ~r/invalid Lens "review \[lens: observations\]".*reserved provenance syntax.*" \[lens: "/,
                   fn -> Client.lens!(name) end
    end

    test "and a duplicate Lens name is identified" do
      Application.put_env(:jido_gralkor, :lenses, [
        valid_lens("observations"),
        valid_lens("observations")
      ])

      assert_raise ArgumentError, ~r/duplicate Lens "observations"/, fn ->
        Client.lens!("observations")
      end
    end

    test "and a reserved `operator` or `global` Lens name is identified" do
      for name <- ["operator", "global"] do
        Application.put_env(:jido_gralkor, :lenses, [valid_lens(name)])

        assert_raise ArgumentError, ~r/#{name}.*reserved/, fn -> Client.lens!(name) end
      end
    end

    test "and the retired `default` Lens name identifies `operator` as its replacement" do
      Application.put_env(:jido_gralkor, :lenses, [valid_lens("default")])

      assert_raise ArgumentError, ~r/default.*operator/, fn -> Client.lens!("default") end
    end

    test "and a removed graph-format field is identified with its Lens" do
      Application.put_env(:jido_gralkor, :lenses, [
        valid_replaceable_lens("systems") ++ [graph_format: :property_graph]
      ])

      assert_raise ArgumentError, ~r/systems.*graph_format.*unsupported/, fn ->
        Client.lens!("systems")
      end
    end

    test "and an invalid Lens definition shape is identified" do
      for definition <- [%{name: "observations"}, [:not_a_keyword_entry]] do
        Application.put_env(:jido_gralkor, :lenses, [definition])

        assert_raise ArgumentError, ~r/invalid Lens definition/, fn ->
          Client.lens!("observations")
        end
      end
    end

    test "and a missing or unknown Lens Destination is identified with its Lens" do
      for destination <- [nil, "missing"] do
        Application.put_env(:jido_gralkor, :lenses, [
          valid_lens("observations") |> Keyword.put(:destination, destination)
        ])

        assert_raise ArgumentError, ~r/observations.*Destination.*#{inspect(destination)}/, fn ->
          Client.lens!("observations")
        end
      end
    end

    test "and an invalid Lens ontology is identified with its Lens" do
      Application.put_env(:jido_gralkor, :lenses, [
        valid_lens("observations") |> Keyword.put(:ontology, String)
      ])

      assert_raise ArgumentError, ~r/observations.*ontology.*String/, fn ->
        Client.lens!("observations")
      end
    end

    test "and an invalid Lens ingestion process is identified with its Lens" do
      Application.put_env(:jido_gralkor, :lenses, [
        valid_lens("observations") |> Keyword.put(:ingestion, String)
      ])

      assert_raise ArgumentError, ~r/observations.*ingestion.*String/, fn ->
        Client.lens!("observations")
      end
    end

    test "and an invalid Lens write mode is identified with its Lens" do
      Application.put_env(:jido_gralkor, :lenses, [
        valid_lens("observations") |> Keyword.put(:write, :overwrite)
      ])

      assert_raise ArgumentError, ~r/observations.*write.*overwrite/, fn ->
        Client.lens!("observations")
      end
    end

    test "and a Lens definition that combines appending and replaceable write settings is identified with its Lens" do
      definition = valid_replaceable_lens("systems") |> Keyword.put(:ingestion, StoreIngestion)
      Application.put_env(:jido_gralkor, :lenses, [definition])

      assert_raise ArgumentError, ~r/systems.*combines.*write settings/, fn ->
        Client.lens!("systems")
      end
    end
  end

  defp valid_lens(name) do
    [
      name: name,
      destination: "memory",
      write: :append,
      ontology: MemoryOntology,
      ingestion: StoreIngestion
    ]
  end

  defp valid_replaceable_lens(name) do
    [name: name, destination: "memory", write: :replace_graph]
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
