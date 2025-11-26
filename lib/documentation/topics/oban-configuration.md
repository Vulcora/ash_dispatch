# Oban Configuration

AshDispatch uses [Oban](https://hexdocs.pm/oban) for asynchronous email delivery. This guide explains how to configure Oban for your application.

## Requirements

AshDispatch requires Oban 2.0 or later. Add it to your dependencies if not already present:

```elixir
# mix.exs
defp deps do
  [
    {:oban, "~> 2.0"}
  ]
end
```

## Basic Setup

### 1. Configure Oban

Add Oban configuration to your `config/config.exs`:

```elixir
config :my_app, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  repo: MyApp.Repo,
  queues: [
    # Email queue for AshDispatch
    emails: 10  # Process up to 10 email jobs concurrently
  ]
```

### 2. Add Oban to Supervision Tree

In your `application.ex`, add Oban to your supervision tree:

```elixir
def start(_type, _args) do
  children = [
    MyApp.Repo,
    {Oban, Application.fetch_env!(:my_app, Oban)},
    # ... other children
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

### 3. Run Oban Migrations

Oban requires database tables to track jobs:

```bash
mix ecto.gen.migration add_oban
```

Then add the migration:

```elixir
defmodule MyApp.Repo.Migrations.AddOban do
  use Ecto.Migration

  def up do
    Oban.Migration.up(version: 12)
  end

  def down do
    Oban.Migration.down(version: 1)
  end
end
```

Run migrations:

```bash
mix ecto.migrate
```

## Custom Queue Name

If you want to use a different queue name (e.g., `mailer` instead of `emails`), configure AshDispatch:

```elixir
# config/config.exs
config :ash_dispatch,
  email_queue: :mailer  # Use :mailer queue instead of :emails
```

Then add the queue to your Oban config:

```elixir
config :my_app, Oban,
  queues: [
    mailer: 10  # AshDispatch will use this queue
  ]
```

## Retry Configuration

By default, email jobs retry up to 5 times with exponential backoff. You can customize this:

```elixir
# config/config.exs
config :ash_dispatch,
  max_email_attempts: 3  # Only retry failed emails 3 times
```

## Queue Concurrency

Adjust the concurrency (number of jobs processed in parallel) based on your needs:

```elixir
config :my_app, Oban,
  queues: [
    emails: 20  # Higher concurrency for email-heavy apps
  ]
```

**Guidelines:**
- **Low volume** (< 100 emails/day): `emails: 5`
- **Medium volume** (100-1000 emails/day): `emails: 10`
- **High volume** (> 1000 emails/day): `emails: 20+`

## Scheduled Delivery

AshDispatch supports delayed email delivery via the channel's `time` option:

```elixir
event :welcome,
  channels: [
    [
      transport: :email,
      audience: :user,
      time: {:in, 300}  # Send email in 5 minutes (300 seconds)
    ]
  ]
```

Oban automatically handles the scheduling - no additional configuration needed.

## Production Considerations

### 1. Use Postgres Notifier

Always use `Oban.Notifiers.Postgres` in production for reliable job distribution:

```elixir
# config/prod.exs
config :my_app, Oban,
  notifier: Oban.Notifiers.Postgres  # Required for multi-node deployments
```

### 2. Enable Plugins

Add recommended Oban plugins for production:

```elixir
config :my_app, Oban,
  plugins: [
    # Prune completed jobs older than 7 days
    {Oban.Plugins.Pruner, max_age: 604_800},

    # Rescue orphaned jobs
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},

    # Automatic retry of failed deliveries (optional)
    {Oban.Plugins.Cron,
     crontab: [
       # Retry failed email deliveries every 15 minutes
       {"*/15 * * * *", AshDispatch.Workers.RetryFailedDeliveries}
     ]}
  ]
```

### 3. Monitor Job Performance

Use [ObanWeb](https://hexdocs.pm/oban_web) for monitoring:

```elixir
# mix.exs
defp deps do
  [
    {:oban_web, "~> 2.0"}
  ]
end
```

Add to your router:

```elixir
# lib/my_app_web/router.ex
scope "/" do
  pipe_through :browser
  forward "/oban", ObanWeb.Router
end
```

## Testing

### Disable Oban in Tests

To avoid async job processing in tests:

```elixir
# config/test.exs
config :my_app, Oban,
  testing: :inline  # Jobs execute synchronously in tests
```

Or use manual testing mode:

```elixir
config :my_app, Oban,
  testing: :manual  # Jobs are enqueued but not executed
```

### Assert Jobs Enqueued

Test that jobs are enqueued correctly:

```elixir
use Oban.Testing, repo: MyApp.Repo

test "email job is enqueued" do
  # Trigger event that sends email
  product
  |> Ash.Changeset.for_create(:create, %{name: "Widget"})
  |> Ash.create!()

  # Assert job was enqueued
  assert_enqueued worker: AshDispatch.Workers.SendEmail,
                  args: %{
                    "receipt_id" => receipt.id,
                    "recipient_email" => "user@example.com"
                  }
end
```

### Execute Jobs Manually

In manual testing mode, execute jobs explicitly:

```elixir
test "email is sent" do
  # Trigger event
  create_product()

  # Find enqueued job
  job = Enum.at(all_enqueued(worker: AshDispatch.Workers.SendEmail), 0)

  # Execute job
  perform_job(AshDispatch.Workers.SendEmail, job.args)

  # Assert receipt was marked as sent
  receipt = Ash.get!(DeliveryReceipt, job.args["receipt_id"])
  assert receipt.status == :sent
end
```

## Troubleshooting

### Jobs Not Processing

**Problem:** Jobs enqueued but never execute.

**Solutions:**
1. Check Oban is started: `Oban.config()`
2. Verify queue exists: `config :my_app, Oban, queues: [emails: 10]`
3. Check queue is running: Visit `/oban` dashboard

### High Job Failure Rate

**Problem:** Many jobs failing with errors.

**Solutions:**
1. Check email backend configuration
2. Verify DeliveryReceipt records exist
3. Review logs for error patterns
4. Increase `max_attempts` if transient errors

### Memory Issues

**Problem:** Oban consuming too much memory.

**Solutions:**
1. Reduce queue concurrency
2. Enable pruner plugin to remove old jobs
3. Limit job retention time

## Next Steps

- [Getting Started](../tutorials/getting-started.md) - Set up your first event
- [Configuration](configuration.md) - Complete configuration reference
