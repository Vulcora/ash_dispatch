defmodule AshDispatch.Notifier.DispatchHandlerEndpointUnstartedTest do
  @moduledoc """
  Mosis cycle (N+8) Mission 2 canary — `DispatchHandler.dispatch/2`
  must not crash when the configured Phoenix endpoint module is set
  but its `:persistent_term` registry is unpopulated (e.g. mix-task
  BEAM where `Endpoint.start_link/1` was never called).

  Repro: `mix mosis.research.market_blind_retrospective` starts the
  Repo via `Mosis.ScriptHarness.start_repo!/0` but does NOT start
  `MosisWeb.Endpoint`. AshDispatch is configured with
  `endpoint: MosisWeb.Endpoint` so `Config.endpoint()` returns the
  module. `endpoint.url()` then calls `Phoenix.Config.cache/3` which
  raises `RuntimeError: could not find persistent term for endpoint
  MosisWeb.Endpoint. Make sure your endpoint is started`.

  The Logger.error inside `DispatchHandler.dispatch/2`'s rescue
  swallows the error (the notification doesn't fail), but the warning
  spam pollutes every retrospective stdout. Defensive fix: detect the
  raise inside `get_base_url/0` and fall through to the PHX_HOST /
  Config.base_url() / localhost cascade silently.

  This canary directly invokes the (private-via-erlang-trickery)
  `get_base_url/0` is awkward; instead we exercise the public
  `dispatch/2` path with a fake notification + endpoint module that
  raises the canonical Phoenix.Config error, and assert no exception
  bubbles out and no error log fires for the URL-fetch step.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AshDispatch.Notifier.DispatchHandler

  defmodule UnstartedEndpoint do
    @moduledoc false
    # Mirrors the Phoenix.Endpoint behaviour just for `url/0`. Raises
    # the exact message Phoenix raises when persistent_term is empty.
    def url do
      raise RuntimeError,
            "could not find persistent term for endpoint " <>
              "AshDispatch.Notifier.DispatchHandlerEndpointUnstartedTest.UnstartedEndpoint. " <>
              "Make sure your endpoint is started"
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  defmodule Resource do
    @moduledoc false
    use Ash.Resource,
      domain: AshDispatch.Notifier.DispatchHandlerEndpointUnstartedTest.Domain,
      data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key :id
      attribute :title, :string, public?: true
    end

    actions do
      defaults [:read, :destroy]
      default_accept :*
      create :create
    end
  end

  setup do
    prior_endpoint = Application.get_env(:ash_dispatch, :endpoint)
    Application.put_env(:ash_dispatch, :endpoint, UnstartedEndpoint)

    on_exit(fn ->
      case prior_endpoint do
        nil -> Application.delete_env(:ash_dispatch, :endpoint)
        v -> Application.put_env(:ash_dispatch, :endpoint, v)
      end
    end)

    :ok
  end

  test "DispatchHandler.dispatch/2 does not log endpoint-not-started error when endpoint is configured but unstarted" do
    {:ok, record} =
      Resource
      |> Ash.Changeset.for_create(:create, %{title: "canary"})
      |> Ash.create()

    changeset = Ash.Changeset.for_create(Resource, :create, %{title: "canary"})

    notification = %Ash.Notifier.Notification{
      resource: Resource,
      changeset: changeset,
      data: record,
      action: %{name: :create, type: :create}
    }

    config = %{
      event_id: :test_endpoint_unstarted_event,
      event_config: %{
        data_key: :resource,
        channels: []
      }
    }

    log =
      capture_log(fn ->
        # Should not raise. Should not log the
        # "could not find persistent term for endpoint" RuntimeError.
        assert :ok = DispatchHandler.dispatch(notification, config)
      end)

    refute log =~ "could not find persistent term for endpoint",
           "Expected DispatchHandler.dispatch/2 to swallow the unstarted-endpoint " <>
             "raise inside get_base_url/0 and fall through to the PHX_HOST / " <>
             "Config.base_url() / localhost cascade silently. Got log:\n#{log}"

    refute log =~ "Make sure your endpoint is started",
           "Expected no Phoenix-endpoint-not-started warning in log; got:\n#{log}"
  end
end
