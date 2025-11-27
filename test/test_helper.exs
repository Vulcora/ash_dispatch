ExUnit.start()

# Ensure ash_dispatch application is started for tests
Application.ensure_all_started(:ash_dispatch)

# Configure test domain for introspection tests
# Test support files are compiled via mix.exs elixirc_paths: ["lib", "test/support"]
Application.put_env(:ash_dispatch_test, :ash_domains, [AshDispatch.Test.Domain])
