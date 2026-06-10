defmodule ImagePipeFiddleWeb.PageController do
  use ImagePipeFiddleWeb, :controller

  def home(conn, _params) do
    render(conn, :home, layout: false)
  end
end
