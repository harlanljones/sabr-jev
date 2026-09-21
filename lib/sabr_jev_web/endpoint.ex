defmodule SabrJevWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :sabr_jev

  @session_options [
    store: :cookie,
    key: "_sabr_jev_key",
    signing_salt: "sabr-session",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false

  plug Plug.Static,
    at: "/",
    from: :sabr_jev,
    gzip: not code_reloading?,
    only: SabrJevWeb.static_paths()

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
  plug Plug.Parsers, parsers: [:urlencoded, :multipart, :json], pass: ["*/*"], json_decoder: Jason
  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug SabrJevWeb.Router
end
