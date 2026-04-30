defmodule JudiciaryWeb.PageControllerTest do
  use JudiciaryWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)
    assert response =~ "Judiciary"
    assert response =~ "Virtual Court"
    assert response =~ "System"
  end
end
