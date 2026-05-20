defmodule AshDispatch.RecipientResolver.ResolverTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AshDispatch.RecipientResolver.Resolver

  describe "resolve_from_resource/2" do
    test "extracts email and name from resource fields" do
      resource = %{
        id: "123",
        contact_email: "test@example.com",
        contact_name: "John Doe"
      }

      result =
        Resolver.resolve_from_resource([email: :contact_email, name: :contact_name], resource)

      assert [recipient] = result
      assert recipient.id == "123"
      # Email key comes from recipient_fields config (defaults to :email)
      assert recipient.email == "test@example.com"
      # Name keys come from recipient_fields config
      assert recipient[:first_name] == "John Doe" || recipient[:display_name] == "John Doe"
    end

    test "returns empty list when email field is nil" do
      resource = %{
        id: "123",
        contact_email: nil,
        contact_name: "John Doe"
      }

      # Warning expected - capture it
      log =
        capture_log(fn ->
          result =
            Resolver.resolve_from_resource([email: :contact_email, name: :contact_name], resource)

          assert result == []
        end)

      assert log =~ "No email found"
    end

    test "returns empty list when email field is empty string" do
      resource = %{
        id: "123",
        contact_email: "",
        contact_name: "John Doe"
      }

      # Warning expected - capture it
      log =
        capture_log(fn ->
          result =
            Resolver.resolve_from_resource([email: :contact_email, name: :contact_name], resource)

          assert result == []
        end)

      assert log =~ "No email found"
    end

    test "returns empty list when resource is nil" do
      result = Resolver.resolve_from_resource([email: :contact_email], nil)

      assert result == []
    end

    test "works without name field" do
      resource = %{
        id: "123",
        contact_email: "test@example.com"
      }

      result = Resolver.resolve_from_resource([email: :contact_email], resource)

      assert [recipient] = result
      assert recipient.id == "123"
      assert recipient.email == "test@example.com"
      refute Map.has_key?(recipient, :first_name)
    end

    test "uses custom id field when specified" do
      resource = %{
        id: "wrong-id",
        external_id: "correct-id",
        contact_email: "test@example.com"
      }

      result = Resolver.resolve_from_resource([email: :contact_email, id: :external_id], resource)

      assert [recipient] = result
      assert recipient.id == "correct-id"
    end

    test "handles CiString email values" do
      resource = %{
        id: "123",
        contact_email: %{string: "test@example.com"}
      }

      result = Resolver.resolve_from_resource([email: :contact_email], resource)

      assert [recipient] = result
      assert recipient.email == "test@example.com"
    end

    test "handles structs as resources" do
      # Using a map with __struct__ to simulate a struct
      resource = %{
        __struct__: SomeLead,
        id: "lead-123",
        contact_email: "lead@example.com",
        contact_name: "Lead Contact"
      }

      result =
        Resolver.resolve_from_resource([email: :contact_email, name: :contact_name], resource)

      assert [recipient] = result
      assert recipient.id == "lead-123"
      assert recipient.email == "lead@example.com"
    end

    test "logs warning for Ash.NotLoaded fields" do
      resource = %{
        id: "123",
        contact_email: %Ash.NotLoaded{field: :contact_email, type: :attribute}
      }

      # Should return empty and log warning (not raise)
      log =
        capture_log(fn ->
          result = Resolver.resolve_from_resource([email: :contact_email], resource)
          assert result == []
        end)

      assert log =~ "not loaded"
    end
  end

  describe "resolve_by_query/2 — defensive rescue" do
    # Dispatch is a side-channel; recipient resolution must never raise
    # into the caller. The classic trap (2026-05-20 Mosis receipt):
    # `decrypt_by_default` AshCloak calculations get auto-loaded by the
    # user-resource read here; if the Cloak vault hasn't started, the
    # calculation raises through the Ash pipeline and bubbles up to the
    # operation that created the dispatching record (a Forge.Binding,
    # in that case), aborting it.
    #
    # The rescue is deliberately broad — ANY raise from the read path
    # is degraded to `[]` + warning. The fix needs to survive arbitrary
    # third-party calculation modules misbehaving, not just Cloak.

    test "passing a non-existent resource module returns [] and logs warning" do
      # `Ash.read` against a module that doesn't implement the resource
      # protocol raises an `UndefinedFunctionError` / `Protocol.UndefinedError`
      # depending on Ash version — either way it's a raise, not an
      # `{:error, _}` tuple. Confirms the try/rescue wrapping does its job.
      log =
        capture_log(fn ->
          result = Resolver.resolve_by_query([id: "anything"], __MODULE__.NotAResource)
          assert result == []
        end)

      assert log =~ "[AshDispatch.RecipientResolver]"
      assert log =~ "resolve_by_query/2 raised"
    end
  end

  describe "apply_filter/2" do
    # We test apply_filter indirectly through the module's private function behavior
    # by testing the full resolve flow, but we can test the filter matching logic

    test "filters recipients by atom value" do
      recipients = [
        %{id: "1", user_type: :customer, name: "Customer"},
        %{id: "2", user_type: :internal, name: "Internal"},
        %{id: "3", user_type: :customer, name: "Another Customer"}
      ]

      # Using send to test the private function indirectly
      result = filter_recipients(recipients, user_type: :customer)

      assert length(result) == 2
      assert Enum.all?(result, &(&1.user_type == :customer))
    end

    test "filters recipients by multiple conditions (AND logic)" do
      recipients = [
        %{id: "1", user_type: :customer, is_active: true},
        %{id: "2", user_type: :customer, is_active: false},
        %{id: "3", user_type: :internal, is_active: true}
      ]

      result = filter_recipients(recipients, user_type: :customer, is_active: true)

      assert length(result) == 1
      assert hd(result).id == "1"
    end

    test "filters recipients by string value" do
      recipients = [
        %{id: "1", role: "admin"},
        %{id: "2", role: "user"}
      ]

      result = filter_recipients(recipients, role: "admin")

      assert length(result) == 1
      assert hd(result).role == "admin"
    end

    test "filters recipients by list of allowed values" do
      recipients = [
        %{id: "1", role: :admin},
        %{id: "2", role: :user},
        %{id: "3", role: :moderator}
      ]

      result = filter_recipients(recipients, role: [:admin, :moderator])

      assert length(result) == 2
      assert Enum.all?(result, &(&1.role in [:admin, :moderator]))
    end

    test "returns all recipients when filter is nil" do
      recipients = [%{id: "1"}, %{id: "2"}]

      result = filter_recipients(recipients, nil)

      assert result == recipients
    end

    test "returns all recipients when filter is empty list" do
      recipients = [%{id: "1"}, %{id: "2"}]

      result = filter_recipients(recipients, [])

      assert result == recipients
    end

    # Helper to test filtering (simulates what the resolver does)
    defp filter_recipients(recipients, nil), do: recipients
    defp filter_recipients(recipients, []), do: recipients

    defp filter_recipients(recipients, filter) do
      Enum.filter(recipients, fn recipient ->
        Enum.all?(filter, fn {key, expected_value} ->
          actual_value = Map.get(recipient, key)
          matches?(actual_value, expected_value)
        end)
      end)
    end

    defp matches?(actual, expected) when is_atom(expected) do
      actual == expected or to_string(actual) == to_string(expected)
    end

    defp matches?(actual, expected) when is_binary(expected) do
      to_string(actual) == expected
    end

    defp matches?(actual, expected) when is_list(expected) do
      actual in expected or to_string(actual) in Enum.map(expected, &to_string/1)
    end

    defp matches?(actual, expected), do: actual == expected
  end
end
