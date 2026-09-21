defmodule SabrJevWeb.Router do
  use SabrJevWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SabrJevWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", SabrJevWeb do
    pipe_through :browser

    live "/", WorkbenchLive
    live "/storylines", StorylinesLive
    live "/about", AboutLive
  end
end
