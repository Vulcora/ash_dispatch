defmodule AshDispatch.SetupTest do
  # The modules under test are compiled with the suite — see
  # test/support/test_setup.ex.
  use ExUnit.Case, async: true

  alias AshDispatch.Test.Setup

  @receipt Setup.Deliveries.DeliveryReceipt

  test "defines the receipt inside the domain it is used in" do
    assert Ash.Resource.Info.domain(@receipt) == Setup.Deliveries
    assert @receipt in Ash.Domain.Info.resources(Setup.Deliveries)
  end

  test "builds on DeliveryReceipt.Base, not a copy of it" do
    # The hand-copied resource Setup used to generate lacked these.
    for action <- [:get_by_provider_id, :send_now, :record_webhook_event, :reopen] do
      assert Ash.Resource.Info.action(@receipt, action), "missing #{inspect(action)}"
    end
  end

  test "relates to the given resources, with aliases resolved in the domain" do
    destinations =
      @receipt
      |> Ash.Resource.Info.relationships()
      |> Map.new(&{&1.name, &1.destination})

    assert destinations == %{notification: Setup.Notification, user: Setup.User}
  end

  # This suite always has ash_typescript; the app without it is the CI job
  # `installer`, which compiles a Setup domain in exactly such an app.
  test "is a TypeScript resource, with a type name, when ash_typescript is installed" do
    assert AshTypescript.Resource in Spark.extensions(@receipt)
    assert AshTypescript.Resource.Info.typescript_type_name(@receipt) == {:ok, "DeliveryReceipt"}
  end

  test "names a missing required option" do
    assert_raise ArgumentError, ~r/:notification_resource/, fn ->
      Code.compile_quoted(
        quote do
          defmodule AshDispatch.Test.Setup.Incomplete do
            use AshDispatch.Setup, repo: AshDispatch.Test.Setup.Repo
          end
        end
      )
    end
  end
end
