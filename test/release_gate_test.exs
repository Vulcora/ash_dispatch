defmodule AshDispatch.ReleaseGateTest do
  @moduledoc """
  Merging to main publishes to hex, so what guards a release is written down in
  the workflows and has to stay there. A release must not go out unless the
  tests that run SQL have run.
  """
  use ExUnit.Case, async: true

  @publish File.read!(".github/workflows/publish.yml")

  test "a push to main does not publish: only a successful CI run on main does" do
    refute @publish =~ ~r/^  push:/m
    assert @publish =~ ~r/workflow_run:\s+workflows: \[CI\]\s+types: \[completed\]/
    assert @publish =~ "branches: [main]"
    assert @publish =~ "github.event.workflow_run.conclusion == 'success'"
    assert @publish =~ "github.event.workflow_run.event == 'push'"
  end

  test "it publishes the commit CI tested" do
    assert @publish =~ "ref: ${{ github.event.workflow_run.head_sha || github.sha }}"
  end

  test "a manual run tests against Postgres too" do
    assert @publish =~ "image: postgres:16"
    assert @publish =~ "ASH_DISPATCH_TEST_DATABASE_URL:"
  end

  test "CI's test job is named test, which the required check on main names" do
    assert File.read!(".github/workflows/ci.yml") =~ ~r/^  test:$/m
  end

  test "the test suite refuses to skip the Postgres tests in CI" do
    helper = File.read!("test/test_helper.exs")

    assert helper =~ ~s|System.get_env("CI")|
    assert helper =~ "raise"
  end

  test "{:cancel, reason} needs Oban 2.12" do
    assert {:oban, "~> 2.12"} in Mix.Project.config()[:deps]
  end
end
