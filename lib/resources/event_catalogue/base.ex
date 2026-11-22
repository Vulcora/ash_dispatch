defmodule AshDispatch.Resources.EventCatalogue.Base do
  @moduledoc """
  The event catalogue as a resource of your own, with your own policies on it.

  `AshDispatch.Resources.EmailEvent` is the same idea with three things nailed
  down: its policies are `actor_attribute_equals(:super_admin, true)`, it is a
  module rather than a macro, and it drops every event that has no email
  channel. A host whose permission model is not a `super_admin` boolean
  therefore could not use it at all — and a host that delivers by SMS, Slack
  or in-app notifications could not see those events in it. Several built the
  catalogue themselves instead.

  This is that resource as a macro. It lists **every** transport, it goes
  through the configured `permission_checker` by default, and
  `policies: :own` hands the whole policy question to you.

  `EmailEvent` stays exactly as it is.

  ## Usage

      defmodule MyApp.Deliveries.EventCatalogue do
        use AshDispatch.Resources.EventCatalogue.Base,
          domain: MyApp.Deliveries,
          extensions: [AshTypescript.Resource]

        typescript do
          type_name("EventCatalogue")
        end
      end

  Then in your domain:

      resources do
        resource MyApp.Deliveries.EventCatalogue do
          define :list_events, action: :list
          define :get_event, action: :get, args: [:id], get?: true
        end
      end

  ## Options

  - `:domain` - (required) Ash domain
  - `:extensions` - additional Ash extensions (e.g. `[AshTypescript.Resource]`)
  - `:policies` - `:default` (the default) or `:own`; see below
  - `:permission` - the permission `:default` policies ask the configured
    `permission_checker` for. `:view_event_catalogue` unless you say otherwise
  - `:transports` - `:all` (the default) or a list of transport atoms
  - `:previews?` - `false` renders no previews at all, for a catalogue that
    only needs names, channels and subjects

  ## Policies

  `policies: :default` declares:

      bypass {AshDispatch.PolicyChecks.HasPermission, permission: <permission>} do
        authorize_if always()
      end

      policy always() do
        forbid_if always()
      end

  so the catalogue is readable by an actor your `permission_checker` approves
  and by nobody else, and `authorize?: false` (a worker, a test) still reads
  it. Configure the checker once:

      config :ash_dispatch,
        permission_checker: MyApp.Accounts.Policy.HasPermission

  Without a checker configured, `HasPermission` denies — the resource is
  closed until you decide who may read it, which is the right direction to
  fail in for a surface that renders letters.

  `policies: :own` declares **no policies at all**. With
  `Ash.Policy.Authorizer` present that means fail-closed: a request no policy
  authorizes is forbidden, and you open it with your own `policies do ... end`
  block — the same contract `AshDispatch.Resources.ManualTrigger.Base` has.

  Do not reach for `policies: :default` and then try to widen it with a
  `bypass` of your own: base policies compile BEFORE yours, the trailing
  `forbid_if always()` is a non-bypass policy, and a later `bypass` cannot
  re-open it. That is what `policies: :own` is for.

  ## What a row holds

  See `AshDispatch.Resources.EventCatalogue` for the shape. Previews come
  from `AshDispatch.Preview`, one channel at a time, from sample data only —
  so listing the catalogue never reads a customer's records and never runs a
  recipient query.
  """

  defmacro __using__(opts) do
    domain = Keyword.fetch!(opts, :domain)
    extra_extensions = Keyword.get(opts, :extensions, [])
    policies = Keyword.get(opts, :policies, :default)
    permission = Keyword.get(opts, :permission, :view_event_catalogue)
    transports = Keyword.get(opts, :transports, :all)
    previews? = Keyword.get(opts, :previews?, true)

    unless policies in [:default, :own] do
      raise ArgumentError,
            "AshDispatch.Resources.EventCatalogue.Base: policies: must be :default or :own, " <>
              "got #{inspect(policies)}"
    end

    policy_block =
      if policies == :default do
        quote do
          policies do
            # Through the configured permission checker, and a bypass so that
            # `authorize?: false` and an approved actor both get through while
            # the trailing policy closes the resource to everyone else.
            #
            # It MUST be a bypass: two non-bypass policies are AND-ed, so an
            # `authorize_if` followed by a `forbid_if always()` forbids
            # everybody — which is the bug `EmailEvent` was shipped with and
            # fixed, and reads surfaced it as an empty list rather than an
            # error.
            bypass {AshDispatch.PolicyChecks.HasPermission, permission: unquote(permission)} do
              authorize_if always()
            end

            policy always() do
              forbid_if always()
            end
          end
        end
      else
        quote do
          # `policies: :own`: none here on purpose. With the authorizer
          # present the resource is fail-closed, and the host's own
          # `policies do ... end` block is the only thing that opens it.
        end
      end

    quote do
      use Ash.Resource,
        domain: unquote(domain),
        data_layer: Ash.DataLayer.Ets,
        authorizers: [Ash.Policy.Authorizer],
        extensions: unquote(extra_extensions),
        validate_domain_inclusion?: false

      ets do
        private? true
      end

      unquote(policy_block)

      @ash_dispatch_catalogue_opts [
        transports: unquote(transports),
        previews?: unquote(previews?)
      ]

      @doc false
      def __ash_dispatch_catalogue_opts__, do: @ash_dispatch_catalogue_opts

      @doc false
      # This base declares no counters, events or metas of its own — see
      # `AshDispatch.Resources.Base`.
      def __ash_dispatch_base_content__, do: %{counters: []}

      attributes do
        attribute :id, :string do
          public? true
          allow_nil? false
          primary_key? true
          description "Event identifier (e.g., 'orders.created')"
        end

        attribute :module, :string do
          public? true
          description "Event module name"
        end

        attribute :domain, :atom do
          public? true
          description "Domain this event belongs to"
        end

        attribute :user_configurable, :boolean do
          public? true
          default false
          description "Whether people can configure delivery preferences for it"
        end

        attribute :category, :atom do
          public? true
          description "Preference category"
        end

        attribute :transports, {:array, :atom} do
          public? true
          default []
          description "Every transport this event delivers over"
        end

        attribute :channel_count, :integer do
          public? true
          default 0
          description "Total number of channels for this event"
        end

        attribute :email_channel_count, :integer do
          public? true
          default 0
          description "Number of email channels for this event"
        end

        attribute :channels, {:array, :map} do
          public? true
          default []

          description "Channel configurations with subjects, timing and rendered previews"
        end

        attribute :action_required, :boolean do
          public? true
          default false
          description "Whether this event requires action from its recipient"
        end

        attribute :notification_type, :atom do
          public? true
          description "Notification type for styling (:info, :success, :warning, :error)"
        end
      end

      actions do
        defaults []

        read :list do
          primary? true
          description "List every dispatch event, with its channels and their previews"

          manual fn _query, _opts, _context ->
            events =
              @ash_dispatch_catalogue_opts
              |> AshDispatch.Resources.EventCatalogue.rows()
              |> Enum.map(&__ash_dispatch_struct__/1)

            {:ok, events}
          end
        end

        read :get do
          description "One event by id"
          argument :id, :string, allow_nil?: false

          manual fn query, _opts, _context ->
            id = Ash.Query.get_argument(query, :id)

            case AshDispatch.Resources.EventCatalogue.row(id, @ash_dispatch_catalogue_opts) do
              nil -> {:ok, []}
              row -> {:ok, [__ash_dispatch_struct__(row)]}
            end
          end
        end
      end

      code_interface do
        define :list, action: :list
        define :get, action: :get, args: [:id]
      end

      @doc false
      def __ash_dispatch_struct__(row) do
        __MODULE__
        |> struct(row)
        |> Ash.Resource.set_metadata(%{})
      end
    end
  end
end
