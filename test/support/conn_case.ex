defmodule SabrJevWeb.ConnCase do
  @moduledoc "HTTP and LiveView test setup; no database or API credentials required."
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint SabrJevWeb.Endpoint
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
