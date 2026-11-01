# The Postgres-backed tests need a database; the CI test job provides one.
# In CI a missing database is an error, never a quiet skip: merging publishes.
exclude =
  cond do
    System.get_env("ASH_DISPATCH_TEST_DATABASE_URL") ->
      []

    System.get_env("CI") ->
      raise "CI must run the Postgres tests: set ASH_DISPATCH_TEST_DATABASE_URL"

    true ->
      [:postgres]
  end

ExUnit.start(exclude: exclude)

# Ensure ash_dispatch application is started for tests
Application.ensure_all_started(:ash_dispatch)

# Configure test domain for introspection tests
# Test support files are compiled via mix.exs elixirc_paths: ["lib", "test/support"]
Application.put_env(:ash_dispatch_test, :ash_domains, [AshDispatch.Test.Domain])

# Configure test mailer for email backend tests
Application.put_env(:ash_dispatch, AshDispatch.Test.Mailer, adapter: Swoosh.Adapters.Test)
