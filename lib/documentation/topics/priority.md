# Priority Levels

Events can declare a delivery priority that flows through the entire dispatch pipeline, enabling consumers to make context-aware delivery decisions.

## DSL Usage

```elixir
dispatch do
  # Urgent: bypass timing constraints, always deliver immediately
  event :budget_alert,
    trigger_on: :manual,
    priority: :urgent,
    channels: [[transport: :in_app, audience: :user]]

  # Standard: deliver at next appropriate opportunity (default)
  event :task_completed,
    trigger_on: :complete,
    priority: :standard,
    channels: [[transport: :in_app, audience: :user]]

  # Informational: low priority, can be batched or held for summaries
  event :habit_logged,
    trigger_on: :manual,
    priority: :informational,
    channels: [[transport: :in_app, audience: :user]]
end
```

If `priority` is not specified, it defaults to `:standard`.

## Priority Values

| Priority | Use Case | Example Events |
|----------|----------|---------------|
| `:urgent` | Must deliver immediately regardless of context | Billing alerts, security warnings, system failures |
| `:standard` | Deliver at next appropriate opportunity | Task completions, goal achievements, assignment changes |
| `:informational` | Low priority, can be batched or deferred | Habit streaks, pattern detections, weekly summaries |

## Pipeline Flow

Priority is set at the **event level** (not per-channel) because an event's urgency is inherent to what happened, not how it's delivered.

```
Event DSL (priority: :urgent)
  → InjectDispatchChanges transformer (stores in event_config)
    → DispatchEvent change (sets context.priority)
      → InApp transport (stores in notification.metadata["priority"])
      → Email transport (available in context for custom logic)
```

### Where Priority Lives

1. **Event DSL** — `AshDispatch.Resource.Dsl.Event.priority` (compile-time)
2. **Event Config** — `event_config.priority` in the change opts (transformer-injected)
3. **Context** — `%AshDispatch.Context{priority: :urgent}` (runtime, during dispatch)
4. **Notification Metadata** — `notification.metadata["priority"]` (in-app, queryable)

## Consumer Usage

AshDispatch stores priority but does **not enforce delivery rules** — that's the consumer's responsibility. This keeps AshDispatch transport-agnostic while enabling rich delivery logic in consuming apps.

### Example: Active Hours Gating

```elixir
# In your app's notification scheduler:
def should_deliver?(notification, user_context) do
  priority = notification.metadata["priority"] || "standard"

  case priority do
    "urgent" -> true  # Always deliver
    _ -> within_active_hours?(user_context)  # Gate non-urgent
  end
end
```

### Example: Deep Work Suppression

```elixir
# In your prompt builder:
def show_in_prompt?(notification, flow_mode) do
  priority = notification.metadata["priority"] || "standard"

  case {priority, flow_mode} do
    {"urgent", _} -> true        # Urgent always visible
    {_, :deep_work} -> false     # Suppress during deep work
    _ -> true                    # Otherwise show
  end
end
```
