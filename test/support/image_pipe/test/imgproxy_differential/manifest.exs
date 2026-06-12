%{
  imgproxy_digest: "sha256:9ed8f87b34d55c7844951ff65bcf6605de54ba6670f64951c7215f9b125a482e",
  imgproxy_libvips: "42.20.2",
  pipe_libvips_at_gen: "8.18.2",
  sources: %{
    "alpha.png" => "7ef18f9ce1e08b6752fa8e55caf0819882d3779b997b65ec7a6c0c45e3a75fee",
    "border.png" => "350a6d992b4204dc619ccc492475ced70509b9f350fb7aed6f6156cb5efe1952",
    "cmyk.jpg" => "9888782df8ccd2e3654b430d6d9feb16985c381859688b22a54dc956772aad0c",
    "exif_2.jpg" => "8756ad8af4a475b0f3a3a6899d9f4e4133fb6ba9db48de3de0351c0a89c41a47",
    "exif_3.jpg" => "1d1f1f82266ae21079b7da91a715f540e260f38a4aca56e99b6c2d40b1367ea4",
    "exif_4.jpg" => "b56080f10510693331c1cfb35028b401c7d8958505710ec3bdc098c2e4df7042",
    "exif_5.jpg" => "627dfc2290f56b47acffe53f25dcc6cedda9e51a28ae7ac815aba098d7add7f7",
    "exif_6.jpg" => "ffc9f345632012165b7c80950b5d97999c370cc8f434995e52f58099fc675905",
    "exif_7.jpg" => "e3e222be9871ff6064dd88d2fd0e6281f39b04183bf6960a8dc22dde82b4f976",
    "exif_8.jpg" => "51d5a8f471da85a76b6327bcc08afe22f55994001003d252f0c98e6540ffd023",
    "exif_placement_2.jpg" => "b4c47754f040d0fb6cd23d76576430dbabe760c7c2f698c9da30003f2708a9db",
    "exif_placement_3.jpg" => "7c7d36bec89cac720e78660b0ba4153f678a8d5ab0e254421c9c27626b98ae99",
    "exif_placement_4.jpg" => "6416279f4061f5d7e8a532abde187611724ecc98cb27ed17931fda37d597a40f",
    "exif_placement_5.jpg" => "dc1a15da0a2fa424750012054e8dd77e8513da21341172b6b63e1fdb07ed8c2e",
    "exif_placement_6.jpg" => "647850a6d806cc8141574273bf8b4cf7cc76548331af2f00777b838dcdbb9d9f",
    "exif_placement_7.jpg" => "cd865146d6bcced1ee11cef5807ccb95dfe5051cf2df14ce39a724438899c11e",
    "exif_placement_8.jpg" => "c2705d93f917dc4c51b40ee8a01ca05b27ab7806d3a46636c26eedee8e1ae082",
    "high_freq.jpg" => "54ded6c57ec02c685e275276b54947f8c9345015342fc8a2acc9d8e54e4a7d43",
    "high_freq.webp" => "32d8e080d7e440b6329a441d2913222906d320bdeb060e956eb68a297c51df18",
    "icc_p3.png" => "80ce9bc055c01a12a9d8bf3db1693a1b46995f66bfdb796503636122de264869",
    "marker.png" => "cbb47b49a36fc7a8b37233c862e1d4b88174ec6bf81876223779b4ce3c52120d",
    "placement.png" => "eb3de4dce6337ed2bd531b35187bcda3265542dc5b661152631839616eca7d09",
    "rgb16.png" => "e0601a09f13020b00dd88e45794dd7fd59368239607c482609f027ee423d8119",
    "rgba16.png" => "0864f435451fd70d22779252fd5e6e5c4b69d0dd589133c069c3a18dad0ff45e",
    "small.png" => "517719b9e7ad77f867266b8c4e135d383cdc94c3bf14f7bc26c2060a98ae870a"
  },
  entries: %{
    "alpha_extend_bg" => %{
      authored_sha256: "bb2345c840edb18a92e9668f24db92256556b759566ae4d41d8f4787b2e9d6ea",
      fixture_filename: "alpha_extend_bg.png",
      fixture_sha256: "cdcaf41f0c8f64c3f76aa258be5789dea1cd6f7843e95230e10fd7099ce29713",
      kind: :transform
    },
    "alpha_resize" => %{
      authored_sha256: "c96b21e6ce5753b5a33105abf5f1dd477fdea3fb08629f136e5418c0a40f6af6",
      fixture_filename: "alpha_resize.png",
      fixture_sha256: "4423b7a96fff78ba10be919543ea7d515067da45c83fdaa7c59add65b47357f6",
      kind: :transform
    },
    "auto_resize_marker" => %{
      authored_sha256: "67bab8434519003df4a368ab2010eb3637db0aa16bffb0e40a8091fadba24c48",
      fixture_filename: "auto_resize_marker.png",
      fixture_sha256: "c55cd6309fa68b2e9244f3dbd9e0c18d62ef82f8392b42a968acdf3d0ff18b61",
      kind: :transform
    },
    "auto_resize_square_source_icc" => %{
      authored_sha256: "12373137d33a6c068bf52bfee59daddcc25cf9c5d6a02c8366198e13acc37219",
      fixture_filename: "auto_resize_square_source_icc.png",
      fixture_sha256: "de43f58c1197c1a2a56208766929c0f78ef51ef5c0add07f3e61ab97756fc6fb",
      kind: :transform
    },
    "auto_resize_square_target_marker" => %{
      authored_sha256: "d3994d8fd6926d447f5883f6a8df43345e71fdfa75e8f2bd5b2d9cd927ab49a6",
      fixture_filename: "auto_resize_square_target_marker.png",
      fixture_sha256: "bd1ebd7079f7d41f861fa3249b43d1b290e30f913f14744d6b8c897d00b0c103",
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
    "cmyk_import" => %{
      authored_sha256: "d176f8ab6e8197ebba123ac6f171b5aa8b4db67e7175a5e30c40b2926459f198",
      fixture_filename: "cmyk_import.png",
      fixture_sha256: "3edbf150cac23cb36ddcc60e59b6bc2f8657abed560cbebd3c76dec8d0138799",
      kind: :transform
    },
    "cover_corner_gravity_marker" => %{
      authored_sha256: "fc1d9286041c294f36a5f99c4ab15122d510dbb6c22517317563ee542a33ee5e",
      fixture_filename: "cover_corner_gravity_marker.png",
      fixture_sha256: "fe01761f16eea85fdcebe34db835579bad6c1adc428914e1d2c5190c7df48d54",
      kind: :transform
    },
    "cover_corner_offset_marker" => %{
      authored_sha256: "17d278c3db76a1985309f9944ca27bfab15f04909f2f0b5a77e8b74e07e2d6f2",
      fixture_filename: "cover_corner_offset_marker.png",
      fixture_sha256: "ccf45e04748c551df84836fca2712b604275bbd5c50fda3d76848d18d31aa1d4",
      kind: :transform
    },
    "cover_focal_marker" => %{
      authored_sha256: "c94cf6b12c4abc0098b5b072ce3d7c04d1a8c9917eba93fec9a8cbc18e0c12e9",
      fixture_filename: "cover_focal_marker.png",
      fixture_sha256: "3571ad4e89b9d6ad964d5dffd1fe6e4c763a50d7b7a2cb286c73b6d44d49dea3",
      kind: :transform
    },
    "cover_gravity_south_offset_marker" => %{
      authored_sha256: "cada26d1bc72ba2f9ab72977c45c77a17892c72a2874d96eeef03016fc0e7f5c",
      fixture_filename: "cover_gravity_south_offset_marker.png",
      fixture_sha256: "892457cfed820ba8fc335c32155c450230fa641860f6b94e57075532be6697f1",
      kind: :transform
    },
    "cover_min_dims_marker" => %{
      authored_sha256: "6843b0b4e54a0a8895fe5cf6e357dda9e244edd3615249d972c9c1933b7d27c2",
      fixture_filename: "cover_min_dims_marker.png",
      fixture_sha256: "58eb1dd93b5541973c662cdbf3f7e3546ac7cc5fae0aa6f7f78116db1a643935",
      kind: :transform
    },
    "cover_odd_gap_center_marker" => %{
      authored_sha256: "6dfbb76ed0bdf41e8dc257883925c91e725bf57887b3a0c7818906edfcdd1af0",
      fixture_filename: "cover_odd_gap_center_marker.png",
      fixture_sha256: "58eb1dd93b5541973c662cdbf3f7e3546ac7cc5fae0aa6f7f78116db1a643935",
      kind: :transform
    },
    "cover_odd_gap_corner_dpr_marker" => %{
      authored_sha256: "65bc368dbf3df112d197740964afdf3d94ba9bbe7aaa76d185e19ce116ac4e74",
      fixture_filename: "cover_odd_gap_corner_dpr_marker.png",
      fixture_sha256: "1a36b442593a4c27919fe48d5192a60a26a2a9f08e5cf40f9cabd7d8039230ba",
      kind: :transform
    },
    "cover_odd_gap_corner_marker" => %{
      authored_sha256: "b5f74b456c3b40d231e174026be45fc682a1ca512d379f6cb2302b6866b95911",
      fixture_filename: "cover_odd_gap_corner_marker.png",
      fixture_sha256: "6ed5eef448f92392f943ee65bcae8f428828a7b4eaaa532fc0ae9d1ce2415f4a",
      kind: :transform
    },
    "cover_offset_dpr_marker" => %{
      authored_sha256: "585b6401022a4a80bc4a4912fc2bc0f69b1716c190e0d59e5200a60a821d90ac",
      fixture_filename: "cover_offset_dpr_marker.png",
      fixture_sha256: "5eacf1059134d3a40971cee9b56b2af7e7d4635b646ecebe98e58feec9027293",
      kind: :transform
    },
    "cover_west_gravity_marker" => %{
      authored_sha256: "54e3be50efd25b894d04cdb91d4d4a16213d4335f673dc54b45f65ea6538de27",
      fixture_filename: "cover_west_gravity_marker.png",
      fixture_sha256: "cc951096a398c2ae0347478e4604d8d63e0b2b707c42880be21800597bf36dd5",
      kind: :transform
    },
    "crop_corner_placement" => %{
      authored_sha256: "3132e70aa7b8cf3deadc8055c231f06950163bf29434ee9727b30a645fd4849b",
      fixture_filename: "crop_corner_placement.png",
      fixture_sha256: "780022203c06f158eb8545bd9690b121150b1dbb25519480b56f4f0b39fa40de",
      kind: :transform
    },
    "crop_east_offset_placement" => %{
      authored_sha256: "5330718ecb04ed88714d90f0f4a98db92b13f9076a42f1b3d0869e0bfa66ea3a",
      fixture_filename: "crop_east_offset_placement.png",
      fixture_sha256: "cdc7023e6f2d4cc112de67cfeebf47b23d2914e96ca99cc6f1f8c4390d15a8e1",
      kind: :transform
    },
    "crop_focal_edge_placement" => %{
      authored_sha256: "8cd4f93d4975bdf1c0f0d3e77e8cefb2457c4132964a849182ef1b0a9d193915",
      fixture_filename: "crop_focal_edge_placement.png",
      fixture_sha256: "df84ba1da81c487987375ed885001ffc724a314e887071bef3ba2ff016bb588b",
      kind: :transform
    },
    "crop_focal_placement" => %{
      authored_sha256: "e1b6bdd69c6a8b4ca90dd29dec4c37a3575c862b39389e7eac3c407d89ad9428",
      fixture_filename: "crop_focal_placement.png",
      fixture_sha256: "e94d29d26fea3e9828f883d73b3a04b1cf311a831dcb89b108c2ff738c954628",
      kind: :transform
    },
    "crop_gravity_placement" => %{
      authored_sha256: "09b7e24186bed6f0a06848365bf1fff59d15f73bbabd98274dfcca547b401e3c",
      fixture_filename: "crop_gravity_placement.png",
      fixture_sha256: "65c19f17fcf0110fa45ef5e46a77e3ca9d90f1f4f017f229019d3b16aa089ff3",
      kind: :transform
    },
    "crop_offset_dpr_placement" => %{
      authored_sha256: "365c53ef270d5edec06b89b54b0cbbbf71865514b60bc07a7825cc0ac0656f0b",
      fixture_filename: "crop_offset_dpr_placement.png",
      fixture_sha256: "cdc7023e6f2d4cc112de67cfeebf47b23d2914e96ca99cc6f1f8c4390d15a8e1",
      kind: :transform
    },
    "crop_resize_two_gravities_marker" => %{
      authored_sha256: "2692a4606d5d061371cfd7dc968f3f8e4d8efe1435871915876ac27c8c8bc674",
      fixture_filename: "crop_resize_two_gravities_marker.png",
      fixture_sha256: "03afc585b5e5abf85d5367a0c9a6ac907aa35b3adba4ee8f8417ceca7b566243",
      kind: :transform
    },
    "crop_smart_marker" => %{
      authored_sha256: "80b4561916217d3885f004b360b8190795dd9ddc7e63ca550ee9f928658f6d6a",
      fixture_filename: "crop_smart_marker.png",
      fixture_sha256: "89c3c63fc4b6c8580ec5e62a72a27fec124fa0b9cad63a7a794a6cf44638bf25",
      kind: :transform
    },
    "crop_west_placement" => %{
      authored_sha256: "0f821fd57da0e797579e1924690bd9191e6787c30dcf37a2a6c5229934263630",
      fixture_filename: "crop_west_placement.png",
      fixture_sha256: "bdd71a80029e55b46cd367f719b958cb9d9eb8867745641f12e2b7f4335d55d3",
      kind: :transform
    },
    "dpr_marker" => %{
      authored_sha256: "00cb87a055c6a296f88bfe865e9d0a5b4aec84d6574881a67a73c8c82d5e32b7",
      fixture_filename: "dpr_marker.png",
      fixture_sha256: "e5fb54254c615ec898969e041fcb1e9e53fa3961045bd28ce846d899a520c0e1",
      kind: :transform
    },
    "effects_chain_order_high_freq" => %{
      authored_sha256: "4a3e0e8a52ae033d473b4b2b2569b6d8423adfb99aab344708d1159671d2e0cc",
      fixture_filename: "effects_chain_order_high_freq.png",
      fixture_sha256: "6dabd60fea767033d02075a8815bdabf88f716dbbe1cb3630a108c654e14a203",
      kind: :transform
    },
    "enlarge_off_dpr_comp_small" => %{
      authored_sha256: "89e38684090a825c470ab16704c1ec61771eeb163753a5f1eae9068c413a3ce7",
      fixture_filename: "enlarge_off_dpr_comp_small.png",
      fixture_sha256: "dd59be38f7dbc89f7cbb930d2b6f738ee418acea6469adb72943d72aabe1634e",
      kind: :transform
    },
    "enlarge_off_dpr_extend_small" => %{
      authored_sha256: "4249406b5a38a34cbad1718792dd61c473a4d527e9ee2a8698d37d3bf06de68e",
      fixture_filename: "enlarge_off_dpr_extend_small.png",
      fixture_sha256: "910aa810c9314da456f1a9f13506e2b49561180cf859741333011706d9726a2e",
      kind: :transform
    },
    "enlarge_small" => %{
      authored_sha256: "0d9961c83de9d80484bc44550ec74ae802741ad0d8034bbf63829eba31df9322",
      fixture_filename: "enlarge_small.png",
      fixture_sha256: "566e927840c7a479afe63b1042d32bdd2df82edce0230e3a3c573a42e00c65ce",
      kind: :transform
    },
    "exif_182_auto_branch" => %{
      authored_sha256: "77dbb16e918cb533dba40b7dae56401197e565fb011ef65f05fe2f6a2e3e3c18",
      fixture_filename: "exif_182_auto_branch.png",
      fixture_sha256: "20ad2e78dec48eda5c7b9e18e9154c6350891841c122b376c7dce2f593cb7c4e",
      kind: :transform
    },
    "exif_182_auto_pad_dpr_cap" => %{
      authored_sha256: "cae34179fbb0071493de74d0ae03a25da0ff0d84856c354239a9bf1af740d08c",
      fixture_filename: "exif_182_auto_pad_dpr_cap.png",
      fixture_sha256: "e713fdd73df5a83658c5d8a48217558753f647236f30d9a48828a3f5fd7bc48b",
      kind: :transform
    },
    "exif_182_padding_no_resize" => %{
      authored_sha256: "f789647ee642db1325020a7ce919b58392a3703824fff222fda8d9b0f13467b0",
      fixture_filename: "exif_182_padding_no_resize.png",
      fixture_sha256: "7671a296cc624b566b3526fa041ecb9bbf63d32c4a8917487b687d7aec732623",
      kind: :transform
    },
    "exif_182_pixelate" => %{
      authored_sha256: "b543f3385a326faab416c44f9dee252c338498d9fad00812afff2a33ae323aee",
      fixture_filename: "exif_182_pixelate.png",
      fixture_sha256: "7577068b53ddba0d274e4ee20a22092dcf39e2e233edd781de3945f789ec0102",
      kind: :transform
    },
    "exif_182_trim_smart" => %{
      authored_sha256: "e130a98cf74cf1cc3692b01cacaed7101bc6a21d0d74d4d1b81f23df2f2a0cb0",
      fixture_filename: "exif_182_trim_smart.png",
      fixture_sha256: "eabc3af213057f52ce256973ae627d939848ad04602cab97e75c782dabffa290",
      kind: :transform
    },
    "exif_2_cover" => %{
      authored_sha256: "b5dff066efece2d187f390a877595b2d84d22a883c78ae5f851e5eea37c0be95",
      fixture_filename: "exif_2_cover.png",
      fixture_sha256: "255202508ca2403b8307a2928b51178ced4c38a13745135760f75ac791005e50",
      kind: :transform
    },
    "exif_2_crop_no" => %{
      authored_sha256: "3ce288626249c0a86f6431ad66838c903e39b46c8fc1e667b821be267296d7d9",
      fixture_filename: "exif_2_crop_no.png",
      fixture_sha256: "d3e9c6ddfe1c8546db919983898f9a1cce89cd5cfe8d74831142621482bf36dc",
      kind: :transform
    },
    "exif_2_extend_so" => %{
      authored_sha256: "965745f07b4616ba65b70c6c273dd2660304b190631646ebee1233cc5fe39802",
      fixture_filename: "exif_2_extend_so.png",
      fixture_sha256: "ef29ecd2a6a9aca14bd72650ede278c87f530c6b97cdef6b6935ab52f5d70369",
      kind: :transform
    },
    "exif_3_cover" => %{
      authored_sha256: "475832ca4af43fc00f5149a86865a8fb4f06a2ab8578164f1a34d59b66109518",
      fixture_filename: "exif_3_cover.png",
      fixture_sha256: "bbe4adabd8293b548fa7933f110f6d65299af7b84d6ef21a5029b1e82d9ff8bd",
      kind: :transform
    },
    "exif_3_crop_no" => %{
      authored_sha256: "21ba98c9e0749f276e91f38deb263b9be889810a608dac615a0f761e76acfce2",
      fixture_filename: "exif_3_crop_no.png",
      fixture_sha256: "72c0684d1cd41a0069acac6f408ec1a87fe6a1041ef7c2dac33c36776d439f0b",
      kind: :transform
    },
    "exif_3_extend_so" => %{
      authored_sha256: "e598e5cd2bcaa9e925ecc304f89d41dedfa03d4df7f0fb3a5671d2dc71a93a51",
      fixture_filename: "exif_3_extend_so.png",
      fixture_sha256: "2f0389acb56d7c26683ddd6e00f0a240a45d97a2adb465d6773e927d123b0ed8",
      kind: :transform
    },
    "exif_4_cover" => %{
      authored_sha256: "c6e75456a056bd08eefaa9fd1f2703f1a0141990fed554d3bcf0b72fde94d5f9",
      fixture_filename: "exif_4_cover.png",
      fixture_sha256: "f6ced049d65c6f9b957fd0d739135d7deda98def7e6f928d9d5e585ed560486f",
      kind: :transform
    },
    "exif_4_crop_no" => %{
      authored_sha256: "560cb0f328f1c793e3f07b72a9d8f714fb22241a908715959208d0cec078bfea",
      fixture_filename: "exif_4_crop_no.png",
      fixture_sha256: "6d320fe78bd2cd98e8de1dea37bfa0c947a11fa5a25b0e72b8008acd49c51303",
      kind: :transform
    },
    "exif_4_extend_so" => %{
      authored_sha256: "9dc2e89e5ff41418e74738917f5fff28b0bb2be877c05b1d57cca1e34c6a940e",
      fixture_filename: "exif_4_extend_so.png",
      fixture_sha256: "f0faef7ede4bbe5e4f7593bf8127b2cc336a4df88752c4f50efc77826dfccf19",
      kind: :transform
    },
    "exif_5_cover" => %{
      authored_sha256: "73b7b23e6299461428479a539b96d10e0e2143d54bca81ad48a4466196a15942",
      fixture_filename: "exif_5_cover.png",
      fixture_sha256: "2c5fdb339ee14be1fcc30d098ca80dca9e30cf09f48b68a33c11ce4d3ad2271b",
      kind: :transform
    },
    "exif_5_cover_fl" => %{
      authored_sha256: "2266e74fe340f8837cb2140132e5d986de238d351a081ce74344b765aee99d1d",
      fixture_filename: "exif_5_cover_fl.png",
      fixture_sha256: "7b7c895adfc90b4546f5dd82aeb22ab7b8a0eda59efa4c61718a58e9aaff0126",
      kind: :transform
    },
    "exif_5_cover_rot90" => %{
      authored_sha256: "8bb5427efd530920c4327d8889e8d867ea20846b7a233a5763688a1078454a9d",
      fixture_filename: "exif_5_cover_rot90.png",
      fixture_sha256: "255202508ca2403b8307a2928b51178ced4c38a13745135760f75ac791005e50",
      kind: :transform
    },
    "exif_5_crop_no" => %{
      authored_sha256: "a2114b8cf723da0836898768b7f451aa6de83b915fcb367195062aeadf6ed650",
      fixture_filename: "exif_5_crop_no.png",
      fixture_sha256: "cb0ef932743dc2d6abe9688447ae8f2c795fae50225ff2a81779c0ccf52ab690",
      kind: :transform
    },
    "exif_5_extend_so" => %{
      authored_sha256: "4a0be7c49af32f415888b2b3a99f2497bb40f97a80b2308ac02c3f2a01d2366c",
      fixture_filename: "exif_5_extend_so.png",
      fixture_sha256: "231caaba0f232ddb90d32a7c21b8378da1ca1e445737a3fec8777a46991ae945",
      kind: :transform
    },
    "exif_7_cover" => %{
      authored_sha256: "81a6b3c7eaec836fc5fa03349ee034f8a1147fcf95917dab1fb40cfd831d4fc7",
      fixture_filename: "exif_7_cover.png",
      fixture_sha256: "122320325795a93e90121504d8115ce5d10c5cb838ad823278c78733316714db",
      kind: :transform
    },
    "exif_7_cover_fl" => %{
      authored_sha256: "c81f38186c960f55c5ffba4f1fb697ffbf35c040541f3a86b5e75b09c97cd10c",
      fixture_filename: "exif_7_cover_fl.png",
      fixture_sha256: "2b1b736ed8a03f337ee9405951199fa5e011402e40cd9c48e712b80cc25c69ab",
      kind: :transform
    },
    "exif_7_cover_rot90" => %{
      authored_sha256: "2e1432bfa6d54ebb66db4fffda0836864e1fc6d0f0049dd0354cea7bc627ffc6",
      fixture_filename: "exif_7_cover_rot90.png",
      fixture_sha256: "f6ced049d65c6f9b957fd0d739135d7deda98def7e6f928d9d5e585ed560486f",
      kind: :transform
    },
    "exif_7_crop_no" => %{
      authored_sha256: "ec2a406e96675579a03ddd68b3eda768133cc0e5bc224bad093ecd6bbfb3a569",
      fixture_filename: "exif_7_crop_no.png",
      fixture_sha256: "e9a1433b8c78bb2d0d6a66b0ac927cadaa3628c568dbe9c76ea80ff119337a13",
      kind: :transform
    },
    "exif_7_extend_so" => %{
      authored_sha256: "0fad42d030b753ac03bfe5f8068704db4754e67f522c90620259a6f90a0654aa",
      fixture_filename: "exif_7_extend_so.png",
      fixture_sha256: "209d4e4ea4fc451007ed1a3888db0a83336ecef84326f474f266b434619821e3",
      kind: :transform
    },
    "exif_8_cover" => %{
      authored_sha256: "1ddb98683358bf52323624b24557a1f675f601eb75fbdfb3102524c62f6c059a",
      fixture_filename: "exif_8_cover.png",
      fixture_sha256: "2b1b736ed8a03f337ee9405951199fa5e011402e40cd9c48e712b80cc25c69ab",
      kind: :transform
    },
    "exif_8_crop_no" => %{
      authored_sha256: "61431db3fb481717cef2e353ad063809da98b8650b9b7058775caf1387276951",
      fixture_filename: "exif_8_crop_no.png",
      fixture_sha256: "99449d7cdf5c29395b041ad60fbcb92aa5eebe7deddd3f0bbf32da59fe2f324d",
      kind: :transform
    },
    "exif_8_extend_so" => %{
      authored_sha256: "da6209bc1024ff37c65feb756f3adca3f3dfca3c0ad581dc1970b8df045bd83b",
      fixture_filename: "exif_8_extend_so.png",
      fixture_sha256: "053a2a202bfa785721c8e9cd4fdb09b5a3d62934858c7d80fece6a94d9d82af5",
      kind: :transform
    },
    "exif_auto_square_marker" => %{
      authored_sha256: "c2046c007d970efbc31384d8b2c2d81d94175ae8cb82e507b8ee2ec9f9c6b506",
      fixture_filename: "exif_auto_square_marker.png",
      fixture_sha256: "a8b69e3cb2d73be56760aae2df633a33fb650f06a4f54fd7258a4363743872b9",
      kind: :transform
    },
    "exif_cover_asym" => %{
      authored_sha256: "2cd5e4002bb2727688ea4cedaac791ab77dd4a5566c994403b63c5d994dfd030",
      fixture_filename: "exif_cover_asym.png",
      fixture_sha256: "7b7c895adfc90b4546f5dd82aeb22ab7b8a0eda59efa4c61718a58e9aaff0126",
      kind: :transform
    },
    "exif_cover_focal_transpose" => %{
      authored_sha256: "92d88c404f8b381aa0d54a97226b3660dc67a98f6c409424f7ccd0e2582ab43c",
      fixture_filename: "exif_cover_focal_transpose.png",
      fixture_sha256: "fb59c994e0f6e4ee0e4fce41e3a7181c465b3a864a3999a2eb5bbb9a03c0a17f",
      kind: :transform
    },
    "exif_cover_focal_transverse" => %{
      authored_sha256: "6d140a8bc09c59ce02181873d1d554ae0e7115a0cfb38e52af23cbf61f981493",
      fixture_filename: "exif_cover_focal_transverse.png",
      fixture_sha256: "14480d7856041f30bbae467229b0cd97dad0df335155348beb15de0900592720",
      kind: :transform
    },
    "exif_crop_focal" => %{
      authored_sha256: "0b7574e2938b0963942e968f693d44a4eb94d83b0505b4e33751296e34b21c2f",
      fixture_filename: "exif_crop_focal.png",
      fixture_sha256: "6f7380739c9aa949e3102829cabe2ddaf9ca57ff6671abdcc83cbbd6ca43639d",
      kind: :transform
    },
    "exif_crop_north" => %{
      authored_sha256: "bb36fce2229e308e5e281ddc1b39cb3124d702fa76b61f51a51231a64ee85700",
      fixture_filename: "exif_crop_north.png",
      fixture_sha256: "1cfc70f3884009d60100aa6d83ae5cc5ddf101e03fb1b01964f59fa0a92a6080",
      kind: :transform
    },
    "exif_extend_south" => %{
      authored_sha256: "e262a0526a95a2a034706429679d1c0ced8facc9975163e96e95c70f6a7f46f2",
      fixture_filename: "exif_extend_south.png",
      fixture_sha256: "c69533dfb15e426ac760589bf0b6bbb8eab3e85d10e6d169e3ff12b927e1c3c9",
      kind: :transform
    },
    "exif_user_flip_h" => %{
      authored_sha256: "669a5f4a69d8da54f87b00834297b3df140a55dc55a0124488c463f9f553e8f5",
      fixture_filename: "exif_user_flip_h.png",
      fixture_sha256: "356a11d4845340173e3ec149c165e1cd276dc0047050d0c5970c4b2cb646a038",
      kind: :transform
    },
    "exif_user_rot90" => %{
      authored_sha256: "84d1ee1a4eaf0a1001e1da449038a8198b14066d06ece73a68ae901c1eca0d77",
      fixture_filename: "exif_user_rot90.png",
      fixture_sha256: "affcf95a6c6eea6fd2f79027f8490292617369a9cfa81b24d47286a0cafc86ef",
      kind: :transform
    },
    "extend_ar_dpr_marker" => %{
      authored_sha256: "ab2f24f77c971a86c30e9c987bcf6ac2f8843b60a57371c6c1b0806a2b8fd2a5",
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
    "extend_corner_offset_small" => %{
      authored_sha256: "3369f2041fcc3a54c70c15d6cf55a81cce46d5be093da6b66b7a8f73bd308463",
      fixture_filename: "extend_corner_offset_small.png",
      fixture_sha256: "d26cb97cf990f1a00ac95d0f40bf826f433cd7d344e5342a24b00ef77cdf601c",
      kind: :transform
    },
    "extend_dpr_fractional_marker" => %{
      authored_sha256: "f8b8a575e88565547d73ce2e46374ddf9a6b97487aefb2857fdd56f3ca6d9f9f",
      fixture_filename: "extend_dpr_fractional_marker.png",
      fixture_sha256: "aa11c87e7f0ab3640e99e33fa8723fc0373a52dfb4fce1786e70ea5c1269db06",
      kind: :transform
    },
    "extend_gravity_north_small" => %{
      authored_sha256: "fadf889b74f06d696b0f29cc3aae6aae4108d13f0b4f6d93ae183c1fa7238f70",
      fixture_filename: "extend_gravity_north_small.png",
      fixture_sha256: "cad8f380cd29378a0ff86ba270333033bc6cd4dbcdb3759ae88e2949b0c959f2",
      kind: :transform
    },
    "extend_gravity_small" => %{
      authored_sha256: "06828b4d0e9cb54648035ccfe6f2c6f017caa4ea6227da5a36d5bafd5cee2f22",
      fixture_filename: "extend_gravity_small.png",
      fixture_sha256: "6f88a30a85bafce0da26d6f78481e833d2f3fab467ca69029b3b7dd84cd424e9",
      kind: :transform
    },
    "extend_inert_marker" => %{
      authored_sha256: "26a4abb8b2992a757d8e8dee1d10bdfe05eba3ed3b7f217ad58058a7df1035a6",
      fixture_filename: "extend_inert_marker.png",
      fixture_sha256: "bba860e367017abb1dcfc0797f5f581329399223baf36bd5ddb2ac59e79a8558",
      kind: :transform
    },
    "extend_offset_clamp_dpr_small" => %{
      authored_sha256: "6aaa664354399f9e5791136ad94e93bb48366352c01ed807c2a6b9a4f68e791f",
      fixture_filename: "extend_offset_clamp_dpr_small.png",
      fixture_sha256: "563e2b027b051acda07cbfeca7577dfd3bda49ee6cea54a2cbe234b57ae75835",
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
    "extend_padding_stack_small" => %{
      authored_sha256: "63fc271613fdef578d11104e0fd6b28be8c4399166406cbfd095d5dc26c57b3d",
      fixture_filename: "extend_padding_stack_small.png",
      fixture_sha256: "d2802f1f15949d73b1ddf3b7ff0128def0382520875252af8b3e5955e78892a0",
      kind: :transform
    },
    "extend_small" => %{
      authored_sha256: "3676ecd409c4d3169f20404c59606e4b6d587f658067f9a56b4505c5c39e98f2",
      fixture_filename: "extend_small.png",
      fixture_sha256: "c17cded72bf2ad1924f0646d3b6225e95a724c825cc43225b39ec01151002a18",
      kind: :transform
    },
    "fill_down_corner_gravity_marker" => %{
      authored_sha256: "e64b87598bb1891106c138f9435dbe1ee91a731d41e7b5da76336021cd90c59c",
      fixture_filename: "fill_down_corner_gravity_marker.png",
      fixture_sha256: "81e505a01f3d56b81a62745684eb071abe8dac60c6ca7772e687fb0b983e75f6",
      kind: :transform
    },
    "fill_down_marker" => %{
      authored_sha256: "dcd9a5e67896f02c71add1b324ae0f113c0a111f793e2470583108198a1a93cc",
      fixture_filename: "fill_down_marker.png",
      fixture_sha256: "2939a6d8a0de7382492f0f268b896e4663e75b63d5be6846b86248e9f8d6c8da",
      kind: :transform
    },
    "fill_down_min_dims_marker" => %{
      authored_sha256: "7512193de895674e14d6895bf6beb669218e89ecdf065c953f5d8993934ed54d",
      fixture_filename: "fill_down_min_dims_marker.png",
      fixture_sha256: "fc26c82d52009da1733fc0e4a841566a7fafd47aaa773eb29158ab6c57e1e895",
      kind: :transform
    },
    "fill_mw_mh_above_target" => %{
      authored_sha256: "14a9731e37ccec428b2c00e34c99aaba2a797a5804c80f5273630b1ad31c23b7",
      fixture_filename: "fill_mw_mh_above_target.png",
      fixture_sha256: "fc26c82d52009da1733fc0e4a841566a7fafd47aaa773eb29158ab6c57e1e895",
      kind: :transform
    },
    "fit_min_dims_gravity_marker" => %{
      authored_sha256: "047b59e479e2208accc8d6b51591bb0dea7c10e1acd14f56c083a4e9c89e52ca",
      fixture_filename: "fit_min_dims_gravity_marker.png",
      fixture_sha256: "c4350027d975c5328abfbd1316102fadc421966c8404bd02b34d0844a4e6bb93",
      kind: :transform
    },
    "flip_h_marker" => %{
      authored_sha256: "6380f86f3e9a64a05f1ee858f54e273f8c609dfbfb77d3ab60775af694e50ed1",
      fixture_filename: "flip_h_marker.png",
      fixture_sha256: "97a92326a2223a93ba24e7bc7c793c000e848a50afaa1ece4c392c97d80c01f2",
      kind: :transform
    },
    "flip_v_marker" => %{
      authored_sha256: "323559e249dc05e0116cc585fa9afbe90b6f4254ece2f21ef9f39a71df17e756",
      fixture_filename: "flip_v_marker.png",
      fixture_sha256: "d42e4551a3be362316d26269b302766a75a3ccdc3870bd18fd202ede1d841fd9",
      kind: :transform
    },
    "force_resize_marker" => %{
      authored_sha256: "6b8e2914ff96ceff9d318e5b9bc324231347a852fdeb670caad0ff9fe7ef05ac",
      fixture_filename: "force_resize_marker.png",
      fixture_sha256: "b9a1442e44341fdc7023896be69f33159e0ed1c8b7e0e9647d4b27c9ef83cc02",
      kind: :transform
    },
    "fp_min_dims_dpr_marker" => %{
      authored_sha256: "e315d4ab65b3b0b400aa1eb003eaf9a4bc2c4a36f1227383743f609a515967e4",
      fixture_filename: "fp_min_dims_dpr_marker.png",
      fixture_sha256: "09a7917cd51390935f6dcba58d9d1b0603fcfbdfae3edb8219eeda50170aaf3f",
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
    "min_dims_dpr_enlarge_off_small" => %{
      authored_sha256: "29eda9d2bae3f78a41b82243f90d949db1f66c97c50987b275a690218178effe",
      fixture_filename: "min_dims_dpr_enlarge_off_small.png",
      fixture_sha256: "382e257c3b80c21ea3799b830299447cd8636ac7bce5621d7a2b321284583ab1",
      kind: :transform
    },
    "min_dims_dpr_marker" => %{
      authored_sha256: "ea817e0877989758723b4e90bd942c1153e53b38751e898b01a06b97ed031467",
      fixture_filename: "min_dims_dpr_marker.png",
      fixture_sha256: "7221abf6b9829f098ce93de522b7697f8b7c798c04d8dabf4f37393c1d556690",
      kind: :transform
    },
    "padding_asym_dpr_exif" => %{
      authored_sha256: "4e1d728e1c102b020405ea0dcbdabb3680d9667e16613b573c82407aba5e0252",
      fixture_filename: "padding_asym_dpr_exif.png",
      fixture_sha256: "7671a296cc624b566b3526fa041ecb9bbf63d32c4a8917487b687d7aec732623",
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
    "pixelate_marker" => %{
      authored_sha256: "fe696e069a5d3aabb3ba361c9ee56de7cec97d835733e2d3741b1784029e08ad",
      fixture_filename: "pixelate_marker.png",
      fixture_sha256: "522a35bf4f754db93a6d6816cf413c067a62cd11e2bee2fa4c0cb6c6de32f9e6",
      kind: :transform
    },
    "rgb16_preserve_hdr" => %{
      authored_sha256: "2bd5249388be6701a6a4f7a3b15715036e07a4c33714a883d438186026a1bce3",
      fixture_filename: "rgb16_preserve_hdr.png",
      fixture_sha256: "e21e3b68d09819003d2fa0cbe46e70c665fb53ba375cd4d21558eb11b1177110",
      kind: :transform
    },
    "rgb16_tonemap_8bit" => %{
      authored_sha256: "585f75e98edf9c7d60ec093d8254cb1649abef8ddc02085b0ac70510b8dc8c2b",
      fixture_filename: "rgb16_tonemap_8bit.png",
      fixture_sha256: "c3b5c879c371810800afff4f44880a8c6d29e6a5f0bf1296343d0ba22aa0196f",
      kind: :transform
    },
    "rgba16_preserve_hdr" => %{
      authored_sha256: "9d32615d0aa1fe406341cc06e536ea2feb2183b1b8f18b421d22599e80fa5ff2",
      fixture_filename: "rgba16_preserve_hdr.png",
      fixture_sha256: "2eed28ab08e3dfb2fd4441fbe6570fa2b5c0cf94a3611a5ad547add2c0c043ee",
      kind: :transform
    },
    "rgba16_tonemap_8bit" => %{
      authored_sha256: "85fa4d52f675528ed6ab6aa9e6779c75ee4e25ac49611458fdc63b7b4487e1b4",
      fixture_filename: "rgba16_tonemap_8bit.png",
      fixture_sha256: "2c508acf5cbe33eb4f2519cb72efbc4a04c5c6786f7c0e1791ede65a9bcc6b69",
      kind: :transform
    },
    "rot90_crop_north_placement" => %{
      authored_sha256: "6576bc02f5acdb648e105e7378618a34bf787998583b49ef4a614457489aed8f",
      fixture_filename: "rot90_crop_north_placement.png",
      fixture_sha256: "8519282908a0245b01a1bc576c2dd6aff3636fd72e5d168f216722d73b9a3f49",
      kind: :transform
    },
    "rot90_flip_h_marker" => %{
      authored_sha256: "663960b5efe0ff98ed3d11e4b323081374cddedaef67b61eb624f236f6ff1a31",
      fixture_filename: "rot90_flip_h_marker.png",
      fixture_sha256: "3602aa2bb77f1d211b4943e282539533bb9323e14ed91cfac98a88960d84221f",
      kind: :transform
    },
    "rotate_exif" => %{
      authored_sha256: "252877ba8585482a2b093e9c98880a686c0c93054ab6cd580dfc998be894790b",
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
    "scp0_blur_icc_p3" => %{
      authored_sha256: "af35c7415e6a30cc698e65d3d6a8ddafe866650af6e82717238ccfbe2122ee34",
      fixture_filename: "scp0_blur_icc_p3.png",
      fixture_sha256: "277e3cc0a0fc915323978f2bb6d3680bab76b8fcc9abab29cb0fb6092374f6c3",
      kind: :transform
    },
    "scp0_colorspace_124" => %{
      authored_sha256: "6ea97617c9f447d32a2496bae12dbd9a47a727e74f13fd2b06c583bc003f47a7",
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
      authored_sha256: "fd84a77b9cb362428575bae75b4cb195c29724e320e851c74a0a8a9c03ec3a4b",
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
    "trim_equal_h_exif5" => %{
      authored_sha256: "975bfff99da47fd986d27676554a0a0a2b487ae5f662f25d924c936f261f6a80",
      fixture_filename: "trim_equal_h_exif5.png",
      fixture_sha256: "356a11d4845340173e3ec149c165e1cd276dc0047050d0c5970c4b2cb646a038",
      kind: :transform
    },
    "trim_equal_hv_border" => %{
      authored_sha256: "e48730ba7e1a70f813acc95b7b143cc29b6dc07b5ba80af7ec76d6f9c0e17e6e",
      fixture_filename: "trim_equal_hv_border.png",
      fixture_sha256: "f25e7af1bf08e3df79b6ace82515d7276dc92575f96006f24d37b3b72bf48336",
      kind: :transform
    },
    "trim_exif_cover_crop" => %{
      authored_sha256: "6a445ae3b20b034a42aada598bcab2cee8b99a3c721ade1d081633b821cec480",
      fixture_filename: "trim_exif_cover_crop.png",
      fixture_sha256: "999a7afcfdf58f5dc19ac0b48cc2ab55d364790074b724456842d9bb67c4a74d",
      kind: :transform
    },
    "trim_icc_p3" => %{
      authored_sha256: "089cddc807e4ae8931d39dc3ec914b408d959ebccd131df555c76b556af71b64",
      fixture_filename: "trim_icc_p3.png",
      fixture_sha256: "4af9c52b2a01bae8cc0ca491a68f1f8072f3a6c31ace8e7e5c30adfd02aa9a74",
      kind: :transform
    },
    "trim_resize_high_freq" => %{
      authored_sha256: "106af208caf732aa9c34186853d211903203defd541984327f9f12f046e9f587",
      fixture_filename: "trim_resize_high_freq.png",
      fixture_sha256: "1470298dfbd3d677e9c6f4ad75f38445f48c5851f2e759dc3e63e1c257810d69",
      kind: :transform
    },
    "user_rot180_marker" => %{
      authored_sha256: "927682c44c9ea190212feec3950893f52589f79c776bfd1131890c9482b7047a",
      fixture_filename: "user_rot180_marker.png",
      fixture_sha256: "25ec6ecdb9819a322dc873f4481293cdc9eff940c04e2fb39ef0983ed9961240",
      kind: :transform
    },
    "zoom_anisotropic_marker" => %{
      authored_sha256: "eac5b3fab00b438243d765085142566dc4f815b41c948ffc04a586a9c4d95340",
      fixture_filename: "zoom_anisotropic_marker.png",
      fixture_sha256: "5ac5c510045e715fa730bd0644cae1961877cb973b6a361b98ea4cc6c4c11e2d",
      kind: :transform
    },
    "zoom_cover_resultcrop_marker" => %{
      authored_sha256: "4c896d07a5fda7532158bf74cec1250ef4cbe75e03d096cbd7f1cbc916a08bd2",
      fixture_filename: "zoom_cover_resultcrop_marker.png",
      fixture_sha256: "786b2dbc90f92ae5cbb6d1291af3cfdda657e7f0b38f17d4e4472587ca7eb751",
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
