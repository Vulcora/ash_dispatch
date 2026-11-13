defmodule AshDispatch.Tenancy.MinimalArgsTest do
  @moduledoc """
  `job_args: :minimal` is the default when receipts are per tenant, and it made
  a shape that only sensitive events had — a job with no rendered message in it
  — universal. Two things were keyed on the event rather than on the shape:

  - the guard that refuses an empty letter. It read
    `Transports.Email.sensitive?/1`, so for every other event the worker sent
    whatever the receipt happened to hold, including nothing, and recorded it
    `:sent`.
  - the From display name. `:full` args carry
    `%{"name" => ..., "email" => ...}`; `:minimal` args carry no `"from"` at
    all, and the fallback answered the bare address — so the same host's mail
    went out as `noreply@acme.test` under `:minimal` and
    `Acme Bookings <noreply@acme.test>` under `:full`.
  """
  use AshDispatch.Test.PerTenantCase, async: false

  alias AshDispatch.Transports.Email
  alias AshDispatch.Workers.SendEmail

  @moduletag :postgres
  @moduletag :capture_log

  test ":minimal is the default when receipts are per tenant" do
    assert AshDispatch.Config.job_args() == :minimal
  end

  describe "an empty letter" do
    test "is not sent, and not recorded as sent" do
      receipt =
        receipt!("tenant_a", %{
          status: :scheduled,
          subject: nil,
          body_text: nil,
          body_html: nil
        })

      result =
        SendEmail.perform(%Oban.Job{
          args: %{"receipt_id" => receipt.id, "tenant" => "tenant_a"},
          attempt: 1
        })

      assert {:cancel, reason} = result
      assert reason =~ "nothing to send"
      assert sent_emails() == []

      reloaded = Ash.get!(PerTenant.Receipt, receipt.id, authorize?: false, tenant: "tenant_a")
      refute reloaded.status == :sent
    end

    test "nor is one whose body the scrub took, whatever the event" do
      receipt =
        receipt!("tenant_a", %{
          status: :scheduled,
          body_text: AshDispatch.Workers.ScrubSensitiveContent.marker(),
          body_html: nil
        })

      assert {:cancel, reason} =
               SendEmail.perform(%Oban.Job{
                 args: %{"receipt_id" => receipt.id, "tenant" => "tenant_a"},
                 attempt: 1
               })

      assert reason =~ "scrubbed"
      assert sent_emails() == []
    end
  end

  describe "what still goes out" do
    test "a letter the receipt holds" do
      receipt = receipt!("tenant_a", %{status: :scheduled})

      assert :ok =
               SendEmail.perform(%Oban.Job{
                 args: %{"receipt_id" => receipt.id, "tenant" => "tenant_a"},
                 attempt: 1
               })

      assert [%{text_body: "The meeting moved"}] = sent_emails()
    end

    test "a subject-only letter, which is thin but is a letter" do
      receipt =
        receipt!("tenant_a", %{status: :scheduled, body_text: nil, body_html: nil})

      assert :ok =
               SendEmail.perform(%Oban.Job{
                 args: %{"receipt_id" => receipt.id, "tenant" => "tenant_a"},
                 attempt: 1
               })

      assert [%{subject: "Meeting"}] = sent_emails()
    end

    test "a job that carries its own body, whatever the receipt holds" do
      receipt =
        receipt!("tenant_a", %{
          status: :scheduled,
          subject: nil,
          body_text: nil,
          body_html: nil
        })

      assert :ok =
               SendEmail.perform(%Oban.Job{
                 args: %{
                   "receipt_id" => receipt.id,
                   "tenant" => "tenant_a",
                   "text_body" => "from the job"
                 },
                 attempt: 1
               })

      assert [%{text_body: "from the job"}] = sent_emails()
    end
  end

  describe "the From field" do
    setup do
      Application.put_env(:ash_dispatch, :default_from_name, "Acme Bookings")
      Application.put_env(:ash_dispatch, :default_from_email, "noreply@acme.test")

      on_exit(fn ->
        Application.delete_env(:ash_dispatch, :default_from_name)
        Application.delete_env(:ash_dispatch, :default_from_email)
        Application.delete_env(:ash_dispatch, :job_args)
      end)

      :ok
    end

    test "carries the configured display name under both args shapes" do
      receipt = receipt!("tenant_a", %{status: :scheduled})
      context = %{event_id: receipt.event_id}

      Application.put_env(:ash_dispatch, :job_args, :full)
      full = SendEmail.email_params(receipt, stringify(Email.job_args(receipt, context, %{})))

      Application.put_env(:ash_dispatch, :job_args, :minimal)
      minimal = SendEmail.email_params(receipt, stringify(Email.job_args(receipt, context, %{})))

      assert full.from == {"Acme Bookings", "noreply@acme.test"}
      assert minimal.from == full.from
    end

    test "and the event's own from still wins" do
      receipt =
        receipt!("tenant_a", %{
          status: :scheduled,
          content: %{"from" => %{"name" => "Bookings", "email" => "bookings@acme.test"}}
        })

      params = SendEmail.email_params(receipt, %{})

      assert params.from == {"Bookings", "bookings@acme.test"}
    end
  end

  defp stringify(args), do: args |> Jason.encode!() |> Jason.decode!()
end
