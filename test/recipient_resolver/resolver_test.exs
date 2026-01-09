defmodule AshDispatch.RecipientResolver.ResolverTest do
  use ExUnit.Case, async: true

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

      result =
        Resolver.resolve_from_resource([email: :contact_email, name: :contact_name], resource)

      assert result == []
    end

    test "returns empty list when email field is empty string" do
      resource = %{
        id: "123",
        contact_email: "",
        contact_name: "John Doe"
      }

      result =
        Resolver.resolve_from_resource([email: :contact_email, name: :contact_name], resource)

      assert result == []
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
      result = Resolver.resolve_from_resource([email: :contact_email], resource)

      assert result == []
    end
  end
end
