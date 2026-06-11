%{
  imgproxy_digest: "sha256:9ed8f87b34d55c7844951ff65bcf6605de54ba6670f64951c7215f9b125a482e",
  imgproxy_libvips: "42.20.2",
  pipe_libvips_at_gen: "8.18.2",
  sources: %{
    "alpha.png" => "7ef18f9ce1e08b6752fa8e55caf0819882d3779b997b65ec7a6c0c45e3a75fee",
    "border.png" => "350a6d992b4204dc619ccc492475ced70509b9f350fb7aed6f6156cb5efe1952",
    "exif.jpg" => "ffc9f345632012165b7c80950b5d97999c370cc8f434995e52f58099fc675905",
    "high_freq.jpg" => "54ded6c57ec02c685e275276b54947f8c9345015342fc8a2acc9d8e54e4a7d43",
    "high_freq.webp" => "32d8e080d7e440b6329a441d2913222906d320bdeb060e956eb68a297c51df18",
    "icc_p3.png" => "80ce9bc055c01a12a9d8bf3db1693a1b46995f66bfdb796503636122de264869",
    "marker.png" => "cbb47b49a36fc7a8b37233c862e1d4b88174ec6bf81876223779b4ce3c52120d",
    "small.png" => "517719b9e7ad77f867266b8c4e135d383cdc94c3bf14f7bc26c2060a98ae870a"
  },
  entries: %{
    "alpha_resize" => %{
      authored_sha256: "c96b21e6ce5753b5a33105abf5f1dd477fdea3fb08629f136e5418c0a40f6af6",
      fixture_filename: "alpha_resize.png",
      fixture_sha256: "4423b7a96fff78ba10be919543ea7d515067da45c83fdaa7c59add65b47357f6",
      kind: :transform
    },
    "background_alpha" => %{
      authored_sha256: "c8f9f7436ee1b9dbc6a7b8743527827d0a2031008b0261eb21be440ec1636ec1",
      fixture_filename: "background_alpha.png",
      fixture_sha256: "cdcaf41f0c8f64c3f76aa258be5789dea1cd6f7843e95230e10fd7099ce29713",
      kind: :transform
    },
    "blur_zone" => %{
      authored_sha256: "f74b9ff49a4d8a450b85cbb88d267a3fbf7a8ad6e3f775ecccdbbf9e56a1df85",
      fixture_filename: "blur_zone.png",
      fixture_sha256: "02e9f874b5b4bf5cf007a844040bc7e3806abdd55216d67e024b737a71c8ecd3",
      kind: :transform
    },
    "cover_min_dims_marker" => %{
      authored_sha256: "6843b0b4e54a0a8895fe5cf6e357dda9e244edd3615249d972c9c1933b7d27c2",
      fixture_filename: "cover_min_dims_marker.png",
      fixture_sha256: "58eb1dd93b5541973c662cdbf3f7e3546ac7cc5fae0aa6f7f78116db1a643935",
      kind: :transform
    },
    "crop_gravity_marker" => %{
      authored_sha256: "365d131e39e4315c49699d27e1de8574c5505ee48a543be7d85074ca36da7160",
      fixture_filename: "crop_gravity_marker.png",
      fixture_sha256: "50a02be76fc5b4c3e91456af442ff5dca1e4dbbdd77fef385feb46e5801f0658",
      kind: :transform
    },
    "dpr_marker" => %{
      authored_sha256: "00cb87a055c6a296f88bfe865e9d0a5b4aec84d6574881a67a73c8c82d5e32b7",
      fixture_filename: "dpr_marker.png",
      fixture_sha256: "e5fb54254c615ec898969e041fcb1e9e53fa3961045bd28ce846d899a520c0e1",
      kind: :transform
    },
    "enlarge_small" => %{
      authored_sha256: "0d9961c83de9d80484bc44550ec74ae802741ad0d8034bbf63829eba31df9322",
      fixture_filename: "enlarge_small.png",
      fixture_sha256: "566e927840c7a479afe63b1042d32bdd2df82edce0230e3a3c573a42e00c65ce",
      kind: :transform
    },
    "extend_ar_dpr_marker" => %{
      authored_sha256: "9b2cc1456b402da222a8af310ff7417b7539c068050236bdfdaae7dae043d17b",
      fixture_filename: "extend_ar_dpr_marker.png",
      fixture_sha256: "aa11c87e7f0ab3640e99e33fa8723fc0373a52dfb4fce1786e70ea5c1269db06",
      kind: :transform
    },
    "extend_ar_small" => %{
      authored_sha256: "4b7510901d7ee641c3a79fabd0b0b42e8e3f9af04ff473700f2f7922a660ebb7",
      fixture_filename: "extend_ar_small.png",
      fixture_sha256: "b228e4eb6c51b2ee76f132330567c629859803875ec544311bd070ae7bdb4b1d",
      kind: :transform
    },
    "extend_gravity_small" => %{
      authored_sha256: "06828b4d0e9cb54648035ccfe6f2c6f017caa4ea6227da5a36d5bafd5cee2f22",
      fixture_filename: "extend_gravity_small.png",
      fixture_sha256: "6f88a30a85bafce0da26d6f78481e833d2f3fab467ca69029b3b7dd84cd424e9",
      kind: :transform
    },
    "extend_offset_dpr_marker" => %{
      authored_sha256: "15f91d1d8a10b39d94a9cd4d5dc95e018036fefe4d4173294041fdf91ded0eb9",
      fixture_filename: "extend_offset_dpr_marker.png",
      fixture_sha256: "68adbb1be71963d2036f2e0535843bd9a0bd8fa3721ee4744ed627266a8b6f91",
      kind: :transform
    },
    "extend_offset_east_marker" => %{
      authored_sha256: "82fdd020f0a4ef3004e81b038a6e9e6043c9a660889b718ea9d3bceddd25556e",
      fixture_filename: "extend_offset_east_marker.png",
      fixture_sha256: "99327146b129ba5b4bd2c80f1f5964d68e607ac87990b5f2cc5304ed4b6ee2b8",
      kind: :transform
    },
    "extend_small" => %{
      authored_sha256: "3676ecd409c4d3169f20404c59606e4b6d587f658067f9a56b4505c5c39e98f2",
      fixture_filename: "extend_small.png",
      fixture_sha256: "c17cded72bf2ad1924f0646d3b6225e95a724c825cc43225b39ec01151002a18",
      kind: :transform
    },
    "fill_down_marker" => %{
      authored_sha256: "dcd9a5e67896f02c71add1b324ae0f113c0a111f793e2470583108198a1a93cc",
      fixture_filename: "fill_down_marker.png",
      fixture_sha256: "2939a6d8a0de7382492f0f268b896e4663e75b63d5be6846b86248e9f8d6c8da",
      kind: :transform
    },
    "fit_min_dims_gravity_marker" => %{
      authored_sha256: "047b59e479e2208accc8d6b51591bb0dea7c10e1acd14f56c083a4e9c89e52ca",
      fixture_filename: "fit_min_dims_gravity_marker.png",
      fixture_sha256: "c4350027d975c5328abfbd1316102fadc421966c8404bd02b34d0844a4e6bb93",
      kind: :transform
    },
    "gravity_offset_marker" => %{
      authored_sha256: "5684f94dd0f675d3b5cfcfdd502d069acdf3e06aaaf104df00de2bffc2f11053",
      fixture_filename: "gravity_offset_marker.png",
      fixture_sha256: "a6cb42f915db8661374325d8e85931017c9d881ba5617331ec7737108a13e44c",
      kind: :transform
    },
    "lossy_avif" => %{
      authored_sha256: "6161305ffaf46ef136566f6b276d87c393d8c9c3241e9137d4c2b203406e3ba4",
      content_type: "image/avif",
      height: 180,
      kind: :lossy,
      width: 240
    },
    "lossy_jpeg_q40" => %{
      authored_sha256: "53dafce1081ccf14ee6b831ea65162a84c23b002acbffda767c3e931707b1290",
      content_type: "image/jpeg",
      height: 180,
      kind: :lossy,
      width: 240
    },
    "lossy_webp" => %{
      authored_sha256: "d53a83b4a75a719eb8d1b28afea1435b3c7d1a8aba1973cdb8bfa7955bb6290a",
      content_type: "image/webp",
      height: 180,
      kind: :lossy,
      width: 240
    },
    "min_dims_clamp" => %{
      authored_sha256: "2dda437232a5dadc724b5b91b46c8e09be945210aa9f028823223157e7c98d67",
      fixture_filename: "min_dims_clamp.png",
      fixture_sha256: "19a131c89a0ba5daba808655526498764cbea3c018673d8e6002e3ee1a408f2f",
      kind: :transform
    },
    "min_dims_dpr_marker" => %{
      authored_sha256: "ea817e0877989758723b4e90bd942c1153e53b38751e898b01a06b97ed031467",
      fixture_filename: "min_dims_dpr_marker.png",
      fixture_sha256: "7221abf6b9829f098ce93de522b7697f8b7c798c04d8dabf4f37393c1d556690",
      kind: :transform
    },
    "padding_border" => %{
      authored_sha256: "4ee6d82c01bd04819cdcff3bc829ebeed27161d0cc2fb4629b0975ead3d1b507",
      fixture_filename: "padding_border.png",
      fixture_sha256: "1af6ead813738e1c08a94d74bb5901bbe999da983a6e9b3a7f84d082ac1ddf31",
      kind: :transform
    },
    "padding_dpr_border" => %{
      authored_sha256: "d5b7f5cb45fa28d7707f418705c24481fc357ca313e29329d8867c7a6376e048",
      fixture_filename: "padding_dpr_border.png",
      fixture_sha256: "423ee3f25796212d24fab9eef6ad27de8f67fb62d69eeae973b2f893b37c2b15",
      kind: :transform
    },
    "rotate_exif" => %{
      authored_sha256: "4920468ba4d56a795323a77b533a0945f66f4620d82fcd84d86d5c3cd508326e",
      fixture_filename: "rotate_exif.png",
      fixture_sha256: "79d98874795f31d33cb9c4739f7eb69f1b83c2e3b1096858f9ca126232db9322",
      kind: :transform
    },
    "rs_fill_webp_residual" => %{
      authored_sha256: "f630ad8191a7c6c6f0d98b33379e5bfefedb7b1dd2c2b912369b5f47ef225b6b",
      fixture_filename: "rs_fill_webp_residual.png",
      fixture_sha256: "9a384d245050b259bcd38efdf8c480caaf570bdc112149c5cd4917b432916332",
      kind: :transform
    },
    "rs_fill_zone" => %{
      authored_sha256: "0343d86c9ee79c809aa23f8b7f22bff6fa2f6faacaa669deceac1165e15a5a80",
      fixture_filename: "rs_fill_zone.png",
      fixture_sha256: "49067e71914e1ceb56b144d8eefe5c54c1caa2de724c1d1117d518715569c1e5",
      kind: :transform
    },
    "rs_fill_zone_q4" => %{
      authored_sha256: "7d87eef5a8dc26f5df3f41610a94f7453048c58e3d1e45eafebde9af0c534e35",
      fixture_filename: "rs_fill_zone_q4.png",
      fixture_sha256: "ce37e1de5360ca35ac1407269a014e695a2ab484c0f55987839c18cd28659f0c",
      kind: :transform
    },
    "rs_fit_zone" => %{
      authored_sha256: "1396b7373640f536ecdf24157c6eae5904e0a17a6f6a7d95a0a8959e7cfce558",
      fixture_filename: "rs_fit_zone.png",
      fixture_sha256: "eb4dfa2bee8f658209f2786c5d3a4518f84173209b55864568f233fd09c4be31",
      kind: :transform
    },
    "scp0_colorspace_124" => %{
      authored_sha256: "6056f7753e03c7c91c82dab5945b663b25d6a18900d96d3d5629597ba1f6fb9a",
      fixture_filename: "scp0_colorspace_124.png",
      fixture_sha256: "c636d669a31d09095e539ee312bd89744b4d6f88064dba9580fe559fb0e8cb4d",
      kind: :transform
    },
    "sharpen_zone" => %{
      authored_sha256: "8326df8eb2ec5e41effc22dad4992a6449d38256827d94a23f228f2a2649fc90",
      fixture_filename: "sharpen_zone.png",
      fixture_sha256: "ad6fb7b30b6afe83d7bd7c808d010cdd5f06feef5088b54a8ea6b6c8adaae7ee",
      kind: :transform
    },
    "strip_exif" => %{
      authored_sha256: "200b4edbbb3a02346765812304a4cda3b6ebdd346bd37b906a9d9caa946168c6",
      fixture_filename: "strip_exif.png",
      fixture_sha256: "79d98874795f31d33cb9c4739f7eb69f1b83c2e3b1096858f9ca126232db9322",
      kind: :transform
    },
    "trim_border_equal" => %{
      authored_sha256: "f5f5861b668af243635c745d337f978a1c9adc08bf10e6b54f648edc77b22f38",
      fixture_filename: "trim_border_equal.png",
      fixture_sha256: "f25e7af1bf08e3df79b6ace82515d7276dc92575f96006f24d37b3b72bf48336",
      kind: :transform
    },
    "trim_icc_p3" => %{
      authored_sha256: "089cddc807e4ae8931d39dc3ec914b408d959ebccd131df555c76b556af71b64",
      fixture_filename: "trim_icc_p3.png",
      fixture_sha256: "4af9c52b2a01bae8cc0ca491a68f1f8072f3a6c31ace8e7e5c30adfd02aa9a74",
      kind: :transform
    },
    "zoom_marker" => %{
      authored_sha256: "3a33335df8e72cbf2c6db4143d2e4ac8ec22f334aab7fd1885e73fa9244c6ea5",
      fixture_filename: "zoom_marker.png",
      fixture_sha256: "95170ad3b1694484cb35070a6dcbb15a7d32dd23bda9bb14e87b4a6d444c6a23",
      kind: :transform
    }
  }
}
