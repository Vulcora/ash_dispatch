import Config

config :ash, :default_string_length_count, :codepoints

config :demo, ecto_repos: [Demo.Repo], ash_domains: [Demo.Accounts]

config :demo, Demo.Repo,
  database: "demo",
  username: "postgres",
  password: "postgres",
  hostname: "localhost"

import_config "#{config_env()}.exs"
