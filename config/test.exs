import Config

config :logger, level: :info

config :jido_gralkor,
  client: Gralkor.Client.InMemory
