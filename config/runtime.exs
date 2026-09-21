import Config

if System.get_env("PHX_SERVER") do
  config :sabr_jev, SabrJevWeb.Endpoint, server: true
end

if config_env() == :prod do
  secret_key_base = System.fetch_env!("SECRET_KEY_BASE")
  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :sabr_jev, SabrJevWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base
end
