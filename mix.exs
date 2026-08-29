defmodule JidoGralkor.MixProject do
  use Mix.Project

  @version "8.0.2"
  @source_url "https://github.com/elimydlarz/jido_gralkor"

  def project do
    [
      app: :jido_gralkor,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      test_coverage: [summary: [threshold: 0]],
      description: description(),
      package: package(),
      source_url: @source_url,
      docs: docs()
    ]
  end

  def cli do
    [
      preferred_envs: [
        muzak: :test,
        "test.unit": :test,
        "test.integration": :test,
        "test.functional": :test,
        "test.journey": :test,
        "test.changed": :test,
        "test.fast": :test,
        "test.all": :test
      ]
    ]
  end

  def application do
    [
      mod: {Gralkor.Application, []},
      extra_applications: [:logger, :inets, :ssl]
    ]
  end

  defp deps do
    [
      {:jido, "~> 2.2"},
      {:jido_ai, "~> 2.3"},
      {:pythonx, "~> 0.4"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:muzak, git: "git@github.com:elimydlarz/muzak.git", branch: "elixir-1.19", only: :test}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      "test.unit": ["test --exclude integration --exclude functional --exclude journey"],
      "test.integration": ["test --only integration"],
      "test.functional": ["test --only functional"],
      "test.journey": ["test --only journey"],
      "test.changed": ["test --stale --include functional --exclude journey"],
      "test.fast": ["test --stale --exclude functional --exclude journey"],
      "test.all": [&test_all/1]
    ]
  end

  defp test_all(_) do
    statuses =
      Enum.map(
        ["mix test --include functional --include journey", "node --test"],
        fn command -> Mix.shell().cmd(command) end
      )

    if Enum.any?(statuses, &(&1 != 0)), do: Mix.raise("Tests failed")
  end

  defp description do
    "In-process long-term memory for Jido agents, with automatic turn capture and explicit memory search and ingestion tools."
  end

  defp package do
    [
      maintainers: ["susu-eng"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Issues" => "#{@source_url}/issues"
      },
      files: ~w(lib priv config mix.exs README.md DESTINATIONS.md CHANGELOG.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      extras: ["README.md", "DESTINATIONS.md"]
    ]
  end
end
