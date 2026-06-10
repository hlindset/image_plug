defmodule ImagePipe.ImgproxyGenReportTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Test.ImgproxyDifferential.OptsSummary

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
end
