defmodule AshDispatch.Test.Mailer do
  @moduledoc """
  Test mailer for AshDispatch email tests.

  Uses Swoosh's Test adapter to capture sent emails without actually sending them.
  """
  use Swoosh.Mailer, otp_app: :ash_dispatch
end
