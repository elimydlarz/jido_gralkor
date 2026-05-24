Gralkor.TestEnv.load(Path.expand("../.env", __DIR__))

:ok = Gralkor.Python.ensure_initialised()

{:ok, _} = Gralkor.Client.InMemory.start_link()

ExUnit.start(trace: true, exclude: [:journey, :functional])
