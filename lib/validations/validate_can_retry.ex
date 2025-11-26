defmodule AshDispatch.Validations.ValidateCanRetry do
  @moduledoc """
  Validates that a delivery receipt can be retried.

  Checks:
  - Receipt is in :failed status (state machine handles this)
  - retry_count is less than max_retries (5)
  """

  use Ash.Resource.Validation

  @max_retries 5

  @impl true
  def validate(changeset, _opts, _context) do
    retry_count = Ash.Changeset.get_attribute(changeset, :retry_count) || 0

    if retry_count >= @max_retries do
      {:error,
       field: :retry_count,
       message: "cannot retry: maximum retry attempts (#{@max_retries}) exceeded"}
    else
      :ok
    end
  end
end
