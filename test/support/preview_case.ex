defmodule AshDispatch.Test.PreviewCase do
  @moduledoc """
  Configuration for tests that send for real and preview the same letter:
  the `AshDispatch.Test.Preview` fixtures registered, receipts in ETS, Oban
  running jobs inline (no database), and every send captured by
  `AshDispatch.Test.CaptureBackend`.
  """
  use ExUnit.CaseTemplate

  @otp_app :ash_dispatch_preview_test

  @env [
    otp_app: @otp_app,
    domains: [AshDispatch.Test.Preview.Domain],
    delivery_receipt_resource: AshDispatch.Test.TransportReceipt,
    email_backend: AshDispatch.Test.CaptureBackend,
    recipient_fields: [
      email: [identifier: :email, name: :name],
      in_app: [identifier: :email]
    ],
    capture_pid: nil
  ]

  using do
    quote do
      import AshDispatch.Test.PreviewCase
    end
  end

  setup do
    previous = Enum.map(@env, fn {key, _} -> {key, Application.fetch_env(:ash_dispatch, key)} end)
    previous_domains = Application.fetch_env(@otp_app, :ash_domains)

    Enum.each(@env, fn {key, value} -> Application.put_env(:ash_dispatch, key, value) end)
    Application.put_env(:ash_dispatch, :capture_pid, self())
    Application.put_env(@otp_app, :ash_domains, [AshDispatch.Test.Preview.Domain])

    # The inline engine executes each job inside `Oban.insert/1`, in this
    # process. Not `testing: :inline`: that mode verifies the oban_jobs
    # migration, and this suite has no database. Everything that would touch
    # one is switched off instead.
    start_supervised!(
      {Oban,
       name: Oban,
       repo: AshDispatch.Test.Setup.Repo,
       engine: Oban.Engines.Inline,
       notifier: {Oban.Notifiers.Isolated, []},
       peer: {Oban.Peers.Isolated, [leader?: false]},
       plugins: [],
       queues: [],
       stager: false}
    )

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:ash_dispatch, key, value)
        {key, :error} -> Application.delete_env(:ash_dispatch, key)
      end)

      case previous_domains do
        {:ok, value} -> Application.put_env(@otp_app, :ash_domains, value)
        :error -> Application.delete_env(@otp_app, :ash_domains)
      end
    end)

    :ok
  end

  @doc "Creates a booking — which sends `booking.confirmed` through the notifier."
  def create_booking!(attrs \\ %{}) do
    AshDispatch.Test.Preview.Booking
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          reference: "B-#{System.unique_integer([:positive])}",
          guest_name: "Alva",
          guest_email: "alva@example.com"
        },
        attrs
      )
    )
    |> Ash.create!(authorize?: false)
  end

  @doc "Every email the capture backend received so far, oldest first."
  def sent_emails(acc \\ []) do
    receive do
      {:sent_email, params} -> sent_emails([params | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
