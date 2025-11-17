defmodule AshDispatch.MixProject do
  use Mix.Project

  @version "0.1.0"
  @description "Event-driven notification system for Ash Framework with multiple transport types"
  @source_url "https://github.com/Vulcora/ash_dispatch"

  def project do
    [
      app: :ash_dispatch,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: @description,
      package: package(),
      deps: deps(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: @source_url,
      name: "AshDispatch",
      consolidate_protocols: Mix.env() != :dev
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Core dependencies
      {:ash, "~> 3.0"},
      {:ash_state_machine, "~> 0.2"},
      {:oban, "~> 2.0"},

      # Optional transport dependencies
      {:swoosh, "~> 1.16", optional: true},
      {:req, "~> 0.5", optional: true},

      # Development and testing
      {:ex_doc, "~> 0.34", only: [:dev, :test], runtime: false},
      {:jason, "~> 1.2"},
      {:smokestack, "~> 0.8", only: [:test]},
      {:faker, "~> 0.18", only: [:test]}
    ]
  end

  defp package do
    [
      name: "ash_dispatch",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      },
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      formatters: ["html"],
      extras: [
        "README.md",
        "CHANGELOG.md",
        "lib/documentation/tutorials/getting-started.md",
        "lib/documentation/topics/what-is-ash-dispatch.md",
        "lib/documentation/topics/recipient-resolution.md",
        "lib/documentation/topics/user-preferences.md",
        "lib/documentation/topics/oban-configuration.md"
      ],
      groups_for_extras: [
        Tutorials: ~r/documentation\/tutorials\/.*/,
        Topics: ~r/documentation\/topics\/.*/
      ],
      groups_for_modules: [
        "Core": [
          AshDispatch,
          AshDispatch.Event,
          AshDispatch.Dispatcher,
          AshDispatch.Context,
          AshDispatch.Channel
        ],
        "Transports": [
          AshDispatch.Transports,
          AshDispatch.Transports.Email,
          AshDispatch.Transports.InApp,
          AshDispatch.Transports.SMS,
          AshDispatch.Transports.Webhook,
          AshDispatch.Transports.Discord,
          AshDispatch.Transports.Slack
        ],
        "Email Backend": [
          AshDispatch.EmailBackend,
          AshDispatch.EmailBackend.Mock,
          AshDispatch.EmailBackend.Swoosh
        ],
        "Workers": [
          AshDispatch.Workers.SendEmail,
          AshDispatch.Workers.SendWebhook,
          AshDispatch.Workers.RetryFailedDeliveries
        ],
        "Resources": [
          AshDispatch.Resources.DeliveryReceipt,
          AshDispatch.Resources.Notification
        ],
        "Behaviours & Plugins": [
          AshDispatch.RecipientResolver,
          AshDispatch.UserPreference,
          AshDispatch.Event.Interpolation
        ],
        "DSL & Extensions": [
          AshDispatch.Resource,
          AshDispatch.Resource.Dsl,
          AshDispatch.Dsl.Sections
        ],
        "Testing": [
          AshDispatch.Test.RecipientResolver,
          AshDispatch.Test.UserPreference
        ]
      ],
      before_closing_head_tag: &before_closing_head_tag/1,
      before_closing_body_tag: &before_closing_body_tag/1
    ]
  end

  # Inject custom CSS for better docs appearance
  defp before_closing_head_tag(:html) do
    """
    <style>
      .sidebar-listNav-list > li > a.sidebar-projectName {
        font-size: 1.2em;
        font-weight: 700;
        color: #2563eb;
      }
      .content-inner h1, .content-inner h2, .content-inner h3 {
        border-bottom: 1px solid #e5e7eb;
        padding-bottom: 0.3em;
      }
    </style>
    """
  end

  defp before_closing_head_tag(_), do: ""

  defp before_closing_body_tag(:html) do
    """
    <script>
      // Add copy buttons to code blocks
      document.querySelectorAll('pre code').forEach(function(block) {
        if (!block.parentElement.querySelector('.copy-button')) {
          const button = document.createElement('button');
          button.className = 'copy-button';
          button.textContent = 'Copy';
          button.onclick = function() {
            navigator.clipboard.writeText(block.textContent);
            button.textContent = 'Copied!';
            setTimeout(() => button.textContent = 'Copy', 2000);
          };
          block.parentElement.style.position = 'relative';
          block.parentElement.appendChild(button);
        }
      });
    </script>
    """
  end

  defp before_closing_body_tag(_), do: ""
end
