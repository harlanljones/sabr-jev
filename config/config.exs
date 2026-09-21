import Config

config :sabr_jev, SabrJevWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: SabrJevWeb.ErrorHTML], layout: false],
  pubsub_server: SabrJev.PubSub,
  live_view: [signing_salt: "sabr-live-view"]

config :phoenix, :json_library, Jason

config :esbuild,
  version: "0.25.12",
  sabr_jev: [
    args: ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
