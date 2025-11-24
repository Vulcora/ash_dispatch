defmodule Mix.Tasks.AshDispatch.Gen do
  @moduledoc """
  Unified generator for AshDispatch - generates everything needed for your app.

  This single command generates:
  1. **Event module stubs** - `event.ex` files with Event behaviour
  2. **Templates** - Email HTML/text templates extracted to your app
  3. **Counter types** - TypeScript types for all counters
  4. **TypeScript SDK** - Hooks, stores, and components for real-time updates

  ## Usage

      # Generate everything
      mix ash_dispatch.gen

      # Generate specific parts only
      mix ash_dispatch.gen --only counters
      mix ash_dispatch.gen --only sdk
      mix ash_dispatch.gen --only events
      mix ash_dispatch.gen --only templates

      # Specify custom output paths
      mix ash_dispatch.gen --counters-output lib/my_frontend/counters.ts

  ## Configuration

  Configure in your application config:

      config :ash_dispatch,
        # Event module generation
        events_namespace: MyApp.Events,           # Module namespace for events
        templates_path: "lib/my_app/events",      # Where templates go

        # SDK generation (path derived from ash_typescript)
        generate_sdk: true,                       # Enable TypeScript SDK
        sdk_folder: "ash-dispatch"                # Folder name

  Output path for SDK is derived from `ash_typescript`:

      config :ash_typescript,
        output_file: "apps/frontend/src/lib/ash_rpc.ts"
      # SDK generates to: "apps/frontend/src/lib/ash-dispatch/"

  ## What Gets Generated

  ### Elixir (your app)

      lib/your_app/events/
      ├── orders/
      │   ├── created/
      │   │   ├── event.ex              # Generated stub
      │   │   └── templates/
      │   │       ├── email.html.heex   # Extracted template
      │   │       └── email.text.eex
      │   └── cancelled/...
      └── tickets/...

  ### TypeScript

      lib/ash-dispatch/
      ├── index.ts              # Re-exports
      ├── store.ts              # Zustand counter store
      ├── channel.ts            # Phoenix channel
      ├── types.ts              # Counter types
      └── hooks/
          ├── use-channel.ts
          ├── use-counter.ts
          └── use-notifications.ts

  ## Event Module Stub Example

  Generated event modules include all required callbacks with TODOs:

      defmodule MyApp.Events.Orders.Created.Event do
        use AshDispatch.Event

        @impl true
        def channels(_context) do
          [
            %{transport: :in_app, audience: :user},
            %{transport: :email, audience: :user}
          ]
        end

        @impl true
        def recipients(context, %{audience: :user}) do
          [context.data.user]
        end

        # ... more callbacks with TODOs
      end
  """

  use Mix.Task

  @shortdoc "Generate AshDispatch types, SDK, events, and templates"

  @switches [
    only: :string,
    counters_output: :string,
    sdk_output: :string,
    events_path: :string,
    force: :boolean
  ]

  @aliases [
    o: :only,
    f: :force
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile")
    Mix.Task.reenable("ash_dispatch.gen")

    {opts, _} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)

    only = Keyword.get(opts, :only)

    parts_to_generate =
      case only do
        nil -> [:counters, :sdk, :events, :templates]
        "counters" -> [:counters]
        "sdk" -> [:sdk]
        "events" -> [:events]
        "templates" -> [:templates]
        other ->
          Mix.shell().error("Unknown --only value: #{other}")
          Mix.shell().info("Valid values: counters, sdk, events, templates")
          []
      end

    if Enum.empty?(parts_to_generate) do
      :ok
    else
      # Get configuration
      config = get_config(opts)

      # Generate each requested part
      results =
        Enum.map(parts_to_generate, fn part ->
          {part, generate_part(part, config)}
        end)

      # Print summary
      print_summary(results)
    end
  end

  defp get_config(opts) do
    # Get ash_typescript output path to derive SDK location
    ash_ts_output = Application.get_env(:ash_typescript, :output_file, "priv/static/ash_rpc.ts")
    sdk_base_dir = Path.dirname(ash_ts_output)

    %{
      # Counter types
      counters_output: Keyword.get(
        opts,
        :counters_output,
        derive_counters_path(ash_ts_output)
      ),

      # SDK generation
      generate_sdk: Application.get_env(:ash_dispatch, :generate_sdk, true),
      sdk_output: Keyword.get(
        opts,
        :sdk_output,
        Path.join(sdk_base_dir, Application.get_env(:ash_dispatch, :sdk_folder, "ash-dispatch"))
      ),

      # Event modules
      events_namespace: Application.get_env(:ash_dispatch, :events_namespace),
      events_path: Keyword.get(
        opts,
        :events_path,
        Application.get_env(:ash_dispatch, :templates_path, "lib/events")
      ),

      # Options
      force: Keyword.get(opts, :force, false)
    }
  end

  defp derive_counters_path(ash_ts_output) do
    # Put counters.ts next to ash_rpc.ts
    dir = Path.dirname(ash_ts_output)
    Path.join(dir, "counters.ts")
  end

  defp generate_part(:counters, config) do
    Mix.shell().info("\n📊 Generating counter types...")

    # Reuse existing counter types generator
    Mix.Tasks.AshDispatch.Gen.CounterTypes.run(["--output", config.counters_output])

    {:ok, config.counters_output}
  rescue
    e ->
      {:error, Exception.message(e)}
  end

  defp generate_part(:sdk, config) do
    if config.generate_sdk do
      Mix.shell().info("\n🔧 Generating TypeScript SDK...")

      case generate_sdk(config) do
        :ok -> {:ok, config.sdk_output}
        error -> error
      end
    else
      {:skipped, "SDK generation disabled (generate_sdk: false)"}
    end
  end

  defp generate_part(:events, config) do
    Mix.shell().info("\n📝 Generating event module stubs...")

    case generate_event_stubs(config) do
      {:ok, count} -> {:ok, "#{count} event modules"}
      error -> error
    end
  end

  defp generate_part(:templates, config) do
    Mix.shell().info("\n📄 Extracting templates...")

    case extract_templates(config) do
      {:ok, count} -> {:ok, "#{count} templates"}
      error -> error
    end
  end

  # SDK Generator
  defp generate_sdk(config) do
    output_dir = config.sdk_output
    File.mkdir_p!(output_dir)

    # Generate each SDK file
    files = [
      {"index.ts", generate_sdk_index()},
      {"types.ts", generate_sdk_types()},
      {"store.ts", generate_sdk_store()},
      {"channel.ts", generate_sdk_channel()},
      {"hooks/use-channel.ts", generate_sdk_use_channel()},
      {"hooks/use-counter.ts", generate_sdk_use_counter()},
      {"hooks/use-notifications.ts", generate_sdk_use_notifications()}
    ]

    Enum.each(files, fn {filename, content} ->
      path = Path.join(output_dir, filename)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end)

    Mix.shell().info("  ✓ Generated #{length(files)} SDK files")
    :ok
  end

  defp generate_sdk_index do
    """
    // Auto-generated by mix ash_dispatch.gen
    // Do not edit manually

    export * from './types'
    export * from './store'
    export * from './channel'
    export { useChannel } from './hooks/use-channel'
    export { useCounter } from './hooks/use-counter'
    export { useNotifications } from './hooks/use-notifications'
    """
  end

  defp generate_sdk_types do
    """
    // Auto-generated by mix ash_dispatch.gen
    // Re-exports from counters.ts for convenience

    export * from '../counters'
    """
  end

  defp generate_sdk_store do
    """
    // Auto-generated by mix ash_dispatch.gen
    // Zustand store for counter state

    import { create } from 'zustand'
    import { DEFAULT_COUNTERS, type AllCounters, type CounterName } from './types'

    interface CounterState {
      counters: AllCounters
      setCounters: (counters: Partial<AllCounters>) => void
      setCounter: (key: CounterName, value: number) => void
      resetCounters: () => void
    }

    export const useCounterStore = create<CounterState>()((set) => ({
      counters: DEFAULT_COUNTERS,

      setCounters: (newCounters) => {
        set((state) => ({
          counters: { ...state.counters, ...newCounters },
        }))
      },

      setCounter: (key, value) => {
        set((state) => ({
          counters: { ...state.counters, [key]: value },
        }))
      },

      resetCounters: () => {
        set({ counters: DEFAULT_COUNTERS })
      },
    }))
    """
  end

  defp generate_sdk_channel do
    """
    // Auto-generated by mix ash_dispatch.gen
    // Phoenix channel utilities

    import { Socket, Channel } from 'phoenix'

    export interface ChannelConfig {
      socketUrl: string
      userToken: string
      userId: string
    }

    export function createUserChannel(config: ChannelConfig): Channel {
      const socket = new Socket(config.socketUrl, {
        params: { token: config.userToken }
      })

      socket.connect()

      const channel = socket.channel(`user:\${config.userId}`, {})

      return channel
    }
    """
  end

  defp generate_sdk_use_channel do
    """
    // Auto-generated by mix ash_dispatch.gen
    // Hook for managing Phoenix channel connection

    import { useEffect, useRef } from 'react'
    import { Channel } from 'phoenix'
    import { useCounterStore } from '../store'
    import { isValidCounter } from '../types'

    interface UseChannelOptions {
      channel: Channel | null
      onNotification?: (notification: unknown) => void
    }

    export function useChannel({ channel, onNotification }: UseChannelOptions) {
      const setCounter = useCounterStore((state) => state.setCounter)
      const joinedRef = useRef(false)

      useEffect(() => {
        if (!channel || joinedRef.current) return

        channel.join()
          .receive('ok', (response) => {
            console.log('[AshDispatch] Channel joined', response)
            joinedRef.current = true

            // Set initial counters
            if (response.counters) {
              Object.entries(response.counters).forEach(([key, value]) => {
                if (isValidCounter(key)) {
                  setCounter(key, value as number)
                }
              })
            }
          })
          .receive('error', (err) => {
            console.error('[AshDispatch] Channel join error', err)
          })

        // Listen for counter updates
        channel.on('counter_updated', (payload) => {
          const counterName = payload.counter as string
          if (isValidCounter(counterName)) {
            setCounter(counterName, payload.value)
          }
        })

        // Listen for notifications
        channel.on('notification', (payload) => {
          onNotification?.(payload)
        })

        return () => {
          if (joinedRef.current) {
            channel.leave()
            joinedRef.current = false
          }
        }
      }, [channel, setCounter, onNotification])
    }
    """
  end

  defp generate_sdk_use_counter do
    """
    // Auto-generated by mix ash_dispatch.gen
    // Hook for accessing a single counter value

    import { useCounterStore } from '../store'
    import type { CounterName } from '../types'

    export function useCounter(name: CounterName): number {
      return useCounterStore((state) => state.counters[name])
    }
    """
  end

  defp generate_sdk_use_notifications do
    """
    // Auto-generated by mix ash_dispatch.gen
    // Hook for notification state and actions

    import { useCallback } from 'react'
    import { useCounterStore } from '../store'

    // NOTE: This is a minimal implementation.
    // You'll need to integrate with your notification store and RPC calls.

    export function useNotifications() {
      const unreadCount = useCounterStore((state) => state.counters.unread_notifications)

      const markAsRead = useCallback(async (notificationId: string) => {
        // TODO: Call your RPC action
        // await markNotificationAsRead({ primaryKey: notificationId, fields: ["id", "read"] })
        console.log('markAsRead:', notificationId)
      }, [])

      const markAllAsRead = useCallback(async () => {
        // TODO: Call your RPC action
        // await markAllNotificationsAsRead({ input: { userId } })
        console.log('markAllAsRead')
      }, [])

      return {
        unreadCount,
        markAsRead,
        markAllAsRead,
      }
    }
    """
  end

  # Event stub generator
  defp generate_event_stubs(config) do
    # Get all domains and their resources
    domains = get_ash_domains()

    if Enum.empty?(domains) do
      {:error, "No Ash domains found"}
    else
      # Find resources with AshDispatch
      events =
        domains
        |> Enum.flat_map(&Ash.Domain.Info.resources/1)
        |> Enum.filter(&uses_ash_dispatch?/1)
        |> Enum.flat_map(&extract_events/1)

      if Enum.empty?(events) do
        Mix.shell().info("  No events found in resources")
        {:ok, 0}
      else
        # Generate stubs for events that don't exist yet
        generated =
          events
          |> Enum.map(fn event ->
            generate_event_stub(event, config)
          end)
          |> Enum.filter(& &1)

        {:ok, length(generated)}
      end
    end
  end

  defp extract_events(resource) do
    case Spark.Dsl.Extension.get_entities(resource, [:dispatch]) do
      [] ->
        []

      entities ->
        entities
        |> Enum.filter(fn entity -> entity.__struct__ == AshDispatch.Resource.Dsl.Event end)
        |> Enum.map(fn event ->
          %{
            name: event.name,
            resource: resource
          }
        end)
    end
  rescue
    _ -> []
  end

  defp generate_event_stub(event, config) do
    namespace = config.events_namespace

    unless namespace do
      Mix.shell().error("  ⚠ events_namespace not configured, skipping event stub generation")
      nil
    else
      # Build module name: MyApp.Events.Orders.Created.Event
      event_parts = event.name |> to_string() |> String.split(".")
      module_parts = Enum.map(event_parts, &Macro.camelize/1)
      module_name = Module.concat([namespace | module_parts] ++ [Event])

      # Build file path
      path_parts = Enum.map(event_parts, &Macro.underscore/1)
      file_path = Path.join([config.events_path | path_parts] ++ ["event.ex"])

      # Only generate if file doesn't exist
      if File.exists?(file_path) and not config.force do
        nil
      else
        content = event_stub_content(module_name, event.name)
        File.mkdir_p!(Path.dirname(file_path))
        File.write!(file_path, content)
        Mix.shell().info("  ✓ #{file_path}")
        file_path
      end
    end
  end

  defp event_stub_content(module_name, event_name) do
    """
    defmodule #{inspect(module_name)} do
      @moduledoc \"\"\"
      Event handler for #{event_name}.

      Generated by `mix ash_dispatch.gen` - customize as needed.
      \"\"\"

      use AshDispatch.Event

      @impl true
      def channels(_context) do
        [
          %{transport: :in_app, audience: :user},
          %{transport: :email, audience: :user}
        ]
      end

      @impl true
      def recipients(context, %{audience: :user}) do
        [context.data.user]
      end

      def recipients(_context, _channel), do: []

      @impl true
      def subject(_context) do
        "#{event_name |> to_string() |> String.split(".") |> List.last() |> Macro.camelize()}"  # TODO: Customize
      end

      @impl true
      def notification_title(_context) do
        "New Notification"  # TODO: Customize
      end

      @impl true
      def notification_body(_context) do
        "You have a new notification"  # TODO: Customize
      end

      # Templates are in: templates/email.html.heex, templates/email.text.eex
    end
    """
  end

  # Template extractor
  defp extract_templates(_config) do
    # TODO: Implement template extraction
    # For now, this is a placeholder
    Mix.shell().info("  Template extraction not yet implemented")
    {:ok, 0}
  end

  # Helpers
  defp get_ash_domains do
    Application.loaded_applications()
    |> Enum.flat_map(fn {app, _, _} ->
      Application.get_env(app, :ash_domains, [])
    end)
    |> Enum.uniq()
  end

  defp uses_ash_dispatch?(resource) do
    AshDispatch.Resource in Spark.extensions(resource)
  end

  defp print_summary(results) do
    Mix.shell().info("\n" <> String.duplicate("─", 50))
    Mix.shell().info("Generation Summary")
    Mix.shell().info(String.duplicate("─", 50))

    Enum.each(results, fn {part, result} ->
      status =
        case result do
          {:ok, output} -> "✓ #{part}: #{output}"
          {:skipped, reason} -> "⊘ #{part}: #{reason}"
          {:error, reason} -> "✗ #{part}: #{reason}"
        end

      Mix.shell().info(status)
    end)

    Mix.shell().info("")
  end
end
