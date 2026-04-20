defmodule JidoGralkor.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/elimydlarz/jido_gralkor"

  def project do
    [
      app: :jido_gralkor,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      preferred_cli_env: [
        "test.unit": :test,
        "test.integration": :test,
        "test.functional": :test
      ],
      description: description(),
      package: package(),
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:jido, "~> 2.2"},
      {:jido_ai, "~> 2.1"},
      {:gralkor, "~> 1.1"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      "test.unit": ["test --exclude integration --exclude functional"],
      "test.integration": ["test --only integration"],
      "test.functional": ["test --only functional"]
    ]
  end

  defp description do
    "Jido plugin and actions that adapt the Gralkor memory server into a Jido agent. Drop in the plugin for recall-on-query and capture-on-completion; add the actions to your ReAct tools list for explicit memory_search / memory_add."
  end

  defp package do
    [
      maintainers: ["susu-eng"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Issues" => "#{@source_url}/issues"
      },
      files: ~w(lib mix.exs README.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      extras: ["README.md"]
    ]
  end
end
