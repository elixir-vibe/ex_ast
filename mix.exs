defmodule ExAst.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_ast,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Search and replace Elixir code by AST pattern",
      package: package()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:sourceror, "~> 1.7"}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/nickolasgaidamakin/ex_ast"}
    ]
  end
end
