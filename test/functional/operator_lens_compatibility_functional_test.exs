defmodule Gralkor.OperatorLensCompatibilityFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  alias Gralkor.Client
  alias Gralkor.Client.InMemory
  alias Gralkor.Ingest
  alias JidoGralkor.Actions.MemoryAdd

  setup do
    keys = [:client, :destination_storage, :lenses, :lens_storage, :ontology]
    previous = Map.new(keys, &{&1, Application.get_env(:jido_gralkor, &1)})

    start_supervised!(Gralkor.Lens.Storage.InMemory)

    Application.delete_env(:jido_gralkor, :lenses)

    Application.put_env(
      :jido_gralkor,
      :destination_storage,
      Gralkor.Destination.Storage.InMemory
    )

    Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)

    on_exit(fn -> Enum.each(previous, fn {key, value} -> restore_env(key, value) end) end)

    :ok
  end

  describe "where an application has not registered or selected a named Lens" do
    test "then implicit-default memory uses the graph named `operator/<operator id>`" do
      assert :ok =
               Client.ingest(%Ingest{
                 operator_id: "operator-one",
                 lens: "operator",
                 source_kind: :document,
                 content: "compatible memory",
                 source_description: "legacy"
               })

      assert {:ok, [%{destination: "operator", fact: "compatible memory"}]} =
               Client.search(%Gralkor.Search{
                 operator_id: "operator-one",
                 query: "compatible"
               })
    end

    test "and jido_gralkor's built-in ontology governs implicit-default extraction" do
      assert %Gralkor.Lens{
               name: "operator",
               destination: %Gralkor.Destination{name: "operator"},
               ontology: Gralkor.DefaultOntology
             } =
               Client.lens!("operator")
    end

    test "and legacy capture, explicit memory addition, and recall use that built-in ontology consistently" do
      assert Client.lens!("operator").ontology == Gralkor.DefaultOntology
      assert_legacy_memory_works()
    end

    test "and implicit-default capture, explicit memory addition, and recall work without a consumer ontology module" do
      Application.delete_env(:jido_gralkor, :ontology)
      assert_legacy_memory_works()
    end
  end

  describe "when implicit-default memory and a named Lens write for the same operator" do
    test "then implicit-default memory writes to the graph named `operator/<operator id>`" do
      Application.put_env(:jido_gralkor, :client, InMemory)
      InMemory.reset()
      InMemory.set_memory_add(:ok)

      assert {:ok, %{result: "Ingesting."}} =
               MemoryAdd.run(
                 %{
                   content: "implicit memory",
                   source_kind: :document,
                   source_description: "manual"
                 },
                 %{agent_id: "operator-one"}
               )

      assert eventually(fn ->
               InMemory.adds() == [
                 ["operator/operator-one", "implicit memory", "manual", :document]
               ]
             end)
    end
  end

  describe "if an application retains the removed deployment-wide `:jido_gralkor, :ontology` setting" do
    test "then the implicit `operator` Lens still uses jido_gralkor's built-in ontology" do
      Application.put_env(:jido_gralkor, :ontology, Gralkor.TestOntologies.Strict)

      assert Client.lens!("operator").ontology == Gralkor.DefaultOntology
    end
  end

  defp assert_legacy_memory_works do
    Application.put_env(:jido_gralkor, :client, Gralkor.Client.InMemory)
    Gralkor.Client.InMemory.reset()
    Gralkor.Client.InMemory.set_capture(:ok)
    Gralkor.Client.InMemory.set_memory_add(:ok)
    Gralkor.Client.InMemory.set_recall({:ok, "legacy memory"})

    messages = [%Gralkor.Message{role: "user", content: "Remember this."}]

    assert :ok =
             Client.impl().capture(
               "session-one",
               "operator_one",
               "Susu",
               "Eli",
               messages
             )

    assert :ok = Client.impl().memory_add("operator_one", "Legacy fact.", "manual")

    assert {:ok, "legacy memory"} =
             Client.impl().recall("operator_one", "Susu", "session-one", "fact")

    assert [["session-one", "operator_one", "Susu", "Eli", ^messages]] =
             Gralkor.Client.InMemory.captures()

    assert [["operator_one", "Legacy fact.", "manual"]] =
             Gralkor.Client.InMemory.adds()

    assert [["operator_one", "Susu", "session-one", "fact"]] =
             Gralkor.Client.InMemory.recalls()
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)

  defp eventually(assertion, attempts \\ 100)

  defp eventually(assertion, attempts) do
    cond do
      assertion.() -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && eventually(assertion, attempts - 1)
    end
  end
end
