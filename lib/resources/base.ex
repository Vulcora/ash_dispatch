defmodule AshDispatch.Resources.Base do
  @moduledoc """
  Which of a resource's AshDispatch declarations came from this library.

  `use AshDispatch.Resources.Notification.Base` writes a `counters` block into
  the host's resource — `unread_notifications`, which is what an in-app bell
  counts. From the outside that counter is indistinguishable from one the host
  wrote: it is an entity of the host's module, in the host's domain.

  It has to be distinguishable for one decision. `sdk: :if_events` generates
  the TypeScript client only when "the host has something to generate for",
  and in 0.9.4-rc.2 that question was asked of every counter found — so any
  host using `Notification.Base` had one, and `:if_events` was `true` in
  effect (#50). It means "something **you** declared" now, and this is how
  that is told apart.

  Each `Base` macro therefore defines `__ash_dispatch_base_content__/0` on the
  resource it builds, naming what it declared there. Nothing else reads it,
  and nothing about generation changes: with the SDK on, a base's counter is
  described in the client exactly as before.

  Not for a host to call.
  """

  @empty %{counters: []}

  @doc false
  @spec declared(module()) :: %{counters: [atom()]}
  def declared(resource) do
    if Code.ensure_loaded?(resource) and
         function_exported?(resource, :__ash_dispatch_base_content__, 0) do
      Map.merge(@empty, resource.__ash_dispatch_base_content__())
    else
      @empty
    end
  end

  @doc """
  The names of the counters one of this library's bases declared on `resource`.

  `[]` for a resource the host wrote itself, and for one built on a base that
  declares no counters (`Preference.Base`, `DeliveryReceipt.Base`).
  """
  @spec counters(module()) :: [atom()]
  def counters(resource), do: declared(resource).counters

  @doc """
  Whether `name` is a counter this library's base brought, not the host's own.

  The DSL name is what is compared, not `counter_name:`: a host that renames
  the base's counter for the client has still not declared a counter.
  """
  @spec counter?(module(), atom()) :: boolean()
  def counter?(resource, name), do: name in counters(resource)
end
