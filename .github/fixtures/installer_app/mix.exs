# A bare Ash app for CI's `installer` job: a repo and a user resource, nothing
# from ash_dispatch yet. The job runs `mix ash_dispatch.install` in a copy of
# it and compiles the result. No ash_typescript, on purpose (#31).
defmodule Demo.MixProject do
  use Mix.Project

  def project do
    [app: :demo, version: "0.1.0", elixir: "~> 1.15", deps: deps()]
  end

  defp deps do
    [
      {:ash_dispatch, path: System.get_env("ASH_DISPATCH_PATH", "../ash_dispatch")},
      {:igniter, "~> 0.8", only: [:dev, :test]}
    ]
  end
end
