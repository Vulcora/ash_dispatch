defmodule AshDispatch.EventResolver do
  @moduledoc """
  Centralized event resolution and callback execution for AshDispatch events.

  Handles the logic for finding event modules and safely calling their callbacks
  with consistent error handling.

  ## Finding Events

      # Find an event module by ID
      {:ok, module} = EventResolver.find_module("orders.created")

      # Get all registered events
      events = EventResolver.all_events()

  ## Safe Callback Execution

  All callback functions handle errors gracefully and return sensible defaults:

      # Get sample data with fallback to empty map
      data = EventResolver.sample_data(module)

      # Get subject with fallback
      subject = EventResolver.subject(module, context, channel, default: "No subject")

      # Check if callback exists and call it
      {:ok, result} = EventResolver.call_if_exported(module, :custom_callback, [arg1, arg2])

  ## Context Building

      # Build a sample context for previews
      context = EventResolver.build_sample_context(event_id, module)
  """

  alias AshDispatch.Context

  require Logger

  # ===========================================================================
  # Event Discovery
  # ===========================================================================

  @doc """
  Find an event module by its event ID.

  ## Returns

  - `{:ok, module}` if found
  - `{:error, :not_found}` if no event with that ID exists
  """
  @spec find_module(String.t()) :: {:ok, module()} | {:error, :not_found}
  def find_module(event_id) do
    case Enum.find(all_events(), fn {id, _module} -> id == event_id end) do
      {^event_id, module} -> {:ok, module}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Get all registered event modules as a list of `{event_id, module}` tuples.

  Uses the EventRegistry which auto-discovers events from configured domains.
  """
  @spec all_events() :: [{String.t(), module()}]
  def all_events do
    AshDispatch.EventRegistry.get_event_modules()
  end

  @doc """
  Get the event ID from a module, if it implements `id/0`.
  """
  @spec event_id(module()) :: String.t() | nil
  def event_id(module) do
    call_if_exported(module, :id, [], default: nil)
  end

  # ===========================================================================
  # Context Building
  # ===========================================================================

  @doc """
  Build a sample context for previews and testing.

  Uses the module's `sample_data/0` callback if available.
  """
  @spec build_sample_context(String.t(), module()) :: Context.t()
  def build_sample_context(event_id, module) do
    sample_data = sample_data(module)

    %Context{
      event_id: event_id,
      data: sample_data,
      metadata: %{}
    }
  end

  # ===========================================================================
  # Safe Callback Execution
  # ===========================================================================

  @doc """
  Call a function on the module if it's exported, with error handling.

  ## Options

  - `:default` - Value to return if function not exported or raises (default: nil)

  ## Examples

      # Returns result or default
      value = EventResolver.call_if_exported(module, :domain, [], default: :unknown)

      # With arguments
      subject = EventResolver.call_if_exported(module, :subject, [context, channel])
  """
  @spec call_if_exported(module(), atom(), list(), keyword()) :: any()
  def call_if_exported(module, function, args, opts \\ []) do
    default = Keyword.get(opts, :default, nil)
    arity = length(args)

    # Ensure module is loaded before checking exports
    if Code.ensure_loaded?(module) && function_exported?(module, function, arity) do
      try do
        apply(module, function, args)
      rescue
        error ->
          Logger.debug(
            "[EventResolver] #{inspect(module)}.#{function}/#{arity} raised: #{inspect(error)}"
          )

          default
      end
    else
      default
    end
  end

  @doc """
  Check if a module exports a specific function.
  """
  @spec exports?(module(), atom(), non_neg_integer()) :: boolean()
  def exports?(module, function, arity) do
    Code.ensure_loaded?(module) && function_exported?(module, function, arity)
  end

  # ===========================================================================
  # Common Callback Helpers
  # ===========================================================================

  @doc """
  Get sample data from an event module.
  """
  @spec sample_data(module()) :: map()
  def sample_data(module) do
    call_if_exported(module, :sample_data, [], default: %{})
  end

  @doc """
  Get the domain from an event module.
  """
  @spec domain(module()) :: atom() | nil
  def domain(module) do
    call_if_exported(module, :domain, [], default: nil)
  end

  @doc """
  Get the resource from an event module.
  """
  @spec resource(module()) :: module() | nil
  def resource(module) do
    call_if_exported(module, :resource, [], default: nil)
  end

  @doc """
  Get the data key from an event module.
  """
  @spec data_key(module()) :: atom() | nil
  def data_key(module) do
    call_if_exported(module, :data_key, [], default: nil)
  end

  @doc """
  Check if the event is user configurable.
  """
  @spec user_configurable?(module(), Context.t()) :: boolean()
  def user_configurable?(module, context) do
    call_if_exported(module, :user_configurable?, [context], default: false)
  end

  @doc """
  Get the event category for preferences.
  """
  @spec category(module(), Context.t()) :: atom() | nil
  def category(module, context) do
    call_if_exported(module, :category, [context], default: nil)
  end

  @doc """
  Check if the event is applicable for a specific user.
  """
  @spec applicable_for_user?(module(), any()) :: boolean()
  def applicable_for_user?(module, user) do
    call_if_exported(module, :applicable_for_user?, [user], default: true)
  end

  @doc """
  Get the email subject for a channel.

  Falls back to DSL content from the registry if the module returns the default value.
  """
  @spec subject(module(), Context.t(), AshDispatch.Channel.t(), keyword()) :: String.t() | nil
  def subject(module, context, channel, opts \\ []) do
    default = Keyword.get(opts, :default, nil)
    result = call_if_exported(module, :subject, [context, channel], default: default)

    # If module returned the static default "Notification", try to get from DSL registry
    if result == "Notification" || result == default do
      case get_dsl_content(context.event_id, :subject) do
        nil ->
          result

        dsl_subject ->
          AshDispatch.Event.Interpolation.interpolate(dsl_subject, context, channel, module)
      end
    else
      result
    end
  end

  @doc """
  Get the from address for a channel.
  """
  @spec from(module(), Context.t(), AshDispatch.Channel.t()) :: {String.t(), String.t()} | nil
  def from(module, context, channel) do
    call_if_exported(module, :from, [context, channel], default: nil)
  end

  @doc """
  Get the template variant for a channel.
  """
  @spec template_variant(module(), Context.t(), AshDispatch.Channel.t()) :: String.t() | nil
  def template_variant(module, context, channel) do
    call_if_exported(module, :template_variant, [context, channel], default: nil)
  end

  @doc """
  Prepare template assigns for a channel.
  """
  @spec prepare_template_assigns(module(), Context.t(), AshDispatch.Channel.t()) :: map()
  def prepare_template_assigns(module, context, channel) do
    call_if_exported(module, :prepare_template_assigns, [context, channel], default: %{})
  end

  @doc """
  Get recipients for a channel.
  """
  @spec recipients(module(), Context.t(), AshDispatch.Channel.t()) :: [String.t()]
  def recipients(module, context, channel) do
    call_if_exported(module, :recipients, [context, channel], default: [])
  end

  @doc """
  Get notification title for in-app notifications.

  Falls back to DSL content from the registry if the module returns the default value.
  """
  @spec notification_title(module(), Context.t(), AshDispatch.Channel.t()) :: String.t() | nil
  def notification_title(module, context, channel) do
    result = call_if_exported(module, :notification_title, [context, channel], default: nil)

    # If module returned the static default, try to get from DSL registry
    if result == "Notification" || result == nil do
      case get_dsl_content(context.event_id, :notification_title) do
        nil ->
          result

        dsl_title ->
          AshDispatch.Event.Interpolation.interpolate(dsl_title, context, channel, module)
      end
    else
      result
    end
  end

  @doc """
  Get notification message for in-app notifications.

  Falls back to DSL content from the registry if the module returns the default value.
  """
  @spec notification_message(module(), Context.t(), AshDispatch.Channel.t()) :: String.t() | nil
  def notification_message(module, context, channel) do
    result = call_if_exported(module, :notification_message, [context, channel], default: nil)

    # If module returned the static default, try to get from DSL registry
    if result == "You have a new notification" || result == nil do
      case get_dsl_content(context.event_id, :notification_message) do
        nil ->
          result

        dsl_message ->
          AshDispatch.Event.Interpolation.interpolate(dsl_message, context, channel, module)
      end
    else
      result
    end
  end

  @doc """
  Get required resources for manual trigger.
  """
  @spec required_resources(module()) :: keyword()
  def required_resources(module) do
    call_if_exported(module, :required_resources, [], default: [])
  end

  @doc """
  Generate send variables for actual delivery.
  """
  @spec generate_send_variables(module(), Context.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def generate_send_variables(module, context, variables) do
    if exports?(module, :generate_send_variables, 2) do
      try do
        module.generate_send_variables(context, variables)
      rescue
        error ->
          Logger.error(
            "[EventResolver] #{inspect(module)}.generate_send_variables/2 raised: #{inspect(error)}"
          )

          {:error, error}
      end
    else
      {:ok, variables}
    end
  end

  @doc """
  Prepare data from changeset (for resource-triggered events).
  """
  @spec prepare_data(module(), Ash.Changeset.t(), any()) :: map()
  def prepare_data(module, changeset, record) do
    call_if_exported(module, :prepare_data, [changeset, record], default: %{})
  end

  @doc """
  Get the notification type from an event module.
  """
  @spec notification_type(module(), Context.t()) :: atom()
  def notification_type(module, context) do
    call_if_exported(module, :notification_type, [context], default: :info)
  end

  @doc """
  Check if the event requires action from the user.
  """
  @spec action_required?(module(), Context.t()) :: boolean()
  def action_required?(module, context) do
    call_if_exported(module, :action_required?, [context], default: false)
  end

  @doc """
  Get action URL for in-app notifications.
  """
  @spec action_url(module(), Context.t(), AshDispatch.Channel.t()) :: String.t() | nil
  def action_url(module, context, channel) do
    call_if_exported(module, :action_url, [context, channel], default: nil)
  end

  @doc """
  Get action label for in-app notifications.
  """
  @spec action_label(module(), Context.t(), AshDispatch.Channel.t()) :: String.t() | nil
  def action_label(module, context, channel) do
    call_if_exported(module, :action_label, [context, channel], default: nil)
  end

  @doc """
  Get HTML body for email (for test modules without templates).
  Returns nil if callback not exported.
  """
  @spec body_html(module(), Context.t(), AshDispatch.Channel.t()) :: String.t() | nil
  def body_html(module, context, channel) do
    call_if_exported(module, :body_html, [context, channel], default: nil)
  end

  @doc """
  Get text body for email (for test modules without templates).
  Returns nil if callback not exported.
  """
  @spec body_text(module(), Context.t(), AshDispatch.Channel.t()) :: String.t() | nil
  def body_text(module, context, channel) do
    call_if_exported(module, :body_text, [context, channel], default: nil)
  end

  @doc """
  Get email attachments for a channel via the optional `attachments/2` callback.

  Returns a list of attachment maps (each with `:filename`, `:content_type`,
  `:data`). Events without the callback → `[]`.
  """
  @spec attachments(module(), Context.t(), AshDispatch.Channel.t()) :: [map()]
  def attachments(module, context, channel) do
    call_if_exported(module, :attachments, [context, channel], default: [])
  end

  @doc """
  Check if module exports both body_html and body_text callbacks.
  Used to determine if we should use callbacks instead of templates.
  """
  @spec has_body_callbacks?(module()) :: boolean()
  def has_body_callbacks?(module) do
    exports?(module, :body_html, 2) && exports?(module, :body_text, 2)
  end

  @doc """
  Get counters for broadcasting.
  """
  @spec counters(module(), Context.t(), AshDispatch.Channel.t()) :: [atom()]
  def counters(module, context, channel) do
    call_if_exported(module, :counters, [context, channel], default: [])
  end

  @doc """
  Get source URL for linking receipts to source resources.
  """
  @spec source_url(module(), Context.t(), AshDispatch.Channel.t()) :: String.t() | nil
  def source_url(module, context, channel) do
    call_if_exported(module, :source_url, [context, channel], default: nil)
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  # Look up DSL content field from the event registry
  defp get_dsl_content(event_id, field) when is_binary(event_id) and is_atom(field) do
    case AshDispatch.EventRegistry.find_event(event_id) do
      {:ok, %{content: content}} when is_map(content) ->
        Map.get(content, field)

      {:ok, %{content: content}} when is_list(content) ->
        Keyword.get(content, field)

      _ ->
        nil
    end
  end

  defp get_dsl_content(_, _), do: nil
end
