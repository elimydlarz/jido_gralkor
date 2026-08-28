defmodule Gralkor.Reflection.JournalTest do
  use ExUnit.Case, async: false

  alias Gralkor.Reflection.Journal

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "reflection-journal-unit-#{System.unique_integer([:positive])}.dets"
      )

    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  describe "when durable Reflection work is written and synchronized" do
    test "then reopening the journal returns the exact work under its logical completion key", %{
      path: path
    } do
      work = %{key: {"operator", "ingestion", "review"}, stage: :storage, attempt: 2}
      first_name = journal_name()
      second_name = journal_name()

      assert {:ok, ^first_name} = Journal.open(path, first_name)
      assert :ok = Journal.put_all(first_name, [work])
      assert :ok = Journal.close(first_name)

      assert {:ok, ^second_name} = Journal.open(path, second_name)
      assert Journal.all(second_name) == [work]
      assert :ok = Journal.close(second_name)
    end
  end

  describe "when durable Reflection work is deleted and synchronized" do
    test "then reopening the journal does not return that work", %{path: path} do
      work = %{key: {"operator", "ingestion", "review"}, stage: :runner, attempt: 1}
      first_name = journal_name()
      second_name = journal_name()

      assert {:ok, ^first_name} = Journal.open(path, first_name)
      assert :ok = Journal.put_all(first_name, [work])
      assert :ok = Journal.delete(first_name, work.key)
      assert :ok = Journal.close(first_name)

      assert {:ok, ^second_name} = Journal.open(path, second_name)
      assert Journal.all(second_name) == []
      assert :ok = Journal.close(second_name)
    end
  end

  describe "when no durable journal path is configured" do
    test "then reads, writes, deletes, and close are successful no-ops" do
      assert {:ok, nil} = Journal.open(nil, journal_name())
      assert Journal.all(nil) == []
      assert :ok = Journal.put_all(nil, [%{key: :work}])
      assert :ok = Journal.delete(nil, :work)
      assert :ok = Journal.close(nil)
    end
  end

  defp journal_name,
    do: Module.concat(__MODULE__, "Table#{System.unique_integer([:positive])}")
end
