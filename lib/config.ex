defmodule AshDispatch.Config do
  @moduledoc """
  Centralized configuration access for AshDispatch.

  This module provides a single source of truth for all configuration values,
  with consistent defaults and clear documentation of each option.

  ## Why This Exists

  Configuration lookups were scattered across 30+ files, each with potentially
  different default values. This module ensures:

  1. **Consistent defaults** - Each config key has one canonical default
  2. **Single source of truth** - Change defaults in one place
  3. **Discoverability** - All config options documented together
  4. **Type safety** - Functions return expected types

  ## Usage

      # Instead of:
      Application.get_env(:ash_dispatch, :user_module)

      # Use:
      AshDispatch.Config.user_module()

  ## Configuration

  All options are configured under the `:ash_dispatch` application:

      config :ash_dispatch,
        user_module: MyApp.Accounts.User,
        domains: [MyApp.Orders, MyApp.Tickets],
        otp_app: :my_app,
        # ... see individual functions for all options
  """

  # ============================================================================
  # Core Resources
  # ============================================================================

  @doc """
  The user module for recipient resolution and preferences.

  Used by:
  - `AshDispatch.Event.Helpers` for recipient resolution
  - `AshDispatch.Dispatcher` for user extraction from context
  - Counter calculations

  ## Example

      config :ash_dispatch,
        user_module: MyApp.Accounts.User
  """
  @spec user_module() :: module() | nil
  def user_module do
    Application.get_env(:ash_dispatch, :user_module)
  end

  @doc """
  The user resource module (alias for user_module for clarity in some contexts).
  """
  @spec user_resource() :: module() | nil
  def user_resource do
    Application.get_env(:ash_dispatch, :user_resource)
  end

  @doc """
  The domain containing the user resource.
  """
  @spec user_domain() :: module() | nil
  def user_domain do
    Application.get_env(:ash_dispatch, :user_domain)
  end

  @doc """
  The delivery receipt resource module.

  Must be configured - returns `nil` if not set.

  ## Example

      config :ash_dispatch,
        delivery_receipt_resource: MyApp.Deliveries.DeliveryReceipt
  """
  @spec delivery_receipt_resource() :: module() | nil
  def delivery_receipt_resource do
    Application.get_env(:ash_dispatch, :delivery_receipt_resource)
  end

  @doc """
  The notification resource module.

  Must be configured - returns `nil` if not set.

  ## Example

      config :ash_dispatch,
        notification_resource: MyApp.Notifications.Notification
  """
  @spec notification_resource() :: module() | nil
  def notification_resource do
    Application.get_env(:ash_dispatch, :notification_resource)
  end

  # ============================================================================
  # Domains & OTP App
  # ============================================================================

  @doc """
  List of Ash domains that have dispatch-enabled resources.

  Used for:
  - Event discovery via DSL introspection
  - Counter loading
  - SDK generation

  ## Example

      config :ash_dispatch,
        domains: [MyApp.Orders, MyApp.Tickets, MyApp.Requests]
  """
  @spec domains() :: [module()]
  def domains do
    Application.get_env(:ash_dispatch, :domains, [])
  end

  @doc """
  The OTP application name.

  Used for:
  - Template resolution
  - Event module discovery
  """
  @spec otp_app() :: atom() | nil
  def otp_app do
    Application.get_env(:ash_dispatch, :otp_app)
  end

  # ============================================================================
  # Localization
  # ============================================================================

  @doc """
  Default locale for template resolution and content.

  Used as the ultimate fallback when no locale is specified. The full locale
  resolution priority is:

  1. Channel-level `locale` (static, e.g., `locale: "sv"`)
  2. Channel-level `locale_from` (dynamic from record field)
  3. Event-level `locale_from` configuration
  4. Resource-level `locale_from` configuration
  5. Auto-detected common fields: `visitor_locale`, `locale`
  6. This config default

  Template resolution then tries locale-specific templates first
  (e.g., `email.sv.html.heex`), falling back to non-localized templates.

  Defaults to `"en"`.

  ## Example

      config :ash_dispatch,
        default_locale: "sv"

  ## See Also

  - `AshDispatch.Resource.Dsl` - Resource-level `locales` configuration
  - `AshDispatch.TemplateResolver` - Template fallback chain
  """
  @spec default_locale() :: String.t()
  def default_locale do
    Application.get_env(:ash_dispatch, :default_locale, "en")
  end

  @doc """
  Optional Gettext backend for translating content strings.

  When configured, all `content:` block strings (notification_title,
  notification_message, etc.) are run through Gettext before variable
  interpolation. The locale is resolved via the dispatch locale chain.

  The content string IS the gettext msgid. Translations are looked up
  in the "notifications" domain.

  ## Example

      config :ash_dispatch,
        gettext_backend: MyAppWeb.Gettext

  Then content strings like `notification_title: "Usage Alert"` will
  be translated via `Gettext.dgettext(MyAppWeb.Gettext, "notifications", "Usage Alert")`.
  """
  @spec gettext_backend() :: module() | nil
  def gettext_backend do
    Application.get_env(:ash_dispatch, :gettext_backend)
  end

  @doc """
  Default Gettext domain used to translate DSL content strings.

  When a channel's `:notification_title`, `:notification_message`,
  `:subject`, etc. is defined as a literal in `dispatch do ... end`,
  `Dispatcher.translate_content/2` looks up the string via
  `Gettext.dgettext(backend, gettext_domain(), msgid)` before variable
  interpolation runs.

  Defaults to `"notifications"` so existing projects keep working.
  Override per app:

      config :ash_dispatch, :gettext_domain, "default"

  Projects that already extract i18n strings to `default.po` (e.g.
  multi-locale Phoenix apps) can consolidate their DSL content
  alongside the rest of their translations.
  """
  @spec gettext_domain() :: String.t()
  def gettext_domain do
    Application.get_env(:ash_dispatch, :gettext_domain, "notifications")
  end

  # ============================================================================
  # Email Configuration
  # ============================================================================

  @doc """
  Default from email address.

  Used when no `from` is specified in event module or inline DSL.

  Defaults to `"noreply@example.com"`.
  """
  @spec default_from_email() :: String.t()
  def default_from_email do
    Application.get_env(:ash_dispatch, :default_from_email, "noreply@example.com")
  end

  @doc """
  Default from name (sender name displayed in email clients).

  Used when no `from` is specified in event module or inline DSL.

  Defaults to the OTP app name (titlecased) or "System" if not configured.

  ## Example

      config :ash_dispatch,
        default_from_name: "Fyndgrossisten"
  """
  @spec default_from_name() :: String.t()
  def default_from_name do
    Application.get_env(:ash_dispatch, :default_from_name) ||
      case otp_app() do
        nil -> "System"
        app -> app |> to_string() |> String.capitalize()
      end
  end

  @doc """
  The email backend module for sending emails.

  Should implement the email backend behaviour.

  ## Example

      config :ash_dispatch,
        email_backend: AshDispatch.EmailBackend.Swoosh
  """
  @spec email_backend() :: module() | nil
  def email_backend do
    Application.get_env(:ash_dispatch, :email_backend)
  end

  @doc """
  The Swoosh mailer module (when using Swoosh backend).
  """
  @spec swoosh_mailer() :: module() | nil
  def swoosh_mailer do
    Application.get_env(:ash_dispatch, :swoosh_mailer)
  end

  @doc """
  The SMS backend module — should implement `AshDispatch.SMSBackend`.
  Returns `nil` when no backend is configured, in which case the SMS
  transport marks receipts `:skipped`.

  ## Example

      config :ash_dispatch,
        sms_backend: MyApp.SMS
  """
  @spec sms_backend() :: module() | nil
  def sms_backend do
    Application.get_env(:ash_dispatch, :sms_backend)
  end

  @doc """
  The Web Push backend module — should implement
  `AshDispatch.PushBackend`. Returns `nil` when no backend is
  configured, in which case the push transport marks receipts
  `:skipped` rather than failing the event.

  ## Example

      config :ash_dispatch,
        push_backend: MyApp.Push
  """
  @spec push_backend() :: module() | nil
  def push_backend do
    Application.get_env(:ash_dispatch, :push_backend)
  end

  # ============================================================================
  # URL Building
  # ============================================================================

  @doc """
  The URL builder module for generating admin/source URLs.

  Should implement `admin_url/2`, `source_url/2`, and optionally `resource_label/1`.
  """
  @spec url_builder() :: module() | nil
  def url_builder do
    Application.get_env(:ash_dispatch, :url_builder)
  end

  @doc """
  The Phoenix endpoint module for URL generation.
  """
  @spec endpoint() :: module() | nil
  def endpoint do
    Application.get_env(:ash_dispatch, :endpoint)
  end

  @doc """
  Base URL for the application (fallback when endpoint not available).
  """
  @spec base_url() :: String.t() | nil
  def base_url do
    Application.get_env(:ash_dispatch, :base_url)
  end

  # ============================================================================
  # Recipients & Audiences
  # ============================================================================

  @doc """
  The recipient resolver module.

  When configured, this module is used for all recipient resolution,
  replacing the legacy `audiences` configuration.

  Should implement `AshDispatch.RecipientResolver` behaviour.

  ## Example

      config :ash_dispatch,
        recipient_resolver: MyApp.RecipientResolver
  """
  @spec recipient_resolver() :: module() | nil
  def recipient_resolver do
    Application.get_env(:ash_dispatch, :recipient_resolver)
  end

  @doc """
  Audience configuration for recipient resolution (legacy).

  Maps audience atoms to filter configurations.

  **Note:** If `recipient_resolver` is configured, this option is ignored.
  Prefer using `recipient_resolver` for new applications.

  ## Example

      config :ash_dispatch,
        audiences: [
          admin: [admin: true],
          user: :user,
          support: [role: :support]
        ]
  """
  @spec audiences() :: keyword()
  def audiences do
    Application.get_env(:ash_dispatch, :audiences, [])
  end

  @doc """
  Recipient field configuration for extracting email/name from user structs.

  ## Example

      config :ash_dispatch,
        recipient_fields: [
          email: [
            default: :email,
            audiences: [admin: :work_email]
          ],
          name: [
            default: :display_name
          ]
        ]

  ## The user id

  A receipt's `user_id` (what preferences and `exclude_actor` compare) is the
  recipient's `:id`. A map recipient that carries its user under another key
  names it with `id:` — generic, per transport, per audience, or per audience
  and transport (since 0.8.8):

      config :ash_dispatch,
        recipient_fields: [
          email: [identifier: :email],
          audiences: [bookers: [id: :user_id]]
        ]

  See `AshDispatch.Event.RecipientExtractor.extract_user_id/4`.
  """
  @spec recipient_fields() :: keyword()
  def recipient_fields do
    Application.get_env(:ash_dispatch, :recipient_fields, [])
  end

  @doc """
  Whether a channel's `exclude_actor: true` also leaves out the `:actor` of a
  manual dispatch (`Dispatcher.dispatch/4`, the ManualTrigger's `:trigger`).

  An action-triggered event always excludes its actor: the action's actor is
  `context.user`. A manual event's `context.user` is whatever user is found
  in `data`; its `:actor` is kept as `context.actor`, and this option makes
  `exclude_actor` leave them out as well.

  **Defaults to `true` since 0.9.0** (it was opt-in in 0.8.8). Set it to
  `false` to keep 0.8.x's behaviour, where a manual dispatch's actor is still
  reached.

  ## Example

      config :ash_dispatch, exclude_actor_on_manual_dispatch: false
  """
  @spec exclude_actor_on_manual_dispatch?() :: boolean()
  def exclude_actor_on_manual_dispatch? do
    Application.get_env(:ash_dispatch, :exclude_actor_on_manual_dispatch, true) != false
  end

  # ============================================================================
  # User Preferences
  # ============================================================================

  @doc """
  The user preference checker module.

  Defaults to `AshDispatch.UserPreference.Default` which allows all notifications.
  """
  @spec user_preference() :: module()
  def user_preference do
    Application.get_env(:ash_dispatch, :user_preference, AshDispatch.UserPreference.Default)
  end

  @doc """
  The notification preference resource read by
  `AshDispatch.UserPreference.Resource` — a resource that uses
  `AshDispatch.Resources.Preference.Base`.

  ## Example

      config :ash_dispatch,
        user_preference: AshDispatch.UserPreference.Resource,
        preference_resource: MyApp.Notifications.Preference
  """
  @spec preference_resource() :: module() | nil
  def preference_resource do
    Application.get_env(:ash_dispatch, :preference_resource)
  end

  @doc """
  The preference provider module (legacy, prefer user_preference).
  """
  @spec preference_provider() :: module() | nil
  def preference_provider do
    Application.get_env(:ash_dispatch, :preference_provider)
  end

  @doc """
  Audiences whose deliveries are gated by the user preference checker.

  A channel is preference-gated when its audience is in this list: the
  transport asks `AshDispatch.UserPreference.allows_user?/4` for the
  RECIPIENT of the receipt before delivering, and marks the receipt
  `:skipped` ("user_opted_out") when the answer is `false`.

  Defaults to `[:user]`, which is exactly the behaviour of every release
  before 0.6.4 — only the `:user` audience was ever gated, and every
  app-defined audience (`:customers`, `:watchers`, permission-scoped
  admin audiences) bypassed preferences entirely.

  Apps that fan a marketing-style event out to an audience of their own
  can now gate it too:

      config :ash_dispatch,
        preference_gated_audiences: [:user, :customers]

  Only add audiences whose recipients are end users with preferences.
  Admin/team/system audiences should stay ungated — an operator must not
  be able to silence an operational alert by unticking a marketing box.
  """
  @spec preference_gated_audiences() :: [atom()]
  def preference_gated_audiences do
    Application.get_env(:ash_dispatch, :preference_gated_audiences, [:user])
  end

  @doc """
  The host's check for whether a recipient may be reached at all — a closed
  account, a barred user, an unverified address.

  A module implementing `AshDispatch.EligibleRecipient`, `{module, function}`,
  `{module, function, extra_args}`, or a two-argument function. `nil` (the
  default) asks nothing.

  Unlike a preference, this applies to mandatory events too. See
  `AshDispatch.EligibleRecipient`.

  ## Example

      config :ash_dispatch,
        eligible_recipient: MyApp.Notifications.Eligibility
  """
  @spec eligible_recipient() ::
          module() | {module(), atom()} | {module(), atom(), list()} | fun() | nil
  def eligible_recipient do
    Application.get_env(:ash_dispatch, :eligible_recipient)
  end

  # ============================================================================
  # Integrations
  # ============================================================================

  @doc """
  The PubSub module for broadcasting notifications.

  ## Contract

  Must be an **endpoint-shaped** module exposing both:

  - `subscribe(topic)` — for server-side consumers (e.g.
    `Mosis.Dispatch.Subscriber` or any GenServer that reacts to
    AshDispatch broadcasts in-process)
  - `broadcast(topic, event, payload)` — used by
    `AshDispatch.Transports.Broadcast` to publish to user / admin
    channels and by `Transports.InApp` for new-notification pushes

  Phoenix endpoints generate both functions automatically — set this
  to your application's endpoint module:

      config :ash_dispatch, pubsub_module: MyAppWeb.Endpoint

  **Do NOT set this to a bare `Phoenix.PubSub` registered name** (e.g.
  `MyApp.PubSub`). Those expose `Phoenix.PubSub.subscribe/2` (arity 2)
  and `Phoenix.PubSub.broadcast/3` as functions on the `Phoenix.PubSub`
  module itself, not on the registered-name atom — and consumers that
  call `pubsub.subscribe(topic)` or `pubsub.broadcast(topic, …)`
  directly would fail with `UndefinedFunctionError`.
  """
  @spec pubsub_module() :: module() | nil
  def pubsub_module do
    Application.get_env(:ash_dispatch, :pubsub_module)
  end

  @doc """
  The Phoenix channel topic prefix for user channels.

  Defaults to `"user"` which creates topics like `"user:user_id"`.
  Configure to match your channel setup, e.g., `"inbox"` for `"inbox:user_id"`.

  ## Example

      config :ash_dispatch,
        channel_topic: "inbox"
  """
  @spec channel_topic() :: String.t()
  def channel_topic do
    Application.get_env(:ash_dispatch, :channel_topic, "user")
  end

  @doc """
  The PubSub topic for admin/firehose broadcasts.

  Used by the `:broadcast` transport when audience is `:admin`.

  ## Example

      config :ash_dispatch,
        admin_channel_topic: "admin:firehose"
  """
  @spec admin_channel_topic() :: String.t()
  def admin_channel_topic do
    Application.get_env(:ash_dispatch, :admin_channel_topic, "admin:firehose")
  end

  @doc """
  The counter broadcaster module.

  Should implement `broadcast/3` for counter updates.
  """
  @spec counter_broadcaster() :: module() | nil
  def counter_broadcaster do
    Application.get_env(:ash_dispatch, :counter_broadcaster)
  end

  @doc """
  The counter broadcast function (alternative to counter_broadcaster module).
  """
  @spec counter_broadcast_fn() :: function() | nil
  def counter_broadcast_fn do
    Application.get_env(:ash_dispatch, :counter_broadcast_fn)
  end

  @doc """
  The permission checker module for policy checks.
  """
  @spec permission_checker() :: module() | nil
  def permission_checker do
    Application.get_env(:ash_dispatch, :permission_checker)
  end

  # ============================================================================
  # Database
  # ============================================================================

  @doc """
  The Ecto repo module.

  Used for Oban job queries and other database operations.
  """
  @spec repo() :: module() | nil
  def repo do
    Application.get_env(:ash_dispatch, :repo)
  end

  # ============================================================================
  # Event Modules
  # ============================================================================

  @doc """
  List of explicitly registered event modules.

  These are discovered in addition to DSL-based events.
  """
  @spec event_modules() :: [module()]
  def event_modules do
    Application.get_env(:ash_dispatch, :event_modules, [])
  end

  # ============================================================================
  # Compilation & Development
  # ============================================================================

  @doc """
  Whether to skip actual email delivery.

  When `true`, emails will not be sent and delivery receipts will be marked
  as `:skipped` with reason "email delivery disabled". Useful for development
  to prevent sending real emails while still testing the full dispatch flow.

  Defaults to `false`.

  Since 0.9.3 this is the email-shaped corner of `delivery_mode/0`: it is read
  as `delivery_mode: [email: :blocked]` and keeps the reason it has always
  written on the receipt. It covers email only — use `:delivery_mode` to hold
  back SMS, push, in-app and webhooks as well.

  ## Example

      # config/dev.exs
      config :ash_dispatch,
        skip_email_delivery: true
  """
  @spec skip_email_delivery?() :: boolean()
  def skip_email_delivery? do
    Application.get_env(:ash_dispatch, :skip_email_delivery, false)
  end

  @doc """
  Whether deliveries really go out, per transport.

  `:live` (the default), `:blocked`, `:dry_run`, `{:allow_list, [...]}`, or a
  keyword list per transport. See `AshDispatch.DeliveryMode` for the full
  reading, including how `skip_email_delivery` maps onto it.

  ## Example

      # config/staging.exs — the team can be mailed, nobody else
      config :ash_dispatch,
        delivery_mode: [
          default: :blocked,
          email: {:allow_list, ["@example.test"]}
        ]
  """
  @spec delivery_mode() :: term()
  def delivery_mode do
    Application.get_env(:ash_dispatch, :delivery_mode)
  end

  @doc """
  Whether an outgoing email carries its tenant as an `X-AshDispatch-Tenant`
  header, so a provider that echoes headers back can say which tenant a
  webhook is about.

  Off by default, and worth leaving off unless you verify the provider's
  signature (`AshDispatch.WebhookHandlers.Resend.verify/3`): without that the
  tag is a value a stranger chose, and the tenant it names is a Postgres
  schema. It is also a header the recipient can read, so it must never say
  more than the tenant key.

  A per-tenant webhook endpoint (`process_webhook(params, tenant: ...)`) needs
  none of this and is the better answer. See
  `AshDispatch.WebhookHandlers.Resend`.

  ## Example

      config :ash_dispatch, webhook_tenant_tag: true
  """
  @spec webhook_tenant_tag?() :: boolean()
  def webhook_tenant_tag? do
    Application.get_env(:ash_dispatch, :webhook_tenant_tag, false) == true
  end

  @doc """
  Where the library finds out which tenants exist — a module implementing
  `AshDispatch.Tenants`, `{module, function}`, `{module, function, args}`, or a
  zero-argument function.

  Needed only when receipts are stored per tenant: the cron workers and the
  scrub work across tenants, and a tenant arriving from outside (a provider's
  webhook tag) is checked against this before it is allowed near a query.

  ## Example

      config :ash_dispatch, tenants: MyApp.Tenants
  """
  @spec tenants() :: module() | {module(), atom()} | {module(), atom(), list()} | fun() | nil
  def tenants do
    Application.get_env(:ash_dispatch, :tenants)
  end

  @doc """
  What the send job carries: `:full` (the rendered message in the job's args,
  as before) or `:minimal` (ids only; the worker reads the message from the
  receipt).

  **Defaults to `:minimal` when receipts are stored per tenant**, and to
  `:full` otherwise — `oban_jobs` is one table in the public schema, so for a
  host with per-tenant receipts the job args would be the one place a tenant's
  rendered message leaves its schema. For a host on public receipts the default
  cannot change inside 0.9.x.

  An event declaring `metadata: [sensitive_content: true]` has been `:minimal`
  since 0.8.7 whatever this says.

  ## Example

      config :ash_dispatch, job_args: :minimal
  """
  @spec job_args() :: :full | :minimal
  def job_args do
    case Application.get_env(:ash_dispatch, :job_args) do
      :minimal -> :minimal
      :full -> :full
      _ -> if AshDispatch.Tenancy.receipts_per_tenant?(), do: :minimal, else: :full
    end
  end

  @doc """
  The Oban queue `AshDispatch.Workers.RetryFailedDeliveries` runs in.

  Defaults to `:default`, which is what every release before 0.9.3 used and
  what 0.9.x keeps: a host whose Oban has no `:emails` entry for it would
  otherwise stop retrying failed deliveries without notice.

  Set it to the queue your mail runs in, so pausing or scaling that queue
  pauses or scales the retries with it:

      config :ash_dispatch, retry_queue: :emails

  A `queue:` in the cron entry wins over this.
  """
  @spec retry_queue() :: atom()
  def retry_queue do
    Application.get_env(:ash_dispatch, :retry_queue, :default)
  end

  @doc """
  Whether to compile templates at build time.

  Defaults to `false`.
  """
  @spec compile_templates?() :: boolean()
  def compile_templates? do
    Application.get_env(:ash_dispatch, :compile_templates, false)
  end

  @doc """
  Custom format extensions for template resolution.
  """
  @spec format_extensions() :: map()
  def format_extensions do
    Application.get_env(:ash_dispatch, :format_extensions, %{})
  end

  @doc """
  Output path for generated SDK files.

  A codegen key, not a runtime one: `mix ash_dispatch.gen` reads it, and this
  accessor exists so the key is documented with the others. The generator also
  accepts the app-scoped spelling (`config :my_app, ash_dispatch: [...]`),
  which this function does not see — ask the generator, not this module, for
  the answer it will act on.

  Three values:

  - a path — write the SDK there
  - `false` — write no SDK at all, and let `mix ash.codegen --check` pass with
    none of those files on disk. The same as `config :ash_dispatch, sdk: false`.
    Before 0.9.4-rc.2 this fell through as falsy and the SDK was written anyway
  - unset — derive the path from `config :ash_typescript, output_file:`

  `config :ash_dispatch, sdk:` is the companion switch: `true` (the default),
  `false`, or `:if_events` to write the SDK only when this app has events,
  counters, a `resource_meta` or an `entity_changes` block. See
  `Mix.Tasks.AshDispatch.Gen` and the Code Generation guide.
  """
  @spec sdk_output_path() :: String.t() | false | nil
  def sdk_output_path do
    Application.get_env(:ash_dispatch, :sdk_output_path)
  end

  # ============================================================================
  # Action Authorization
  # ============================================================================

  @doc """
  Authorizer module for the `send_now` action on delivery receipts.

  The module should implement `authorize/1` which receives the actor and returns:
  - `:ok` if authorized
  - `{:error, message}` if not authorized

  When `nil` (default), `send_now` is allowed for any authenticated actor.
  System calls (no actor) are always allowed regardless of this setting.

  ## Example

      # Define authorizer module
      defmodule MyApp.SendNowAuthorizer do
        def authorize(nil), do: :ok  # System calls always allowed
        def authorize(%{super_admin: true}), do: :ok
        def authorize(_), do: {:error, "Only super admins can trigger send now"}
      end

      # Configure in config.exs
      config :ash_dispatch,
        send_now_authorizer: MyApp.SendNowAuthorizer
  """
  @spec send_now_authorizer() :: module() | nil
  def send_now_authorizer do
    Application.get_env(:ash_dispatch, :send_now_authorizer)
  end
end
