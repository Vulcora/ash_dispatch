defmodule AshDispatch.Transports.WebhookUrl do
  @moduledoc """
  Where the Slack and Discord transports post, and how the worker finds it.

  A Slack or Discord webhook URL is a bearer credential: whoever has it can
  post to the channel. Two places used to keep a copy of it that outlived the
  request:

    * the job args (`oban_jobs.args`), which are kept after the job completes
      and are readable by anyone who can read the Oban tables or a dashboard on
      them, and
    * the log, at every level, from `AshDispatch.Workers.SendWebhook`.

  `metadata.webhook_url_env` names an environment variable instead of carrying
  the URL, the same option `AshDispatch.Transports.Webhook` has had since 0.9.4.
  With it, the job carries only the NAME (`"webhook_url_env"`), and the worker
  reads the value when it sends. Rotating the URL then needs no recompile and
  no rewrite of queued jobs, and staging cannot post to production's channel
  through a URL baked in at compile time.

  An explicit `webhook_url` (on the channel or in `opts`) still works as
  before and still travels in the job args: it was compiled into the
  application already, so the job adds no new copy.
  """

  alias AshDispatch.Channel

  @typedoc "The job-args fragment that tells the worker where to post."
  @type target :: %{String.t() => String.t()}

  @doc """
  The job-args fragment for a channel, or why there is none.

    * `{:ok, %{"webhook_url" => url}}` — an explicit URL on the channel or in
      `opts`, as before.
    * `{:ok, %{"webhook_url_env" => name}}` — `metadata.webhook_url_env` names
      a variable that is set now. Only the name is returned.
    * `{:skip, reason}` — nothing to post to. `"No webhook_url configured"`
      when the channel names neither, as before; a reason naming the variable
      when it names one that is unset, so the receipt says which.

  The order is the one `AshDispatch.Transports.Webhook` uses: the channel's
  `webhook_url`, then `metadata.webhook_url_env`, then `opts["webhook_url"]`.
  """
  @spec target(Channel.t() | term()) :: {:ok, target()} | {:skip, String.t()}
  def target(%Channel{webhook_url: url}) when is_binary(url) and url != "",
    do: {:ok, %{"webhook_url" => url}}

  def target(%Channel{metadata: metadata} = channel) when is_map(metadata) do
    case env_name(metadata) do
      nil ->
        from_opts(channel)

      name ->
        if read_env(name),
          do: {:ok, %{"webhook_url_env" => name}},
          else: {:skip, "webhook_url_env #{name} is not set"}
    end
  end

  def target(channel), do: from_opts(channel)

  @doc """
  The URL a job posts to, read at send time.

  `"webhook_url"` wins when present (jobs enqueued before this option, and
  channels with an explicit URL). Otherwise the variable named by
  `"webhook_url_env"` is read now; `{:error, reason}` names the variable, never
  a value, when it is unset.
  """
  @spec resolve(map()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve(%{"webhook_url" => url}) when is_binary(url) and url != "", do: {:ok, url}

  def resolve(%{"webhook_url_env" => name}) when is_binary(name) and name != "" do
    case read_env(name) do
      nil -> {:error, "webhook_url_env #{name} is not set"}
      url -> {:ok, url}
    end
  end

  def resolve(_), do: {:error, "No webhook_url configured"}

  @doc """
  A URL as it may appear in a log line: scheme and host, nothing else.

  The secret part of a Slack or Discord webhook is the path, and a generic
  receiver can carry a token in the query or the user info, so only the
  scheme and host are kept. Anything that does not parse as a URL with a host
  is shown as `"[redacted]"`.
  """
  @spec mask(term()) :: String.t()
  def mask(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        scheme <> "://" <> host <> "/[redacted]"

      _ ->
        "[redacted]"
    end
  end

  def mask(_), do: "[redacted]"

  @doc """
  `text` with every occurrence of `url` replaced by its masked form.

  For log lines built from values the worker does not control — a response
  body that echoes the request, an exception message that names it.
  """
  @spec scrub(String.t(), String.t() | nil) :: String.t()
  def scrub(text, url) when is_binary(text) and is_binary(url) and url != "",
    do: String.replace(text, url, mask(url))

  def scrub(text, _url), do: text

  defp from_opts(%Channel{opts: opts}) when is_map(opts) do
    case opts["webhook_url"] || opts[:webhook_url] do
      url when is_binary(url) and url != "" -> {:ok, %{"webhook_url" => url}}
      _ -> {:skip, "No webhook_url configured"}
    end
  end

  defp from_opts(_), do: {:skip, "No webhook_url configured"}

  defp env_name(metadata) do
    case metadata[:webhook_url_env] || metadata["webhook_url_env"] do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp read_env(name) do
    case System.get_env(name) do
      url when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end
end
