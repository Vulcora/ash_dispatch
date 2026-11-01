# The Postgres-backed tests need a database; the CI test job provides one.
exclude = if System.get_env("ASH_DISPATCH_TEST_DATABASE_URL"), do: [], else: [:postgres]

ExUnit.start(exclude: exclude)

# Ensure ash_dispatch application is started for tests
Application.ensure_all_started(:ash_dispatch)

# Configure test domain for introspection tests
# Test support files are compiled via mix.exs elixirc_paths: ["lib", "test/support"]
Application.put_env(:ash_dispatch_test, :ash_domains, [AshDispatch.Test.Domain])

# Configure test mailer for email backend tests
Application.put_env(:ash_dispatch, AshDispatch.Test.Mailer, adapter: Swoosh.Adapters.Test)
