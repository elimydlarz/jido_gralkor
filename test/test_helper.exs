Gralkor.TestEnv.load(Path.expand("../.env", __DIR__))

:ok = Gralkor.Python.ensure_initialised()

case Gralkor.Client.InMemory.start_link() do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

Mimic.copy(Gralkor.Client)
Mimic.copy(JidoGralkor.MemorySearchPresentation)

ExUnit.start(trace: true, exclude: [:journey, :functional])
