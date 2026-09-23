import Config

# Ash 3.33 makes every application choose how string length is counted, and
# refuses to compile a resource until it has. This is ash_dispatch's own
# choice, for its own dev and test builds — Ash skips the check for resources
# compiled as a dependency, so a consuming app makes its own.
config :ash, :default_string_length_count, :codepoints

# Register AshDispatch domain
config :ash_dispatch, ash_domains: [AshDispatch.Domain]

# Configure user resource (can be overridden by consuming application)
config :ash_dispatch,
  user_resource: nil,
  repo: nil
