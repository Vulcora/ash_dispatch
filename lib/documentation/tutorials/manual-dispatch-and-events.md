# Manual Dispatch and Event Modules

This guide covers **standalone event modules**, **manual triggers**, and the **two-path pattern** for previews vs. actual sending.

## Table of Contents

1. [Understanding Event Modules](#understanding-event-modules)
2. [When to Use Event Modules vs. Inline Events](#when-to-use-event-modules-vs-inline-events)
3. [The Two-Path Pattern](#the-two-path-pattern)
   - [Single Source of Truth Principle](#single-source-of-truth-principle)
4. [Setting Up Manual Triggers](#setting-up-manual-triggers)
5. [Complete Example: Password Reset](#complete-example-password-reset)
6. [Integration with Existing Systems](#integration-with-existing-systems)
7. [Troubleshooting](#troubleshooting)

---

## Understanding Event Modules

While the [Getting Started Guide](./getting-started.md) focuses on **inline events** (defined directly in the `dispatch` DSL), many real-world scenarios require **standalone event modules** that implement the `AshDispatch.Event` behaviour.

### Why Use Event Modules?

Event modules are essential when you need:

- **Custom email templates** (HTML and text versions)
- **Manual triggering** (admin sending password resets, invitations, etc.)
- **Preview functionality** (show what the email will look like before sending)
- **Complex recipient logic** (dynamic recipients based on context)
- **Reusable events** (same event triggered from multiple places)
- **Two-path data** (sample data for previews, real data for sending)

### Event Module Structure

```elixir
defmodule MyApp.Accounts.Events.PasswordReset.Event do
  @moduledoc """
  Event dispatched when a user requests to reset their password.
  """

  use AshDispatch.Event

  alias AshDispatch.Channel
  alias MyApp.Accounts.User

  # Required callbacks
  @impl true
  def id, do: "accounts.password_reset"

  @impl true
  def resource, do: MyApp.Accounts.User

  @impl true
  def data_key, do: :user

  @impl true
  def channels(_context) do
    [
      %Channel{transport: :email, audience: :user, time: {:in, 0}}
    ]
  end

  @impl true
  def recipients(context, _channel) do
    user = context.data.user
    [%{id: user.id, email: user.email, display_name: User.display_name(user)}]
  end

  # Email template callbacks
  @impl true
  def subject(_context, _channel), do: "Reset Your Password"

  @impl true
  def from(_context, _channel), do: {"MyApp", "noreply@myapp.com"}

  @impl true
  def prepare_template_assigns(context, _channel) do
    assigns = AshDispatch.Context.template_assigns(context)
    user = assigns.user
    token = Map.get(assigns, :reset_token) || "sample-reset-token-xyz123"

    %{
      display_name: User.display_name(user),
      reset_url: MyApp.UrlBuilder.build(:password_reset, token: token),
      expiry_hours: 24
    }
  end

  # Preview support - sample data for testing
  @impl true
  def sample_data do
    %{user: MyApp.Factory.build(:user)}
  end

  # Real sending - generate actual tokens
  @impl true
  def generate_send_variables(context, opts) do
    user = context.data[:user]

    if user && not Map.has_key?(opts, :reset_token) do
      case generate_password_reset_token(user) do
        {:ok, token} ->
          {:ok, Map.put(opts, :reset_token, token)}

        {:error, reason} ->
          # SECURITY: Fail dispatch - never send sample tokens!
          {:error, "Token generation failed: #{inspect(reason)}"}
      end
    else
      {:ok, opts}
    end
  end

  defp generate_password_reset_token(user) do
    case AshAuthentication.Jwt.token_for_user(user,
           purpose: :password_reset,
           token_lifetime: {24, :hours}
         ) do
      {:ok, token, _claims} -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :token_generation_failed}
  end
end
```

### Templates Directory Structure

Event modules use **co-located templates**:

```
lib/my_app/accounts/events/password_reset/
├── event.ex                     # Event module
└── templates/
    ├── email.html.heex         # HTML email template
    └── email.text.eex          # Plain text email template
```

**Example HTML template:**

```heex
<!-- email.html.heex -->
<h1>Reset Your Password</h1>

<p>Hi <%= @display_name %>,</p>

<p>You requested to reset your password. Click the button below to create a new password:</p>

<p>
  <a href="<%= @reset_url %>"
     style="display: inline-block; padding: 12px 24px; background: #007bff; color: white; text-decoration: none; border-radius: 4px;">
    Reset Password
  </a>
</p>

<p>This link expires in <%= @expiry_hours %> hours.</p>

<p>If you didn't request this, you can safely ignore this email.</p>
```

**Example text template:**

```eex
<!-- email.text.eex -->
Reset Your Password

Hi <%= @display_name %>,

You requested to reset your password. Click the link below to create a new password:

<%= @reset_url %>

This link expires in <%= @expiry_hours %> hours.

If you didn't request this, you can safely ignore this email.
```

---

## When to Use Event Modules vs. Inline Events

### Use Inline Events When:

✅ **Simple notifications** with no custom templates
✅ **Variable interpolation is enough** (`{{user_name}}`, `{{ticket_id}}`)
✅ **No preview needed** (just fire-and-forget)
✅ **Single trigger point** (one action dispatches the event)

**Example:**

```elixir
dispatch do
  event :ticket_created,
    trigger_on: :create,
    channels: [[transport: :in_app, audience: :user]],
    content: [
      notification_title: "Ticket Created",
      notification_message: "Your ticket #{{id}} has been created"
    ]
end
```

### Use Event Modules When:

✅ **Custom email templates** required (HTML + text)
✅ **Manual triggering** by admins
✅ **Preview functionality** needed
✅ **Complex logic** (dynamic recipients, conditional channels)
✅ **Integration with external systems** (password reset, invitations, etc.)
✅ **Reusability** (same event from multiple places)

**Example:**

```elixir
dispatch do
  event :password_reset,
    trigger_on: :request_password_reset,
    module: MyApp.Accounts.Events.PasswordReset.Event
end
```

---

## The Two-Path Pattern

One of the most important concepts in AshDispatch event modules is the **two-path pattern** for data handling:

1. **Preview Path** - Uses `sample_data()` to generate fake data for testing/previewing
2. **Send Path** - Uses `generate_send_variables()` to generate real data for actual dispatch

### Why Two Paths?

Consider password reset emails:

- **Preview:** You want to see what the email looks like WITHOUT generating a real password reset token
- **Sending:** You need a real, secure JWT token that actually works

The same applies to:
- **Invitations:** Preview with fake invite code, send with real unique code
- **Order confirmations:** Preview with sample order, send with real order data
- **Magic links:** Preview with fake link, send with real secure link

### How It Works

```elixir
defmodule MyApp.Events.PasswordReset do
  use AshDispatch.Event

  # 1. PREVIEW PATH: Provide sample data for testing
  @impl true
  def sample_data do
    %{
      user: MyApp.Factory.build(:user, %{
        email: "alice@example.com",
        name: "Alice Smith"
      })
    }
  end

  # 2. TEMPLATE PREPARATION: Use whatever data is available
  @impl true
  def prepare_template_assigns(context, _channel) do
    assigns = AshDispatch.Context.template_assigns(context)

    user = assigns.user
    # Use real token if available, otherwise fall back to sample
    token = Map.get(assigns, :reset_token) || "sample-reset-token-xyz123"

    %{
      display_name: User.display_name(user),
      reset_url: MyApp.UrlBuilder.build(:password_reset, token: token),
      expiry_hours: 24
    }
  end

  # 3. SEND PATH: Generate real data when actually sending
  @impl true
  def generate_send_variables(context, opts) do
    user = context.data[:user]

    # Only generate if not already provided
    if user && not Map.has_key?(opts, :reset_token) do
      case AshAuthentication.Jwt.token_for_user(user,
             purpose: :password_reset,
             token_lifetime: {24, :hours}
           ) do
        {:ok, token, _claims} ->
          {:ok, Map.put(opts, :reset_token, token)}

        {:error, reason} ->
          # SECURITY: Fail dispatch instead of sending sample token!
          {:error, "Token generation failed: #{inspect(reason)}"}
      end
    else
      {:ok, opts}
    end
  end
end
```

### When Each Path Is Used

| Scenario | Path Used | Data Source |
|----------|-----------|-------------|
| **Admin previewing event** | Preview | `sample_data()` → fake data |
| **Manual trigger preview** | Preview | `sample_data()` → fake data |
| **Manual trigger send** | Send | User-selected data + `generate_send_variables()` |
| **Normal action dispatch** | Send | Action data + `generate_send_variables()` |

### Flow Diagrams

**Preview Flow:**
```
User clicks "Preview"
  → Event.sample_data() generates fake user
  → Event.prepare_template_assigns() uses sample token
  → Template renders with fake data
  → Admin sees preview (no real token generated)
```

**Manual Trigger Flow:**
```
Admin selects user + clicks "Send"
  → User data loaded from database
  → Event.generate_send_variables() creates REAL token
  → Event.prepare_template_assigns() uses real token
  → Email sends with working reset link
  → DeliveryReceipt created for tracking
```

**Normal Action Flow:**
```
User requests password reset (calls action)
  → AshAuthentication strategy generates token
  → Sender dispatches event with token in opts
  → Event.generate_send_variables() skipped (token already present)
  → Event.prepare_template_assigns() uses provided token
  → Email sends with token from strategy
```

### Single Source of Truth Principle

**IMPORTANT:** The event module should be the **single source of truth** for event-specific logic like token generation.

**Why this matters:**

When building systems with multiple entry points (RPC actions, AshAuthentication routes, manual triggers), it's tempting to duplicate token generation logic in each entry point. This creates confusion:

- Developers don't know which code actually runs
- Token formats may diverge between entry points
- Security vulnerabilities slip through when one path is forgotten
- Testing becomes fragmented

**The correct pattern:**

```
┌──────────────────────┐     ┌──────────────────────┐
│  RPC Action          │     │  AshAuthentication   │
│  (custom endpoint)   │     │  (built-in routes)   │
└─────────┬────────────┘     └─────────┬────────────┘
          │                            │
          │    dispatch event          │    dispatch event
          │    (no token)              │    (with token)
          ▼                            ▼
┌───────────────────────────────────────────────────────┐
│                    Event Module                       │
│  ┌─────────────────────────────────────────────────┐  │
│  │  generate_send_variables/2                      │  │
│  │  - If token missing → generate it               │  │
│  │  - If token provided → use it                   │  │
│  │  - Single place for token generation logic!     │  │
│  └─────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────┘
```

**Benefits:**
- **One place to maintain** token generation logic
- **Works for all entry points** (RPC, AshAuth, manual triggers)
- **Testable** - test the event module once, covers all paths
- **Clear responsibility** - event owns its data requirements

**Anti-pattern to avoid:**

```elixir
# ❌ DON'T: Token generation in multiple places
# In RPC action:
def run(input, _context) do
  token = generate_token(user)  # Duplicated!
  dispatch("password_reset", %{user: user}, %{token: token})
end

# In sender:
def send(user, nil, _opts) do
  token = generate_token(user)  # Duplicated again!
  dispatch("password_reset", %{user: user}, %{token: token})
end

# ✅ DO: Centralize in event module
# In RPC action:
def run(input, _context) do
  dispatch("password_reset", %{user: user})  # Event generates token
end

# In sender:
def send(user, token, _opts) do
  opts = if token, do: %{token: token}, else: %{}
  dispatch("password_reset", %{user: user}, opts)  # Event generates if missing
end
```

---

## Setting Up Manual Triggers

Manual triggers allow admins to manually send events (password resets, invitations, etc.) from the admin panel.

### 1. Add Manual Trigger Resource

AshDispatch provides a base resource for manual triggers:

```elixir
defmodule MyApp.Deliveries.ManualTrigger do
  @moduledoc """
  Manual trigger resource for admin-initiated events.
  """

  use AshDispatch.Resources.ManualTrigger.Base,
    domain: MyApp.Deliveries
end
```

### 2. Add to Your Domain

```elixir
defmodule MyApp.Deliveries do
  use Ash.Domain

  resources do
    resource MyApp.Deliveries.DeliveryReceipt
    resource MyApp.Deliveries.ManualTrigger  # Add this
  end
end
```

### 3. Configure Event Discovery

AshDispatch automatically discovers event modules at compile time. Ensure your event modules are compiled before the dispatcher:

```elixir
# config/config.exs
config :ash_dispatch,
  otp_app: :my_app,
  event_modules: []  # Auto-discovered at compile time
```

Event modules are discovered by looking for modules that:
- Implement the `AshDispatch.Event` behaviour
- Define an `id/0` callback

### 4. Use Manual Triggers in Your Admin UI

**Backend (Ash RPC):**

```elixir
# The ManualTrigger resource provides these actions:
# - :list_available_events - Returns all registered events
# - :preview - Preview event with sample data
# - :preview_for_resource - Preview event with real resource data
# - :trigger - Actually send the event
```

**Frontend (React/Next.js example):**

```tsx
import { executeRpc } from '@/lib/ash_rpc'

// 1. List available events
const { data: events } = useQuery({
  queryKey: ['manual-trigger-events'],
  queryFn: () => executeRpc('Magasin.Deliveries.ManualTrigger', 'list_available_events', {}),
})

// 2. Preview an event
const previewEvent = async (eventId: string, userId: string) => {
  const result = await executeRpc(
    'Magasin.Deliveries.ManualTrigger',
    'preview_for_resource',
    {
      event_id: eventId,
      context_data: { user_id: userId },
    }
  )

  return {
    subject: result.subject,
    html_preview: result.html_preview,
    text_preview: result.text_preview,
  }
}

// 3. Send the event
const sendEvent = async (eventId: string, userId: string) => {
  const result = await executeRpc(
    'Magasin.Deliveries.ManualTrigger',
    'trigger',
    {
      event_id: eventId,
      context_data: { user_id: userId },
      opts: {
        channels: [{ transport: 'email', audience: 'user' }],
      },
    }
  )

  // Redirect to delivery receipt
  if (result.deliveryReceiptIds && result.deliveryReceiptIds.length > 0) {
    router.push(`/admin/delivery-receipts/${result.deliveryReceiptIds[0]}`)
  }
}
```

### 5. Example Admin UI Component

```tsx
export default function SendEmailPage({ userId }: { userId: string }) {
  const [selectedEvent, setSelectedEvent] = useState<string>('')
  const [preview, setPreview] = useState<{ subject: string; html: string } | null>(null)

  // Fetch available events
  const { data: events } = useQuery({
    queryKey: ['manual-trigger-events'],
    queryFn: () => executeRpc('MyApp.Deliveries.ManualTrigger', 'list_available_events', {}),
  })

  // Preview event
  const { mutate: previewEvent } = useMutation({
    mutationFn: async (eventId: string) => {
      return executeRpc('MyApp.Deliveries.ManualTrigger', 'preview_for_resource', {
        event_id: eventId,
        context_data: { user_id: userId },
      })
    },
    onSuccess: (data) => {
      setPreview({ subject: data.subject, html: data.html_preview })
    },
  })

  // Send event
  const { mutate: sendEvent } = useMutation({
    mutationFn: async (eventId: string) => {
      return executeRpc('MyApp.Deliveries.ManualTrigger', 'trigger', {
        event_id: eventId,
        context_data: { user_id: userId },
        opts: { channels: [{ transport: 'email', audience: 'user' }] },
      })
    },
    onSuccess: (data) => {
      toast.success('Email sent!')
      if (data.deliveryReceiptIds?.[0]) {
        router.push(`/admin/delivery-receipts/${data.deliveryReceiptIds[0]}`)
      }
    },
  })

  return (
    <div>
      {/* Event selector */}
      <select onChange={(e) => {
        setSelectedEvent(e.target.value)
        previewEvent(e.target.value)
      }}>
        {events?.map((event) => (
          <option key={event.id} value={event.id}>
            {event.name}
          </option>
        ))}
      </select>

      {/* Preview */}
      {preview && (
        <div>
          <h3>Preview: {preview.subject}</h3>
          <iframe srcDoc={preview.html} />
        </div>
      )}

      {/* Send button */}
      <button onClick={() => sendEvent(selectedEvent)}>
        Send Email
      </button>
    </div>
  )
}
```

---

## Complete Example: Password Reset

Let's walk through a complete password reset implementation showing both normal flow and manual triggers.

### 1. Event Module

```elixir
defmodule MyApp.Accounts.Events.PasswordReset.Event do
  @moduledoc """
  Event dispatched when a user requests to reset their password.

  ## Two-Path Pattern

  This event demonstrates the two-path pattern:

  **Preview Path:**
  - Uses `sample_data/0` to generate a fake user
  - `prepare_template_assigns/2` falls back to sample token
  - Admin can preview email without generating real token

  **Send Path:**
  - Normal flow: AshAuthentication strategy provides token
  - Manual trigger: `generate_send_variables/2` creates real token
  - `prepare_template_assigns/2` uses real token from opts
  """

  use AshDispatch.Event

  alias AshDispatch.Channel
  alias MyApp.Accounts.User

  # ============================================================================
  # Required Callbacks
  # ============================================================================

  @impl true
  def id, do: "accounts.password_reset"

  @impl true
  def resource, do: MyApp.Accounts.User

  @impl true
  def data_key, do: :user

  @impl true
  def channels(_context) do
    [
      # Immediate email with reset link (critical for security)
      %Channel{transport: :email, audience: :user, time: {:in, 0}}
    ]
  end

  # ============================================================================
  # Domain Metadata
  # ============================================================================

  @impl true
  def domain, do: :accounts

  @impl true
  def category(_context), do: nil

  @impl true
  def action_required?(_context), do: true

  @impl true
  def user_configurable?(_context), do: false  # Always send (security)

  # ============================================================================
  # Recipient Resolution
  # ============================================================================

  @impl true
  def recipients(context, _channel) do
    user = context.data.user

    [
      %{
        id: user.id,
        email: extract_email(user),
        display_name: User.display_name(user)
      }
    ]
  end

  # ============================================================================
  # Email Template Callbacks
  # ============================================================================

  @impl true
  def subject(_context, _channel), do: "Reset Your Password"

  @impl true
  def from(_context, _channel), do: {"MyApp", "noreply@myapp.com"}

  @impl true
  def prepare_template_assigns(context, _channel) do
    # Get both data and variables (includes :reset_token if provided)
    assigns = AshDispatch.Context.template_assigns(context)

    user = assigns.user
    # Use real token if available, otherwise use sample token for preview
    token = Map.get(assigns, :reset_token) || "sample-reset-token-xyz123"

    %{
      display_name: User.display_name(user),
      reset_url: MyApp.UrlBuilder.build(:password_reset, token: token),
      expiry_hours: 24
    }
  end

  @impl true
  def template_variant(_context, _channel), do: nil

  # ============================================================================
  # In-App Notification Callbacks
  # (Not used for email-only events, but required by behaviour)
  # ============================================================================

  @impl true
  def notification_title(_context, _channel), do: "Reset Your Password"

  @impl true
  def notification_message(context, _channel) do
    user = context.data.user
    email = extract_email(user)
    "A password reset link for #{email} has been sent"
  end

  @impl true
  def notification_type(_context), do: :info

  @impl true
  def action_url(context, _channel) do
    token = Map.get(context.metadata, :reset_token)

    if token do
      MyApp.UrlBuilder.build(:password_reset, token: token)
    else
      nil
    end
  end

  @impl true
  def action_label(_context, _channel), do: "Reset Password"

  # ============================================================================
  # Two-Path Pattern: Preview Support
  # ============================================================================

  @impl true
  def sample_data do
    %{
      user: MyApp.Factory.build(MyApp.Accounts.User)
    }
  end

  # ============================================================================
  # Two-Path Pattern: Real Sending
  # ============================================================================

  @impl true
  def generate_send_variables(context, opts) do
    user = context.data[:user]

    # Only generate token if not already provided (by AshAuthentication strategy)
    if user && not Map.has_key?(opts, :reset_token) do
      case generate_password_reset_token(user) do
        {:ok, token} ->
          {:ok, Map.put(opts, :reset_token, token)}

        {:error, reason} ->
          # SECURITY: Fail the dispatch - never send emails with sample tokens!
          {:error, "Failed to generate password reset token: #{inspect(reason)}"}
      end
    else
      {:ok, opts}
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  # Generate a real password reset token using AshAuthentication
  defp generate_password_reset_token(user) do
    case AshAuthentication.Jwt.token_for_user(user,
           purpose: :password_reset,
           token_lifetime: {24, :hours}
         ) do
      {:ok, token, _claims} -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :token_generation_failed}
  end

  defp extract_email(%{email: %{string: email}}) when is_binary(email), do: email
  defp extract_email(%{email: email}) when is_binary(email), do: email
  defp extract_email(_), do: nil
end
```

### 2. Templates

**HTML Template** (`templates/email.html.heex`):

```heex
<h1>Reset Your Password</h1>

<p>Hi <%= @display_name %>,</p>

<p>You requested to reset your password. Click the button below to create a new password:</p>

<p style="margin: 24px 0;">
  <a href="<%= @reset_url %>"
     style="display: inline-block; padding: 12px 24px; background: #007bff; color: white; text-decoration: none; border-radius: 4px; font-weight: 600;">
    Reset Password
  </a>
</p>

<p>This link expires in <strong><%= @expiry_hours %> hours</strong>.</p>

<p style="margin-top: 24px; color: #666; font-size: 14px;">
  If you didn't request this, you can safely ignore this email.
  Your password will not be changed.
</p>
```

**Text Template** (`templates/email.text.eex`):

```eex
Reset Your Password

Hi <%= @display_name %>,

You requested to reset your password. Click the link below to create a new password:

<%= @reset_url %>

This link expires in <%= @expiry_hours %> hours.

If you didn't request this, you can safely ignore this email. Your password will not be changed.
```

### 3. Resource Integration

```elixir
defmodule MyApp.Accounts.User do
  use Ash.Resource,
    domain: MyApp.Accounts,
    extensions: [
      AshAuthentication,
      AshAuthentication.PasswordReset,
      AshDispatch.Resource  # Add dispatch support
    ]

  authentication do
    strategies do
      password :password do
        identity_field :email

        resettable do
          sender MyApp.Accounts.User.Senders.SendPasswordResetEmail
        end
      end
    end
  end

  # Dispatch events
  dispatch do
    event :password_reset,
      trigger_on: :request_password_reset_token,
      module: MyApp.Accounts.Events.PasswordReset.Event
  end
end
```

### 4. Sender Integration

```elixir
defmodule MyApp.Accounts.User.Senders.SendPasswordResetEmail do
  @moduledoc """
  Sends a password reset email using the unified event dispatcher.
  """

  use AshAuthentication.Sender

  @impl true
  def send(user, token, _opts) do
    # Dispatch event using unified system
    # Token provided by AshAuthentication strategy
    result =
      AshDispatch.Dispatcher.dispatch(
        "accounts.password_reset",
        %{user: user},
        %{reset_token: token}  # Strategy provides token here
      )

    case result do
      {:ok, _receipts} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
```

### 5. Usage Examples

**Normal User Flow:**
```elixir
# User requests password reset via form
{:ok, _user} = User
  |> Ash.Changeset.for_action(:request_password_reset_token, %{email: "alice@example.com"})
  |> Ash.update()

# What happens:
# 1. AshAuthentication strategy generates JWT token
# 2. Strategy calls SendPasswordResetEmail.send(user, token, opts)
# 3. Sender dispatches "accounts.password_reset" event with token in opts
# 4. generate_send_variables/2 sees token already present, skips generation
# 5. prepare_template_assigns/2 uses real token from opts
# 6. Email sent with working reset link
```

**Admin Manual Trigger:**
```elixir
# Admin previews email for user
{:ok, preview} = ManualTrigger
  |> Ash.Changeset.for_action(:preview_for_resource, %{
    event_id: "accounts.password_reset",
    context_data: %{user_id: user.id}
  })
  |> Ash.create()

# What happens:
# 1. Event module NOT used - context_data provides user
# 2. generate_send_variables/2 NOT called (preview mode)
# 3. prepare_template_assigns/2 uses sample token
# 4. Returns HTML/text preview

# Admin sends actual email
{:ok, trigger} = ManualTrigger
  |> Ash.Changeset.for_action(:trigger, %{
    event_id: "accounts.password_reset",
    context_data: %{user_id: user.id},
    opts: %{channels: [%{transport: :email, audience: :user}]}
  })
  |> Ash.create()

# What happens:
# 1. User loaded from context_data
# 2. generate_send_variables/2 CALLED - generates real JWT token
# 3. prepare_template_assigns/2 uses real token
# 4. Email sent with working reset link
# 5. DeliveryReceipt created
# 6. Returns trigger.delivery_receipt_ids for redirect
```

---

## Integration with Existing Systems

### AshAuthentication Integration

When integrating with AshAuthentication (password reset, email confirmation, magic links), you have two entry points:

**Entry Point 1: Normal Action Flow**
```
User action
  → AshAuthentication strategy
  → Strategy generates token
  → Strategy calls Sender.send(user, token, opts)
  → Sender dispatches event WITH token in opts
  → Event skips generate_send_variables (token present)
  → Email sent with strategy token
```

**Entry Point 2: Manual Trigger**
```
Admin clicks send
  → Manual trigger loads user
  → Event.generate_send_variables generates token
  → Email sent with event-generated token
```

Both use the same underlying token generation (`AshAuthentication.Jwt.token_for_user`), just different entry points.

### Factory Integration for Previews

Use `Smokestack` or similar factory libraries to generate sample data:

```elixir
# lib/my_app/factory.ex
defmodule MyApp.Factory do
  use Smokestack

  factory User do
    attribute :email, &Faker.Internet.email/0
    attribute :name, &Faker.Person.name/0
    attribute :id, &Ash.UUID.generate/0
  end
end

# In your event module
def sample_data do
  %{
    user: MyApp.Factory.build(User, %{
      email: "alice@example.com",
      name: "Alice Smith"
    })
  }
end
```

---

## Troubleshooting

### Sample tokens showing in sent emails

**Problem:** You see `"sample-reset-token-xyz123"` in emails sent via manual trigger.

**Cause:** `generate_send_variables/2` not implemented or not working.

**Solution:**
1. Implement `generate_send_variables/2` callback with proper return types
2. Return `{:error, reason}` on failure - NEVER fall back to sample tokens
3. Check logs for token generation errors

```elixir
@impl true
def generate_send_variables(context, opts) do
  user = context.data[:user]

  if user && not Map.has_key?(opts, :reset_token) do
    case generate_token(user) do
      {:ok, token} ->
        {:ok, Map.put(opts, :reset_token, token)}

      {:error, reason} ->
        # SECURITY: Fail the dispatch - never send sample tokens!
        Logger.error("Token generation failed: #{inspect(reason)}")
        {:error, "Token generation failed: #{inspect(reason)}"}
    end
  else
    {:ok, opts}
  end
end
```

### Preview shows real data instead of sample

**Problem:** Preview is using production database data.

**Cause:** `sample_data/0` not implemented or returning real records.

**Solution:**
1. Implement `sample_data/0` to return factory-built structs
2. Never call `Ash.read!` or database queries in `sample_data/0`
3. Use factories to build Ash structs with `__meta__` field

```elixir
# ❌ Wrong - queries database
def sample_data do
  %{user: User |> Ash.Query.first() |> Ash.read!()}
end

# ✅ Correct - uses factory
def sample_data do
  %{user: MyApp.Factory.build(:user)}
end
```

### Manual trigger not generating real tokens

**Problem:** Manual trigger works but uses sample tokens.

**Cause:** `generate_send_variables/2` not being called.

**Solution:**
1. Check that callback is exported: `function_exported?(YourEvent, :generate_send_variables, 2)`
2. Ensure manual trigger helpers are up to date
3. Add logging to verify callback is called

```elixir
@impl true
def generate_send_variables(context, opts) do
  require Logger
  Logger.info("generate_send_variables called for #{context.event_id}")

  # Your implementation must return {:ok, opts} or {:error, reason}
  case generate_your_token() do
    {:ok, token} -> {:ok, Map.put(opts, :my_token, token)}
    {:error, reason} -> {:error, reason}
  end
end
```

### Subject not showing in preview

**Problem:** Email preview shows content but subject is missing.

**Cause:** Subject not being passed to template layout.

**Solution:** This is handled internally by the dispatcher. If you see this issue:
1. Ensure `subject/2` callback returns a string
2. Check that layout template uses `@subject` variable
3. Verify dispatcher is computing subject before rendering

```elixir
@impl true
def subject(_context, _channel) do
  "Your Subject Here"  # Must return string, not nil
end
```

### Delivery receipt not found after sending

**Problem:** Manual trigger succeeds but `delivery_receipt_ids` is empty.

**Cause:** Dispatcher not returning receipt IDs correctly.

**Solution:**
1. Check that dispatcher returns `{:ok, receipts}` tuple
2. Ensure manual trigger action extracts IDs from results
3. Verify receipt IDs are being stored in `delivery_receipt_ids` attribute

---

## Summary

### Key Takeaways

1. **Event modules** provide full control over email templates, recipient logic, and multi-channel dispatch
2. **Two-path pattern** enables safe previews without generating real tokens/data
3. **Single source of truth** - keep token generation in `generate_send_variables/2`, not scattered across actions
4. **Manual triggers** let admins send events on-demand with real data
5. **Integration is seamless** - same event works for normal actions AND manual triggers
6. **Factories enable testing** - generate sample data without database queries

### Quick Reference

| Callback | Purpose | Returns | Used In |
|----------|---------|---------|---------|
| `sample_data/0` | Generate fake data for previews | `map()` | Preview mode only |
| `generate_send_variables/2` | Generate real tokens/data | `{:ok, map}` or `{:error, reason}` | Send mode (manual + normal) |
| `prepare_template_assigns/2` | Convert context to template assigns | `map()` | Always (preview + send) |
| `subject/2` | Email subject line | `String.t()` | Email transports only |
| `recipients/2` | Who receives this event | `list(map)` | All transports |

### Next Steps

- **[Getting Started Guide](./getting-started.md)** - Learn inline events and basic dispatch
- **[User Preferences](../topics/user-preferences.md)** - Let users control notifications
- **[Phoenix Integration](../topics/phoenix-integration.md)** - Real-time channel integration

---

**Need help?** [Open an issue](https://github.com/magasin/ash_dispatch/issues) or join the [Ash community](https://ash-hq.org).
