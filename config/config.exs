import Config

# Register AshDispatch domain
config :ash_dispatch, ash_domains: [AshDispatch.Domain]

# Configure user resource (can be overridden by consuming application)
config :ash_dispatch,
  user_resource: nil,
  repo: nil
