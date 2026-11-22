defmodule AshDispatch.Changes.PutReasonCode do
  @moduledoc false
  # Writes `content["reason_code"]` beside the `error_message` a receipt is
  # being given: one of `AshDispatch.Reason.codes/0` for a reason the library
  # wrote, `:other` for anything else.
  #
  # On the receipt's own `change` rather than in `AshDispatch.ReceiptStatus`,
  # so a host that moves a receipt through `:skip` or `:mark_failed` itself —
  # from an admin action, a transport of its own — gets the code too, and the
  # library has exactly one place that decides it.
  #
  # Does nothing when the action carries no `error_message`: a `:skip` without
  # a reason had no reason before either.
  use Ash.Resource.Change

  alias AshDispatch.Reason

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.fetch_change(changeset, :error_message) do
      {:ok, message} when is_binary(message) and message != "" ->
        content = Ash.Changeset.get_attribute(changeset, :content) || %{}
        Ash.Changeset.change_attribute(changeset, :content, Reason.put(content, message))

      _ ->
        changeset
    end
  end
end
