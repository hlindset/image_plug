defmodule ImagePipe.ImgproxyGenReportTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Test.ImgproxyDifferential.Constellations
  alias ImagePipe.Test.ImgproxyDifferential.OptsSummary
  alias ImagePipe.Test.ImgproxyDifferential.ReportHtml

  describe "OptsSummary.describe/1" do
    test "resize + gravity" do
      assert OptsSummary.describe("rs:fill:240:180/g:ce") ==
               "resize fill 240×180; gravity center"
    end

    test "compound gravity codes and absolute offset" do
      assert OptsSummary.describe("c:120:90/g:nowe") == "crop 120×90; gravity north-west"

      assert OptsSummary.describe("rs:fill:120:120/g:no:10:20") ==
               "resize fill 120×120; gravity north +10,+20"
    end

    test "trim, min-dims, zoom, dpr" do
      assert OptsSummary.describe("t:10") == "trim (threshold 10)"

      assert OptsSummary.describe("rs:fit:300:300/mw:280/mh:280") ==
               "resize fit 300×300; min-width 280; min-height 280"

      assert OptsSummary.describe("z:0.5") == "zoom 0.5"
      assert OptsSummary.describe("rs:fit:80:80/dpr:2") == "resize fit 80×80; dpr 2"
    end

    test "extend variants" do
      assert OptsSummary.describe("rs:fit:300:200/ex:1") == "resize fit 300×200; extend"

      assert OptsSummary.describe("rs:fit:300:200/ex:1:so") ==
               "resize fit 300×200; extend (south)"

      assert OptsSummary.describe("rs:fit:400:150/ex:1:we:5:0") ==
               "resize fit 400×150; extend (west +5,+0)"

      assert OptsSummary.describe("rs:fit:300:200/exar:1") ==
               "resize fit 300×200; extend-aspect-ratio"
    end

    test "background, blur, sharpen, strip, format, quality" do
      assert OptsSummary.describe("rs:fit:64:64/bg:255:0:0") ==
               "resize fit 64×64; background rgb(255,0,0)"

      assert OptsSummary.describe("rs:fit:240:240/bl:3") == "resize fit 240×240; blur 3"
      assert OptsSummary.describe("rs:fit:240:240/sh:2") == "resize fit 240×240; sharpen 2"

      assert OptsSummary.describe("rs:fit:120:120/sm:1") ==
               "resize fit 120×120; strip-metadata on"

      assert OptsSummary.describe("rs:fit:200:200/scp:0") ==
               "resize fit 200×200; strip-color-profile off"

      assert OptsSummary.describe("rs:fill:240:180/q:40/f:jpg") ==
               "resize fill 240×180; quality 40; format jpg"
    end

    test "padding" do
      assert OptsSummary.describe("rs:fit:120:120/pd:10:20") ==
               "resize fit 120×120; padding 10,20"
    end

    test "unknown segments echo verbatim" do
      assert OptsSummary.describe("rs:fit:64:64/wat:9") == "resize fit 64×64; wat:9"
    end
  end

  defp sample_doc do
    %{
      provenance: %{
        imgproxy_digest: "sha256:abc",
        imgproxy_libvips: "42.20.2",
        pipe_libvips_at_gen: "8.18.2",
        runtime_libvips: "8.18.2",
        skew?: false
      },
      cards: [
        %{
          id: "rs_fill_zone",
          group: :transform,
          verdict: :equal,
          url: "/unsafe/rs:fill:240:180/f:png/plain/local:///high_freq.jpg",
          summary: "resize fill 240×180",
          status: :pass,
          attention?: false,
          hash_drift?: false,
          triage: nil,
          tol: nil,
          metric_text: "0 band-bytes over Δ2 (budget 64)",
          imgproxy_img: "data:image/png;base64,AAAA",
          pipe_img: "data:image/png;base64,BBBB",
          heat_banded: "data:image/png;base64,CCCC",
          heat_raw: "data:image/png;base64,DDDD",
          pipe_dims: {240, 180},
          fixture_dims: {240, 180}
        },
        %{
          id: "extend_offset_east_marker",
          group: :transform,
          verdict: :equal,
          url: "/unsafe/rs:fit:400:150/ex:1:ea:20:0/f:png/plain/local:///marker.png",
          summary: "resize fit 400×150; extend (east +20,+0)",
          status: :over_budget,
          attention?: true,
          hash_drift?: false,
          triage: %{reason: "extend east offset sign", issue: "#200"},
          tol: nil,
          metric_text: "9001 band-bytes over Δ2 (budget 64)",
          imgproxy_img: "data:image/png;base64,EEEE",
          pipe_img: "data:image/png;base64,FFFF",
          heat_banded: "data:image/png;base64,GGGG",
          heat_raw: "data:image/png;base64,HHHH",
          pipe_dims: {400, 150},
          fixture_dims: {400, 150}
        },
        %{
          id: "lossy_avif",
          group: :lossy,
          verdict: :equal,
          url: "/unsafe/rs:fill:240:180/f:avif/plain/local:///high_freq.jpg",
          summary: "resize fill 240×180; format avif",
          status: :contract_ok,
          attention?: false,
          hash_drift?: false,
          triage: nil,
          tol: nil,
          metric_text:
            "dims 240×180 (expected 240×180); type \"image/avif\" (expected \"image/avif\")",
          imgproxy_img: nil,
          pipe_img: "data:image/avif;base64,IIII",
          heat_banded: nil,
          heat_raw: nil,
          pipe_dims: {240, 180},
          fixture_dims: nil
        }
      ]
    }
  end

  describe "ReportHtml.render/1" do
    test "emits a self-contained document with fonts + slider CDN" do
      html = ReportHtml.render(sample_doc())
      assert html =~ "<!doctype html>"
      assert html =~ "fonts.googleapis.com"
      assert html =~ "img-comparison-slider"
      assert html =~ "Geist"
    end

    test "renders a card anchor and metric per case" do
      html = ReportHtml.render(sample_doc())
      assert html =~ ~s(id="rs_fill_zone")
      assert html =~ "0 band-bytes over Δ2 (budget 64)"
      assert html =~ "resize fill 240×180"
    end

    test "triage issue is a clickable repo link" do
      html = ReportHtml.render(sample_doc())
      assert html =~ ~s(href="https://github.com/hlindset/image_pipe/issues/200")
      assert html =~ "extend east offset sign"
    end

    test "counts summary reflects groups and attention" do
      html = ReportHtml.render(sample_doc())
      assert html =~ "2 transform"
      assert html =~ "1 lossy"
      assert html =~ "1 attention"
    end

    test "lossy card omits imgproxy panel and heatmaps" do
      html = ReportHtml.render(sample_doc())
      refute html =~ "data:image/png;base64,IIII"
      assert html =~ "data:image/avif;base64,IIII"
    end

    test "global heatmap toggle + filter controls present" do
      html = ReportHtml.render(sample_doc())
      assert html =~ "data-heat"
      assert html =~ "data-filter"
    end
  end

  test "gen_report renders every constellation to a self-contained file" do
    out =
      Path.join(System.tmp_dir!(), "imgproxy_report_#{System.unique_integer([:positive])}.html")

    on_exit(fn -> File.rm_rf(out) end)

    Mix.Tasks.Imgproxy.GenReport.run(["--out", out])

    assert File.exists?(out)
    html = File.read!(out)

    for c <- Constellations.all() do
      assert html =~ ~s(id="#{c.id}"), "report missing card anchor for #{c.id}"
    end

    assert html =~ "band-bytes over Δ", "per-case metric text not rendered"
    # The quarantined cases surface their live over-budget divergence (the triage
    # state annotates, it does not suppress the metric).
    assert html =~ "over_budget", "expected quarantined cases to show over-budget divergence"

    assert html =~ "data:image/png;base64,", "no inlined PNG images in report"
    # alpha_resize / background_alpha exercise RGB band-alignment in the heatmap
    # path; the run must not crash on a band-count mismatch.
    assert html =~ "alpha_resize"
    assert html =~ "background_alpha"
  end
end
