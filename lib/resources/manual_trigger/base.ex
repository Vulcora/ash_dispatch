defmodule AshDispatch.Resources.ManualTrigger.Base do
  @moduledoc """
  Provides the base DSL for ManualTrigger resources.

  This module exports a `__using__` macro that consuming apps can use to create
  their own ManualTrigger resource with a specific domain.

  ## Usage

      defmodule MyApp.Deliveries.ManualTrigger do
        use AshDispatch.Resources.ManualTrigger.Base,
          domain: MyApp.Deliveries,
          extensions: [AshTypescript.Resource]

        # Optional: TypeScript type configuration
        typescript do
          type_name("ManualTrigger")
        end
      end

  Then add to your domain:

      resources do
        resource MyApp.Deliveries.ManualTrigger do
          define :list_manual_trigger_events, action: :list_events, args: [:user_id]
          define :preview_manual_trigger, action: :preview
          define :trigger_manual_event, action: :trigger
        end
      end

  ## Options

  - `:domain` - (required) Ash domain
  - `:extensions` - Additional Ash extensions (e.g., `[AshTypescript.Resource]`)
  """

  defmacro __using__(opts) do
    domain = Keyword.fetch!(opts, :domain)
    extra_extensions = Keyword.get(opts, :extensions, [])

    quote do
      use Ash.Resource,
        domain: unquote(domain),
        data_layer: Ash.DataLayer.Simple,
        extensions: unquote(extra_extensions),
        validate_domain_inclusion?: false

      alias AshDispatch.Resources.ManualTrigger.Helpers

      resource do
        require_primary_key? false
      end

      actions do
        defaults []

        read :list_events do
          description "List manually triggerable events (trigger_on: :manual)"

          argument :user_id, :string do
            allow_nil? true
            description "Optional user ID to filter events based on user state"
          end

          prepare fn query, _context ->
            # TODO: Make user loading configurable via DSL
            # For now, we list all events without user-based filtering
            _user_id = Ash.Query.get_argument(query, :user_id)
            events = Helpers.list_available_events(nil)

            records =
              Enum.map(events, fn event_data ->
                struct(__MODULE__, event_data)
              end)

            Ash.DataLayer.Simple.set_data(query, records)
          end
        end

        read :list_all_events do
          description "List ALL events for template preview (regardless of trigger_on setting)"

          prepare fn query, _context ->
            events = Helpers.list_all_events()

            records =
              Enum.map(events, fn event_data ->
                struct(__MODULE__, event_data)
              end)

            Ash.DataLayer.Simple.set_data(query, records)
          end
        end

        read :get_user_preference do
          description "Get user's email preference status for a specific event"

          argument :user_id, :string do
            allow_nil? false
            description "The user ID to check preferences for"
          end

          argument :event_id, :string do
            allow_nil? false
            description "The event ID to check"
          end

          prepare fn query, _context ->
            user_id = Ash.Query.get_argument(query, :user_id)
            event_id = Ash.Query.get_argument(query, :event_id)

            case Helpers.get_user_preference_for_event(user_id, event_id) do
              {:ok, preference_data} ->
                record = struct(__MODULE__, Map.merge(preference_data, %{event_id: event_id}))
                Ash.DataLayer.Simple.set_data(query, [record])

              {:error, reason} ->
                Ash.Query.add_error(query, reason)
            end
          end
        end

        read :preview do
          description "Preview the email content that would be sent"

          argument :event_id, :string do
            allow_nil? false
          end

          argument :context_data, :map do
            default %{}
          end

          argument :recipient_email, :ci_string
          argument :audience, :atom, constraints: [one_of: [:user, :admin]]
          argument :transport, :atom, constraints: [one_of: [:email, :in_app]]

          prepare fn query, context ->
            event_id = Ash.Query.get_argument(query, :event_id)
            context_data = Ash.Query.get_argument(query, :context_data)
            recipient_email = Ash.Query.get_argument(query, :recipient_email)
            audience = Ash.Query.get_argument(query, :audience)
            transport = Ash.Query.get_argument(query, :transport)

            channel_filter = Helpers.build_channel_filter(audience, transport)

            case Helpers.preview_trigger(
                   event_id,
                   context_data,
                   channel_filter,
                   recipient_email,
                   context.actor
                 ) do
              {:ok, previews} ->
                records =
                  Enum.map(previews, fn preview_data ->
                    merged = Map.merge(preview_data, %{event_id: event_id})
                    struct(__MODULE__, merged)
                  end)

                Ash.DataLayer.Simple.set_data(query, records)

              {:error, reason} ->
                Ash.Query.add_error(query, reason)
            end
          end
        end

        create :trigger do
          description "Manually trigger an event with custom configuration"

          accept [
            :event_id,
            :recipient_email,
            :audience,
            :transport,
            :context_data,
            :skip_preferences
          ]

          change fn changeset, context ->
            event_id = Ash.Changeset.get_attribute(changeset, :event_id)
            context_data = Ash.Changeset.get_attribute(changeset, :context_data)
            recipient_email = Ash.Changeset.get_attribute(changeset, :recipient_email)
            audience = Ash.Changeset.get_attribute(changeset, :audience)
            transport = Ash.Changeset.get_attribute(changeset, :transport)
            skip_preferences = Ash.Changeset.get_attribute(changeset, :skip_preferences)

            opts =
              Helpers.build_trigger_opts(
                recipient_email,
                audience,
                transport,
                skip_preferences,
                context.actor
              )

            # Use load_and_dispatch to load resource data before dispatching
            case Helpers.load_and_dispatch(event_id, context_data, opts, context.actor) do
              {:ok, results} ->
                # Extract receipt IDs from results
                receipt_ids =
                  results
                  |> Enum.flat_map(fn
                    {:ok, receipts} when is_list(receipts) ->
                      Enum.map(receipts, & &1.id)

                    _ ->
                      []
                  end)

                # Store receipt IDs in changeset so they can be returned
                Ash.Changeset.force_change_attribute(
                  changeset,
                  :delivery_receipt_ids,
                  receipt_ids
                )

              {:error, reason} ->
                Ash.Changeset.add_error(changeset, reason)
            end
          end
        end
      end

      attributes do
        attribute :event_id, :string do
          allow_nil? false
          public? true
        end

        attribute :recipient_email, :ci_string do
          public? true
        end

        attribute :audience, :atom do
          public? true
          constraints one_of: [:user, :admin]
        end

        attribute :transport, :atom do
          public? true
          constraints one_of: [:email, :in_app]
        end

        attribute :context_data, :map do
          public? true
          default %{}
        end

        attribute :skip_preferences, :boolean do
          public? true
          default false
        end

        attribute :description, :string do
          public? true
        end

        attribute :channels, {:array, :map} do
          public? true
        end

        attribute :required_context, {:array, :string} do
          public? true
        end

        attribute :example_context, :map do
          public? true
        end

        attribute :domain, :string do
          public? true
        end

        attribute :required_resources, {:array, :map} do
          public? true
          description "Resources required for manual trigger, with optional Ash filters"
        end

        attribute :subject, :string do
          public? true
        end

        attribute :html_body, :string do
          public? true
        end

        attribute :text_body, :string do
          public? true
        end

        attribute :from_address, :string do
          public? true
        end

        attribute :recipient, :string do
          public? true
        end

        attribute :notification_title, :string do
          public? true
          description "Title for in-app notification preview"
        end

        attribute :notification_message, :string do
          public? true
          description "Message for in-app notification preview"
        end

        attribute :user_configurable, :boolean do
          public? true
        end

        attribute :category, :string do
          public? true
        end

        attribute :preference_enabled, :boolean do
          public? true
        end

        attribute :delivery_receipt_ids, {:array, :string} do
          public? true
          description "IDs of delivery receipts created by trigger action"
        end
      end
    end
  end
end
