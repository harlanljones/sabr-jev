defmodule SabrJev.MixProject do
  use Mix.Project

  def project do
    [
      app: :sabr_jev,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      listeners: [Phoenix.CodeReloader],
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [mod: {SabrJev.Application, []}, extra_applications: [:logger, :runtime_tools]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8.14"},
      {:phoenix_live_view, "~> 1.2.12"},
      {:phoenix_html, "~> 4.3"},
      {:bandit, "~> 1.12"},
      {:jason, "~> 1.4"},
      {:typesafe_api, "0.1.0-alpha.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:lazy_html, "~> 0.1.12", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["esbuild.install --if-missing"],
      "assets.build": ["esbuild sabr_jev"],
      "assets.deploy": ["esbuild sabr_jev --minify", "phx.digest"]
    ]
  end
end
