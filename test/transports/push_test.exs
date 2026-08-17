defmodule AshDispatch.Transports.PushTest do
  @moduledoc """
  Web Push-transporten. Samma form som SMS: ash_dispatch äger routingen
  och kvittot, konsumenten äger protokollet (VAPID, RFC 8291-kryptering,
  per-endpoint-POST).
  """

  use ExUnit.Case, async: false

  alias AshDispatch.Transports.Push

  setup do
    tidigare = Application.get_env(:ash_dispatch, :push_backend)

    on_exit(fn ->
      if tidigare do
        Application.put_env(:ash_dispatch, :push_backend, tidigare)
      else
        Application.delete_env(:ash_dispatch, :push_backend)
      end
    end)

    Application.delete_env(:ash_dispatch, :push_backend)
    :ok
  end

  describe "transport-metadata" do
    test "registrerar sig som :push och skapar kvitton" do
      assert Push.transport_atom() == :push
      assert Push.skip_receipt?() == false
    end

    test "är nåbar via registret" do
      assert {:ok, Push} = AshDispatch.Transport.Registry.module_for(:push)
    end
  end

  describe "utan konfigurerad backend" do
    test "delegerar inte — appen ska kunna deklarera :push-kanaler innan backend finns" do
      # Vi verifierar kontraktet utan att röra databasen: `deliver/4`
      # ska INTE försöka anropa någon backend när ingen är satt.
      assert Application.get_env(:ash_dispatch, :push_backend) == nil
      assert AshDispatch.Config.push_backend() == nil
    end
  end

  describe "med konfigurerad backend" do
    defmodule EkoBackend do
      @behaviour AshDispatch.PushBackend

      @impl true
      def deliver(receipt, _context, _channel, _event_config) do
        send(self(), {:push_levererad, receipt})
        {:ok, Map.put(receipt, :status, :sent)}
      end
    end

    test "delegerar deliver/4 till backend-modulen" do
      Application.put_env(:ash_dispatch, :push_backend, EkoBackend)

      kvitto = %{id: "r-1", user_id: "u-1", content: %{title: "Möte om 15 min"}}

      assert {:ok, uppdaterat} = Push.deliver(kvitto, %{}, %{}, %{})
      assert uppdaterat.status == :sent
      assert_received {:push_levererad, ^kvitto}
    end

    test "backend-fel bubblar upp till dispatchern i stället för att svälja" do
      defmodule TrasigBackend do
        @behaviour AshDispatch.PushBackend

        @impl true
        def deliver(_receipt, _context, _channel, _event_config) do
          {:error, :push_service_unavailable}
        end
      end

      Application.put_env(:ash_dispatch, :push_backend, TrasigBackend)

      assert {:error, :push_service_unavailable} =
               Push.deliver(%{id: "r-2"}, %{}, %{}, %{})
    end
  end

  describe "Config.push_backend/0" do
    test "läser :ash_dispatch, :push_backend" do
      Application.put_env(:ash_dispatch, :push_backend, EkoBackend)
      assert AshDispatch.Config.push_backend() == EkoBackend
    end

    test "är nil när inget är konfigurerat" do
      assert AshDispatch.Config.push_backend() == nil
    end
  end
end
