import Config

config :logger, level: :warning

config :gralkor,
  client: Gralkor.Client.InMemory,
  client_http: [
    url: "http://gralkor.test"
  ]
