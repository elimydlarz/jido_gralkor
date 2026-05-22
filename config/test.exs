import Config

config :logger, level: :info

config :gralkor_ex,
  client: Gralkor.Client.InMemory,
  client_http: [
    url: "http://gralkor.test"
  ]
