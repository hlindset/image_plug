defmodule ImagePlug.Runtime.ResponseDispositionTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan.Response
  alias ImagePlug.Plan.Response.Filename
  alias ImagePlug.Runtime.ResponseDisposition

  test "renders attachment with ASCII filename parameters" do
    response = %Response{disposition: :attachment, filename: %Filename{stem: "report"}}

    assert ResponseDisposition.render(response, "image/webp") ==
             {:ok, ~s(attachment; filename="report.webp"; filename*=UTF-8''report.webp)}
  end

  test "renders deterministic ASCII fallback and UTF-8 filename star" do
    response = %Response{disposition: :inline, filename: %Filename{stem: "katt-æøå"}}

    assert ResponseDisposition.render(response, "image/webp") ==
             {:ok,
              ~s(inline; filename="katt-___.webp"; filename*=UTF-8''katt-%C3%A6%C3%B8%C3%A5.webp)}
  end

  test "uses download fallback when ASCII fallback becomes empty" do
    response = %Response{disposition: :inline, filename: %Filename{stem: "東京"}}

    assert ResponseDisposition.render(response, "image/png") ==
             {:ok, ~s(inline; filename="download.png"; filename*=UTF-8''%E6%9D%B1%E4%BA%AC.png)}
  end

  test "rejects unsupported cached content type for delivery filename extension" do
    response = %Response{disposition: :inline, filename: %Filename{stem: "report"}}

    assert ResponseDisposition.render(response, "image/gif") ==
             {:error, {:unsupported_delivery_content_type, "image/gif"}}
  end
end
