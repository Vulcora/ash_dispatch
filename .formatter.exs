# Formatter configuration for AshDispatch
# Projects using AshDispatch can import this config via:
#   import_deps: [:ash_dispatch]

locals_without_parens = [
  # Main DSL entities
  event: 2,
  counter: 2,

  # Event options
  trigger_on: 1,
  module: 1,
  event_id: 1,
  load: 1,
  domain: 1,
  data_key: 1,
  template_path: 1,
  channels: 1,
  content: 1,
  metadata: 1,
  recipient: 1,
  recipient_filter: 1,
  manual_trigger_filter: 1,
  should_send_filter: 1,

  # Counter options
  counter_name: 1,
  resource: 1,
  query_filter: 1,
  invalidates: 1,

  # Channel options (inline)
  transport: 1,
  audience: 1,
  delay: 1,
  policy: 1,
  variant: 1,
  webhook_url: 1,

  # Content options (inline)
  subject: 1,
  notification_title: 1,
  notification_message: 1,
  action_url: 1,
  title: 1,
  message: 1,
  body: 1,
  template: 1,
  from_email: 1,

  # Metadata options (inline)
  notification_type: 1,
  action_required: 1,
  user_configurable: 1
]

[
  import_deps: [:ash],
  inputs: ["{mix,.formatter}.exs", "{lib,test}/**/*.{ex,exs}"],
  locals_without_parens: locals_without_parens,
  export: [
    locals_without_parens: locals_without_parens
  ]
]
