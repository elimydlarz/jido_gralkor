import Config

config :logger, :default_formatter,
  format: "[$level] $message\n",
  metadata: []

config :pythonx, :uv_init,
  pyproject_toml: """
  [project]
  name = "gralkor_ex"
  version = "0.0.0"
  requires-python = "==3.12.*"
  dependencies = [
    "graphiti-core[falkordb,google-genai]>=0.28.2",
    "falkordblite"
  ]
  """

import_config "#{config_env()}.exs"
