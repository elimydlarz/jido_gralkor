import Config

config :logger, level: :warning

config :gralkor_ex,
  client: Gralkor.Client.InMemory,
  client_http: [
    url: "http://gralkor.test"
  ]
