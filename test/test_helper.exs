{:ok, _} = Gralkor.Client.InMemory.start_link()

ExUnit.start(trace: true, exclude: [:integration, :functional])
