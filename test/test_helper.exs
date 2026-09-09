Gralkor.TestEnv.load(Path.expand("../.env", __DIR__))

:ok = Gralkor.Python.ensure_initialised()

case Gralkor.Client.InMemory.start_link() do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

ExUnit.start(trace: true, exclude: [:journey, :functional])
