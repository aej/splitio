defmodule Splitio.MixProject do
  use Mix.Project

  def project do
    [
      app: :splitio,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:mint, "~> 1.6"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.9"},
      {:telemetry, "~> 1.2"},
      {:nimble_options, "~> 1.1"},
      {:mox, "~> 1.1", only: :test},
      {:benchee, "~> 1.3", only: [:dev, :test]}
    ]
  end
end
