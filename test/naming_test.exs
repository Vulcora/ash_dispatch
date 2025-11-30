defmodule AshDispatch.NamingTest do
  use ExUnit.Case, async: true

  alias AshDispatch.Naming

  describe "filename/4" do
    test "generates basic filename with audience" do
      assert Naming.filename("email", :user, nil, "html") == "email.user.html"
      assert Naming.filename("email", :admin, nil, "txt") == "email.admin.txt"
    end

    test "includes variant when different from audience" do
      assert Naming.filename("email", :admin, "summary", "html") == "email.admin.summary.html"
      assert Naming.filename("email", :user, "urgent", "txt") == "email.user.urgent.txt"
    end

    test "omits variant when it matches audience (deduplication)" do
      # When variant equals audience, don't repeat it
      assert Naming.filename("email", :admin, "admin", "html") == "email.admin.html"
      assert Naming.filename("email", :user, "user", "txt") == "email.user.txt"
    end

    test "handles atom variants" do
      assert Naming.filename("email", :admin, :summary, "html") == "email.admin.summary.html"
      assert Naming.filename("email", :admin, :admin, "html") == "email.admin.html"
    end

    test "handles nil audience" do
      assert Naming.filename("email", nil, nil, "html") == "email.html"
      assert Naming.filename("email", nil, "variant", "html") == "email.variant.html"
    end
  end

  describe "label/3" do
    test "generates basic label with audience" do
      assert Naming.label(:email, :user, nil) == "email (user)"
      assert Naming.label(:email, :admin, nil) == "email (admin)"
    end

    test "includes variant when different from audience" do
      assert Naming.label(:email, :admin, "summary") == "email (admin, summary)"
      assert Naming.label(:sms, :user, "urgent") == "sms (user, urgent)"
    end

    test "omits variant when it matches audience (deduplication)" do
      assert Naming.label(:email, :admin, "admin") == "email (admin)"
      assert Naming.label(:email, :user, "user") == "email (user)"
    end

    test "handles nil transport defaults to email" do
      assert Naming.label(nil, :user, nil) == "email (user)"
    end

    test "handles nil audience defaults to user" do
      assert Naming.label(:email, nil, nil) == "email (user)"
    end
  end

  describe "include_variant?/2" do
    test "returns false when variant is nil" do
      refute Naming.include_variant?(:user, nil)
      refute Naming.include_variant?(:admin, nil)
    end

    test "returns false when variant equals audience" do
      refute Naming.include_variant?(:admin, "admin")
      refute Naming.include_variant?(:admin, :admin)
      refute Naming.include_variant?(:user, "user")
    end

    test "returns true when variant differs from audience" do
      assert Naming.include_variant?(:admin, "summary")
      assert Naming.include_variant?(:user, "urgent")
      assert Naming.include_variant?(:admin, :internal)
    end
  end

  describe "variant_parts/2" do
    test "returns empty list when variant is nil" do
      assert Naming.variant_parts(:user, nil) == []
    end

    test "returns empty list when variant equals audience" do
      assert Naming.variant_parts(:admin, "admin") == []
    end

    test "returns variant in list when different from audience" do
      assert Naming.variant_parts(:admin, "summary") == ["summary"]
      assert Naming.variant_parts(:user, :urgent) == ["urgent"]
    end
  end
end
