defmodule Gralkor.DestinationSearchFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  alias Gralkor.Client
  alias Gralkor.Search

  defmodule SearchStorage do
    @behaviour Gralkor.Destination.Storage

    @impl true
    def search(destination, operator_id, query, result_type, max_results, opts) do
      send(Application.fetch_env!(:jido_gralkor, :destination_search_test_pid), {
        :destination_search,
        destination.name,
        operator_id,
        query,
        result_type,
        max_results,
        opts
      })

      {:ok, ["#{destination.name}:#{query}"]}
    end
  end

  setup do
    previous =
      for key <- [:destinations, :destination_storage, :destination_search_test_pid], into: %{} do
        {key, Application.get_env(:jido_gralkor, key)}
      end

    Application.put_env(:jido_gralkor, :destinations, [
      [name: "first", address: "operator/first"],
      [name: "second", address: "global/second"]
    ])

    Application.put_env(:jido_gralkor, :destination_storage, SearchStorage)
    Application.put_env(:jido_gralkor, :destination_search_test_pid, self())

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:jido_gralkor, key)
        {key, value} -> Application.put_env(:jido_gralkor, key, value)
      end)
    end)

    :ok
  end

  describe "when a caller searches memory naming one or more Destinations" do
    test "then every distinct Destination is searched concurrently" do
      assert {:ok,
              [
                %{destination: "first", fact: "first:question"},
                %{destination: "second", fact: "second:question"}
              ]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "question",
                 destinations: ["first", "second"],
                 result_type: :facts
               })

      assert_receive {:destination_search, "first", "operator-one", "question", :facts, 20,
                      []}

      assert_receive {:destination_search, "second", "operator-one", "question", :facts, 20,
                      []}
    end
  end
end
