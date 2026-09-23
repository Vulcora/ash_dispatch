defmodule AshDispatch.Setup do
  @moduledoc """
  Defines a DeliveryReceipt resource inside your Deliveries domain.

  A shortcut for `AshDispatch.Resources.DeliveryReceipt.Base`: instead of
  writing a resource file, `use` this in the domain module and it creates
  `<Domain>.DeliveryReceipt` there — built on the same Base, with the domain
  set to the module you are in.

  ## Usage

      defmodule MyApp.Deliveries do
        use AshDispatch.Setup,
          repo: MyApp.Repo,
          notification_resource: MyApp.Notifications.Notification,
          user_resource: MyApp.Accounts.User

        use Ash.Domain

        resources do
          resource MyApp.Deliveries.DeliveryReceipt
        end
      end

  Then point AshDispatch at it:

      config :ash_dispatch,
        delivery_receipt_resource: MyApp.Deliveries.DeliveryReceipt

  ## Options

  - `:repo` - (required) Ecto repo module
  - `:notification_resource` - (required) your Notification resource
  - `:user_resource` - adds a `belongs_to :user` relationship
  - `:table`, `:notifiers` - as for `AshDispatch.Resources.DeliveryReceipt.Base`
  - `:extensions` - Ash extensions to add. Defaults to `[AshTypescript.Resource]`
    when ash_typescript is installed and `[]` otherwise. With
    `AshTypescript.Resource` the receipt's TypeScript type is `"DeliveryReceipt"`.

  For anything the options don't cover — your own policies, actions or
  relationships — write the resource yourself on
  `AshDispatch.Resources.DeliveryReceipt.Base`.
  """

  defmacro __using__(opts) do
    domain = __CALLER__.module

    # The receipt is compiled as a module of its own, which does not see the
    # aliases in scope here — so aliases in the options are resolved now,
    # where they were written.
    opts = Macro.prewalk(opts, &expand_alias(&1, __CALLER__))

    for key <- [:repo, :notification_resource], not Keyword.has_key?(opts, key) do
      raise ArgumentError,
            "use AshDispatch.Setup requires #{inspect(key)} " <>
              "(see the AshDispatch.Setup docs for an example)"
    end

    extensions = Keyword.get_lazy(opts, :extensions, &default_extensions/0)
    base_opts = Keyword.merge(opts, domain: domain, extensions: extensions)
    doc = "Delivery receipt resource, defined by `AshDispatch.Setup` in `#{inspect(domain)}`."

    body =
      quote do
        @moduledoc unquote(doc)
        use AshDispatch.Resources.DeliveryReceipt.Base, unquote(base_opts)
        unquote(typescript_section(extensions))
      end

    # `Module.create/3` takes the module body as quoted code, so it must be
    # escaped. Before 0.8.4 it was not: the body was spliced in as code and
    # ran inside the *domain* module instead, so `use Ash.Domain` right after
    # failed with "can be called only one time", and this macro had never
    # produced a receipt.
    quote do
      Module.create(
        unquote(Module.concat(domain, DeliveryReceipt)),
        unquote(Macro.escape(body)),
        Macro.Env.location(__ENV__)
      )
    end
  end

  # `ash_typescript` is optional (#31): the receipt is a TypeScript resource
  # only in apps that have it. Evaluated at macro expansion, so it follows the
  # consuming app's deps rather than ash_dispatch's.
  defp default_extensions do
    if Code.ensure_loaded?(AshTypescript.Resource), do: [AshTypescript.Resource], else: []
  end

  # `type_name` is required once the extension is present — ash_typescript's
  # unique-type-name verifier calls `typescript_type_name!/1` on every
  # TypeScript resource — and a generated module leaves nowhere else to set it.
  defp typescript_section(extensions) do
    if AshTypescript.Resource in extensions do
      quote do
        typescript do
          type_name("DeliveryReceipt")
        end
      end
    end
  end

  defp expand_alias({:__aliases__, _, _} = alias, env), do: Macro.expand(alias, env)
  defp expand_alias(other, _env), do: other
end
