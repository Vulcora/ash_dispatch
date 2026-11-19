defmodule AshDispatch.DigestRenderer.Default do
  @moduledoc """
  The digest renderer used when the host has not configured one: a short,
  plain English letter listing each email's title, summary and link.

  It is meant to be replaced by a host with a mail design of its own (see
  `AshDispatch.DigestRenderer`); it is complete enough that a digest is
  never empty or unreadable if it is not.
  """

  @behaviour AshDispatch.DigestRenderer

  @impl true
  def render(items, info) do
    heading = "#{info.count} updates"

    %{
      subject: heading,
      html_body: html(heading, items),
      text_body: text(heading, items)
    }
  end

  defp html(heading, items) do
    entries =
      Enum.map_join(items, "\n", fn item ->
        title = escape(item["title"])
        summary = item["summary"] && "<p style=\"margin:4px 0 0\">#{escape(item["summary"])}</p>"

        link =
          case item["url"] do
            url when is_binary(url) and url != "" ->
              "<p style=\"margin:4px 0 0\"><a href=\"#{escape(url)}\">" <>
                "#{escape(item["label"] || "Open")}</a></p>"

            _ ->
              nil
          end

        "<li style=\"margin:0 0 16px\"><strong>#{title}</strong>#{summary}#{link}</li>"
      end)

    """
    <!DOCTYPE html>
    <html>
    <body style="font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;line-height:1.5;color:#1a1a1a">
    <h1 style="font-size:20px">#{escape(heading)}</h1>
    <ul style="padding-left:20px">
    #{entries}
    </ul>
    </body>
    </html>
    """
  end

  defp text(heading, items) do
    entries =
      Enum.map_join(items, "\n\n", fn item ->
        [
          "- " <> to_text(item["title"]),
          item["summary"] && "  " <> to_text(item["summary"]),
          is_binary(item["url"]) && item["url"] != "" && "  " <> item["url"]
        ]
        |> Enum.filter(&is_binary/1)
        |> Enum.join("\n")
      end)

    heading <> "\n\n" <> entries <> "\n"
  end

  defp to_text(nil), do: ""
  defp to_text(value), do: to_string(value)

  defp escape(nil), do: ""

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
