defmodule Mix.Tasks.AshDispatch.Doctor do
  @shortdoc "Asks the database the questions no source check can answer"

  @moduledoc """
  #{@shortdoc}.

      mix ash_dispatch.doctor

  Starts the application (so the repo is running) and runs
  `AshDispatch.Doctor.check/1`. Exits 0 when there is nothing wrong and 1 with
  the problem and the migration to add otherwise, so it can stand in a deploy
  script or a CI job.

  Today it checks one thing: that the database can resolve the function the
  library's UUID v7 primary keys default to. `mix ash_dispatch.install` warns
  about that from the project's source, which cannot be conclusive — the first
  per-tenant host listed the `"ash-functions"` extension and the function was
  missing anyway (#50). This is the half that asks the database.

  ## Options

  * `--repo MyApp.Repo` — the repo to ask. Defaults to
    `config :ash_dispatch, repo:`.

  The same check from inside the application, for a host that would rather
  fail its own boot or its own test:

      AshDispatch.Doctor.check!()
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: [repo: :string])

    check_opts =
      case opts[:repo] do
        nil -> []
        repo -> [repo: Module.concat([repo])]
      end

    case AshDispatch.Doctor.check(check_opts) do
      :ok ->
        Mix.shell().info([:green, "✔ ", :reset, "AshDispatch.Doctor found nothing wrong."])

      {:error, error} ->
        Mix.shell().error(Exception.message(error))
        exit({:shutdown, 1})
    end
  end
end
