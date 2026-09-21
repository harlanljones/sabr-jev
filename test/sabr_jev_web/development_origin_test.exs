defmodule SabrJevWeb.DevelopmentOriginTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import ExUnit.CaptureLog

  setup_all do
    # Read development settings without changing the running test endpoint.
    config =
      Config.Reader.read!(Path.expand("../../config/config.exs", __DIR__), env: :dev)

    endpoint_config = config |> Keyword.fetch!(:sabr_jev) |> Keyword.fetch!(SabrJevWeb.Endpoint)

    %{origin_options: Keyword.take(endpoint_config, [:check_origin])}
  end

  for origin <- ["http://localhost:4000", "http://127.0.0.1:4000"] do
    test "development permits the #{origin} WebSocket origin", %{origin_options: options} do
      conn = check_origin(unquote(origin), options)

      refute conn.halted
      refute conn.status == 403
    end
  end

  test "development rejects an external WebSocket origin", %{origin_options: options} do
    capture_log(fn ->
      conn = check_origin("https://example.com", options)

      assert conn.halted
      assert conn.status == 403
    end)
  end

  defp check_origin(origin, options) do
    Plug.Test.conn(:get, "http://127.0.0.1:4000/live/websocket")
    |> put_req_header("origin", origin)
    |> Phoenix.Socket.Transport.check_origin(
      Phoenix.LiveView.Socket,
      SabrJevWeb.Endpoint,
      options
    )
  end
end
