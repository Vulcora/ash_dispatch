defmodule AshDispatch.Changes.PutDigest do
  @moduledoc false
  # Writes a receipt's digest bookkeeping under `content["digest"]`: the whole
  # map on `:batch` (window, batched_at, item), and the digest receipt's id on
  # `:mark_digested`.
  #
  # The content may hold atom keys (a receipt created in this process) or
  # string keys (one read back from JSONB). Both spellings of `digest` are
  # removed before the string one is written, so the map never carries the
  # same key twice — which would encode as a JSON object with a duplicate key.
  use Ash.Resource.Change

  alias AshDispatch.ContentMap

  @impl true
  def change(changeset, _opts, _context) do
    content = Ash.Changeset.get_attribute(changeset, :content) || %{}
    current = ContentMap.get_content(content, :digest) || %{}

    digest =
      case {Ash.Changeset.get_argument(changeset, :digest),
            Ash.Changeset.get_argument(changeset, :digest_receipt_id)} do
        {%{} = digest, _} -> stringify(digest)
        {nil, id} when is_binary(id) -> current |> stringify() |> Map.put("receipt_id", id)
        _ -> stringify(current)
      end

    content =
      content
      |> Map.delete(:digest)
      |> Map.delete("digest")
      |> Map.put("digest", digest)

    Ash.Changeset.change_attribute(changeset, :content, content)
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
