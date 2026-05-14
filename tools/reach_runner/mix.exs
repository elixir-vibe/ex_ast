defmodule ExASTReachRunner.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_ast_reach_runner,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: deps()
    ]
  end

  defp deps do
    [
      {:ex_ast, path: "../..", override: true},
      {:reach, "~> 2.3"}
    ]
  end
end
