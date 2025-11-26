# AshDispatch Architecture

## Cross-Project References Solution

### Problem
Library code (`ash_dispatch`) needs to reference user records from the consuming application (`magasin`), but compile-time `belongs_to` relationships cause warnings:

```
warning: invalid association `user` in schema AshDispatch.Resources.DeliveryReceipt:
associated schema Magasin.Accounts.User does not exist
```

This happens because during compilation, the library doesn't have access to the consuming app's modules.

### Solution: Calculation-Based Relationships

Instead of compile-time `belongs_to`, we use **Ash calculations** to load users at runtime:

```elixir
# ❌ OLD: Compile-time dependency (causes warnings)
relationships do
  belongs_to :user, Magasin.Accounts.User do
    source_attribute :user_id
    allow_nil? true
  end
end

# ✅ NEW: Runtime calculation (no warnings)
attributes do
  uuid_attribute :user_id, allow_nil?: true
end

calculations do
  calculate :user, :struct, {AshDispatch.Calculations.LoadUser, []} do
    public? true
    description "Associated user (loaded from configured user_resource)"
  end
end
```

### Benefits

1. **Zero compile-time warnings** - No cross-project module dependencies
2. **Same API** - `Ash.Query.load(:user)` works exactly the same
3. **Batch loading** - Efficiently loads multiple users in a single query
4. **Runtime configuration** - Consuming app configures which resource to use
5. **Community standard** - This is the recommended Ash pattern for libraries

### How It Works

#### Configuration (in consuming app)
```elixir
# config/config.exs
config :ash_dispatch,
  user_resource: Magasin.Accounts.User,
  user_domain: Magasin.Accounts
```

#### Usage (identical to belongs_to)
```elixir
# Load user relationship
receipts =
  DeliveryReceipt
  |> Ash.Query.load(:user)
  |> Ash.read!()

# Access user
receipts
|> Enum.each(fn receipt ->
  IO.puts(receipt.user.email)
end)
```

#### Implementation Details

The `LoadUser` calculation:
1. Collects all `user_id` values from the batch of records
2. Performs a single query to load all users: `User |> filter(id in ^user_ids)`
3. Maps users back to their corresponding records
4. Returns nil for records without user_id

This provides the same efficiency as Ecto's preload while avoiding compile-time dependencies.

### Why This Pattern?

This is the **standard Elixir pattern** for library cross-project references:

- **Ecto.Repo** - Configured at runtime, no compile-time module dependency
- **AshAuthentication** - Adds functionality to YOUR resources, not library resources
- **Phoenix PubSub** - Module configured at runtime via application config
- **Swoosh.Mailer** - Adapter configured at runtime

Libraries should **avoid compile-time dependencies** on consuming application modules.

### Alternative Approaches Considered

1. **@compile directive** - Only suppresses warnings, doesn't solve the issue
2. **Code.ensure_loaded?** - Breaks at runtime when module doesn't exist yet
3. **Polymorphic embed** - Less efficient, doesn't leverage Ash's query system
4. **No relationship** - Forces consuming app to manually load, poor DX
5. **Calculation** - ✅ **Best solution**: Clean, efficient, idiomatic

### Migration Guide

If you have existing code using `receipt.user` with belongs_to:

**No changes needed!** The calculation provides the same API:

```elixir
# Before (belongs_to)
receipt
|> Ash.load(:user)

# After (calculation) - SAME!
receipt
|> Ash.load(:user)

# Accessing the user - SAME!
receipt.user.email
```

The only difference is internal implementation. The external API is identical.

### Performance

Calculations with batch loading are **equivalent** to belongs_to performance:

- Single query for multiple records
- Uses Ash's load/preload system
- Respects authorization and policies
- Same memory footprint

### Testing

See [TESTING.md](TESTING.md) for details on the test structure.

Library tests verify the calculation logic, integration tests in the consuming app verify end-to-end behavior.
