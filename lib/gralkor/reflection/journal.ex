defmodule Gralkor.Reflection.Journal do
  @moduledoc false

  def open(nil, _name), do: {:ok, nil}

  def open(path, name) when is_binary(path) and is_atom(name) do
    File.mkdir_p!(Path.dirname(path))

    case :dets.open_file(name,
           file: String.to_charlist(path),
           type: :set,
           auto_save: 1_000,
           repair: true
         ) do
      {:ok, ^name} -> {:ok, name}
      {:error, reason} -> {:error, {:journal_open_failed, reason}}
    end
  end

  def all(nil), do: []

  def all(table) do
    :dets.foldl(fn {_key, job}, jobs -> [job | jobs] end, [], table)
  end

  def put_all(nil, _jobs), do: :ok
  def put_all(_table, []), do: :ok

  def put_all(table, jobs) do
    records = Enum.map(jobs, &{&1.key, &1})

    with :ok <- :dets.insert(table, records),
         :ok <- :dets.sync(table) do
      :ok
    end
  end

  def delete(nil, _key), do: :ok

  def delete(table, key) do
    with :ok <- :dets.delete(table, key),
         :ok <- :dets.sync(table) do
      :ok
    end
  end

  def close(nil), do: :ok
  def close(table), do: :dets.close(table)
end
