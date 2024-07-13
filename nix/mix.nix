{ lib, beamPackages, overrides ? (x: y: {}) }:

let
  buildRebar3 = lib.makeOverridable beamPackages.buildRebar3;
  buildMix = lib.makeOverridable beamPackages.buildMix;
  buildErlangMk = lib.makeOverridable beamPackages.buildErlangMk;

  self = packages // (overrides self packages);

  packages = with beamPackages; with self; {
    ash = buildMix rec {
      name = "ash";
      version = "3.1.3";

      src = fetchHex {
        pkg = "ash";
        version = "${version}";
        sha256 = "530c04f32b2562352e48c92fab50bc837819c6cd3453c4fa9c9842b2e9d8483b";
      };

      beamDeps = [ comparable decimal ecto ets igniter jason plug reactor spark splode stream_data telemetry ];
    };

    ash_authentication = buildMix rec {
      name = "ash_authentication";
      version = "4.0.1";

      src = fetchHex {
        pkg = "ash_authentication";
        version = "${version}";
        sha256 = "e204585c8eed2d46a12e7031da48a169c513d5074ba43da90be0a92f7e1e0413";
      };

      beamDeps = [ ash ash_postgres assent bcrypt_elixir castore finch jason joken plug spark splode ];
    };

    ash_authentication_phoenix = buildMix rec {
      name = "ash_authentication_phoenix";
      version = "2.0.1";

      src = fetchHex {
        pkg = "ash_authentication_phoenix";
        version = "${version}";
        sha256 = "b4b38c72cb49fd6c5243e4a110b1bcd4138bb0074bb8b5a165e40d29abc1382e";
      };

      beamDeps = [ ash ash_authentication ash_phoenix bcrypt_elixir jason phoenix phoenix_html phoenix_html_helpers phoenix_live_view phoenix_view slugify ];
    };

    ash_json_api = buildMix rec {
      name = "ash_json_api";
      version = "1.3.6";

      src = fetchHex {
        pkg = "ash_json_api";
        version = "${version}";
        sha256 = "d044a9c9170529f047f92bdf14ec00cf0a49987c115938f70a336a45b50c6a73";
      };

      beamDeps = [ ash jason json_xema open_api_spex plug spark ];
    };

    ash_phoenix = buildMix rec {
      name = "ash_phoenix";
      version = "2.0.4";

      src = fetchHex {
        pkg = "ash_phoenix";
        version = "${version}";
        sha256 = "f3ea5309b42cdcaafc0ca713757cd4bb4819e02aeacc5195a040a955e861767d";
      };

      beamDeps = [ ash phoenix phoenix_html phoenix_live_view ];
    };

    ash_postgres = buildMix rec {
      name = "ash_postgres";
      version = "2.1.1";

      src = fetchHex {
        pkg = "ash_postgres";
        version = "${version}";
        sha256 = "df2e0ddef26cfdcd31c07a7f65d219a861a4eeab67fd00b42e951c903f1c1668";
      };

      beamDeps = [ ash ash_sql ecto ecto_sql igniter jason postgrex ];
    };

    ash_sql = buildMix rec {
      name = "ash_sql";
      version = "0.2.13";

      src = fetchHex {
        pkg = "ash_sql";
        version = "${version}";
        sha256 = "c493a05570873133896412fff43db6ed21f27527907cf6bbd19b380692e6fa9e";
      };

      beamDeps = [ ash ecto ecto_sql ];
    };

    assent = buildMix rec {
      name = "assent";
      version = "0.2.10";

      src = fetchHex {
        pkg = "assent";
        version = "${version}";
        sha256 = "8483bf9621e994795a70a4ad8fda725abfb6a9675d63a9bfd4217c76d4a2d82a";
      };

      beamDeps = [ certifi finch jason jose mint req ssl_verify_fun ];
    };

    bandit = buildMix rec {
      name = "bandit";
      version = "1.5.5";

      src = fetchHex {
        pkg = "bandit";
        version = "${version}";
        sha256 = "f21579a29ea4bc08440343b2b5f16f7cddf2fea5725d31b72cf973ec729079e1";
      };

      beamDeps = [ hpax plug telemetry thousand_island websock ];
    };

    bcrypt_elixir = buildMix rec {
      name = "bcrypt_elixir";
      version = "3.1.0";

      src = fetchHex {
        pkg = "bcrypt_elixir";
        version = "${version}";
        sha256 = "2ad2acb5a8bc049e8d5aa267802631912bb80d5f4110a178ae7999e69dca1bf7";
      };

      beamDeps = [ comeonin elixir_make ];
    };

    castore = buildMix rec {
      name = "castore";
      version = "1.0.8";

      src = fetchHex {
        pkg = "castore";
        version = "${version}";
        sha256 = "0b2b66d2ee742cb1d9cb8c8be3b43c3a70ee8651f37b75a8b982e036752983f1";
      };

      beamDeps = [];
    };

    certifi = buildRebar3 rec {
      name = "certifi";
      version = "2.12.0";

      src = fetchHex {
        pkg = "certifi";
        version = "${version}";
        sha256 = "ee68d85df22e554040cdb4be100f33873ac6051387baf6a8f6ce82272340ff1c";
      };

      beamDeps = [];
    };

    comeonin = buildMix rec {
      name = "comeonin";
      version = "5.4.0";

      src = fetchHex {
        pkg = "comeonin";
        version = "${version}";
        sha256 = "796393a9e50d01999d56b7b8420ab0481a7538d0caf80919da493b4a6e51faf1";
      };

      beamDeps = [];
    };

    comparable = buildMix rec {
      name = "comparable";
      version = "1.0.0";

      src = fetchHex {
        pkg = "comparable";
        version = "${version}";
        sha256 = "277c11eeb1cd726e7cd41c6c199e7e52fa16ee6830b45ad4cdc62e51f62eb60c";
      };

      beamDeps = [ typable ];
    };

    conv_case = buildMix rec {
      name = "conv_case";
      version = "0.2.3";

      src = fetchHex {
        pkg = "conv_case";
        version = "${version}";
        sha256 = "88f29a3d97d1742f9865f7e394ed3da011abb7c5e8cc104e676fdef6270d4b4a";
      };

      beamDeps = [];
    };

    db_connection = buildMix rec {
      name = "db_connection";
      version = "2.7.0";

      src = fetchHex {
        pkg = "db_connection";
        version = "${version}";
        sha256 = "dcf08f31b2701f857dfc787fbad78223d61a32204f217f15e881dd93e4bdd3ff";
      };

      beamDeps = [ telemetry ];
    };

    decimal = buildMix rec {
      name = "decimal";
      version = "2.1.1";

      src = fetchHex {
        pkg = "decimal";
        version = "${version}";
        sha256 = "53cfe5f497ed0e7771ae1a475575603d77425099ba5faef9394932b35020ffcc";
      };

      beamDeps = [];
    };

    ecto = buildMix rec {
      name = "ecto";
      version = "3.11.2";

      src = fetchHex {
        pkg = "ecto";
        version = "${version}";
        sha256 = "3c38bca2c6f8d8023f2145326cc8a80100c3ffe4dcbd9842ff867f7fc6156c65";
      };

      beamDeps = [ decimal jason telemetry ];
    };

    ecto_sql = buildMix rec {
      name = "ecto_sql";
      version = "3.11.3";

      src = fetchHex {
        pkg = "ecto_sql";
        version = "${version}";
        sha256 = "e5f36e3d736b99c7fee3e631333b8394ade4bafe9d96d35669fca2d81c2be928";
      };

      beamDeps = [ db_connection ecto postgrex telemetry ];
    };

    elixir_make = buildMix rec {
      name = "elixir_make";
      version = "0.8.4";

      src = fetchHex {
        pkg = "elixir_make";
        version = "${version}";
        sha256 = "6e7f1d619b5f61dfabd0a20aa268e575572b542ac31723293a4c1a567d5ef040";
      };

      beamDeps = [ castore certifi ];
    };

    enough = buildRebar3 rec {
      name = "enough";
      version = "0.1.0";

      src = fetchHex {
        pkg = "enough";
        version = "${version}";
        sha256 = "0460c7abda5f5e0ea592b12bc6976b8a5c4b96e42f332059cd396525374bf9a1";
      };

      beamDeps = [];
    };

    esbuild = buildMix rec {
      name = "esbuild";
      version = "0.8.1";

      src = fetchHex {
        pkg = "esbuild";
        version = "${version}";
        sha256 = "25fc876a67c13cb0a776e7b5d7974851556baeda2085296c14ab48555ea7560f";
      };

      beamDeps = [ castore jason ];
    };

    ets = buildMix rec {
      name = "ets";
      version = "0.9.0";

      src = fetchHex {
        pkg = "ets";
        version = "${version}";
        sha256 = "2861fdfb04bcaeff370f1a5904eec864f0a56dcfebe5921ea9aadf2a481c822b";
      };

      beamDeps = [];
    };

    ex_json_schema = buildMix rec {
      name = "ex_json_schema";
      version = "0.10.2";

      src = fetchHex {
        pkg = "ex_json_schema";
        version = "${version}";
        sha256 = "37f43be60f8407659d4d0155a7e45e7f406dab1f827051d3d35858a709baf6a6";
      };

      beamDeps = [ decimal ];
    };

    expo = buildMix rec {
      name = "expo";
      version = "0.5.2";

      src = fetchHex {
        pkg = "expo";
        version = "${version}";
        sha256 = "8c9bfa06ca017c9cb4020fabe980bc7fdb1aaec059fd004c2ab3bff03b1c599c";
      };

      beamDeps = [];
    };

    file_system = buildMix rec {
      name = "file_system";
      version = "1.0.0";

      src = fetchHex {
        pkg = "file_system";
        version = "${version}";
        sha256 = "6752092d66aec5a10e662aefeed8ddb9531d79db0bc145bb8c40325ca1d8536d";
      };

      beamDeps = [];
    };

    finch = buildMix rec {
      name = "finch";
      version = "0.18.0";

      src = fetchHex {
        pkg = "finch";
        version = "${version}";
        sha256 = "69f5045b042e531e53edc2574f15e25e735b522c37e2ddb766e15b979e03aa65";
      };

      beamDeps = [ castore mime mint nimble_options nimble_pool telemetry ];
    };

    floki = buildMix rec {
      name = "floki";
      version = "0.36.2";

      src = fetchHex {
        pkg = "floki";
        version = "${version}";
        sha256 = "a8766c0bc92f074e5cb36c4f9961982eda84c5d2b8e979ca67f5c268ec8ed580";
      };

      beamDeps = [];
    };

    gettext = buildMix rec {
      name = "gettext";
      version = "0.24.0";

      src = fetchHex {
        pkg = "gettext";
        version = "${version}";
        sha256 = "bdf75cdfcbe9e4622dd18e034b227d77dd17f0f133853a1c73b97b3d6c770e8b";
      };

      beamDeps = [ expo ];
    };

    glob_ex = buildMix rec {
      name = "glob_ex";
      version = "0.1.7";

      src = fetchHex {
        pkg = "glob_ex";
        version = "${version}";
        sha256 = "decc1c21c0c73df3c9c994412716345c1692477b9470e337f628a7e08da0da6a";
      };

      beamDeps = [];
    };

    hackney = buildRebar3 rec {
      name = "hackney";
      version = "1.20.1";

      src = fetchHex {
        pkg = "hackney";
        version = "${version}";
        sha256 = "fe9094e5f1a2a2c0a7d10918fee36bfec0ec2a979994cff8cfe8058cd9af38e3";
      };

      beamDeps = [ certifi idna metrics mimerl parse_trans ssl_verify_fun unicode_util_compat ];
    };

    hpax = buildMix rec {
      name = "hpax";
      version = "0.2.0";

      src = fetchHex {
        pkg = "hpax";
        version = "${version}";
        sha256 = "bea06558cdae85bed075e6c036993d43cd54d447f76d8190a8db0dc5893fa2f1";
      };

      beamDeps = [];
    };

    idna = buildRebar3 rec {
      name = "idna";
      version = "6.1.1";

      src = fetchHex {
        pkg = "idna";
        version = "${version}";
        sha256 = "92376eb7894412ed19ac475e4a86f7b413c1b9fbb5bd16dccd57934157944cea";
      };

      beamDeps = [ unicode_util_compat ];
    };

    igniter = buildMix rec {
      name = "igniter";
      version = "0.2.12";

      src = fetchHex {
        pkg = "igniter";
        version = "${version}";
        sha256 = "51f3487a13441cd3e6e0d559689f8b0ba2c716834f86802e8a6760fdd1a2e579";
      };

      beamDeps = [ glob_ex nimble_options req rewrite sourceror spitfire ];
    };

    jason = buildMix rec {
      name = "jason";
      version = "1.4.3";

      src = fetchHex {
        pkg = "jason";
        version = "${version}";
        sha256 = "9a90e868927f7c777689baa16d86f4d0e086d968db5c05d917ccff6d443e58a3";
      };

      beamDeps = [ decimal ];
    };

    joken = buildMix rec {
      name = "joken";
      version = "2.6.1";

      src = fetchHex {
        pkg = "joken";
        version = "${version}";
        sha256 = "ab26122c400b3d254ce7d86ed066d6afad27e70416df947cdcb01e13a7382e68";
      };

      beamDeps = [ jose ];
    };

    jose = buildMix rec {
      name = "jose";
      version = "1.11.10";

      src = fetchHex {
        pkg = "jose";
        version = "${version}";
        sha256 = "0d6cd36ff8ba174db29148fc112b5842186b68a90ce9fc2b3ec3afe76593e614";
      };

      beamDeps = [];
    };

    json_xema = buildMix rec {
      name = "json_xema";
      version = "0.6.2";

      src = fetchHex {
        pkg = "json_xema";
        version = "${version}";
        sha256 = "50c84c537c95fcc76677f1f030af4aed188f538820fc488aeaa3f7dfe04d0edf";
      };

      beamDeps = [ conv_case xema ];
    };

    libgraph = buildMix rec {
      name = "libgraph";
      version = "0.16.0";

      src = fetchHex {
        pkg = "libgraph";
        version = "${version}";
        sha256 = "41ca92240e8a4138c30a7e06466acc709b0cbb795c643e9e17174a178982d6bf";
      };

      beamDeps = [];
    };

    makeup = buildMix rec {
      name = "makeup";
      version = "1.1.2";

      src = fetchHex {
        pkg = "makeup";
        version = "${version}";
        sha256 = "cce1566b81fbcbd21eca8ffe808f33b221f9eee2cbc7a1706fc3da9ff18e6cac";
      };

      beamDeps = [ nimble_parsec ];
    };

    makeup_json = buildMix rec {
      name = "makeup_json";
      version = "0.1.1";

      src = fetchHex {
        pkg = "makeup_json";
        version = "${version}";
        sha256 = "3879d78117e37a9b1e567b9cc76c1b5b51b9efc5f4f4301ea5e53fb70c59c718";
      };

      beamDeps = [ makeup nimble_parsec ];
    };

    metrics = buildRebar3 rec {
      name = "metrics";
      version = "1.0.1";

      src = fetchHex {
        pkg = "metrics";
        version = "${version}";
        sha256 = "69b09adddc4f74a40716ae54d140f93beb0fb8978d8636eaded0c31b6f099f16";
      };

      beamDeps = [];
    };

    mime = buildMix rec {
      name = "mime";
      version = "2.0.6";

      src = fetchHex {
        pkg = "mime";
        version = "${version}";
        sha256 = "c9945363a6b26d747389aac3643f8e0e09d30499a138ad64fe8fd1d13d9b153e";
      };

      beamDeps = [];
    };

    mimerl = buildRebar3 rec {
      name = "mimerl";
      version = "1.3.0";

      src = fetchHex {
        pkg = "mimerl";
        version = "${version}";
        sha256 = "a1e15a50d1887217de95f0b9b0793e32853f7c258a5cd227650889b38839fe9d";
      };

      beamDeps = [];
    };

    mint = buildMix rec {
      name = "mint";
      version = "1.6.2";

      src = fetchHex {
        pkg = "mint";
        version = "${version}";
        sha256 = "5ee441dffc1892f1ae59127f74afe8fd82fda6587794278d924e4d90ea3d63f9";
      };

      beamDeps = [ castore hpax ];
    };

    nimble_options = buildMix rec {
      name = "nimble_options";
      version = "1.1.1";

      src = fetchHex {
        pkg = "nimble_options";
        version = "${version}";
        sha256 = "821b2470ca9442c4b6984882fe9bb0389371b8ddec4d45a9504f00a66f650b44";
      };

      beamDeps = [];
    };

    nimble_ownership = buildMix rec {
      name = "nimble_ownership";
      version = "0.3.1";

      src = fetchHex {
        pkg = "nimble_ownership";
        version = "${version}";
        sha256 = "4bf510adedff0449a1d6e200e43e57a814794c8b5b6439071274d248d272a549";
      };

      beamDeps = [];
    };

    nimble_parsec = buildMix rec {
      name = "nimble_parsec";
      version = "1.4.0";

      src = fetchHex {
        pkg = "nimble_parsec";
        version = "${version}";
        sha256 = "9c565862810fb383e9838c1dd2d7d2c437b3d13b267414ba6af33e50d2d1cf28";
      };

      beamDeps = [];
    };

    nimble_pool = buildMix rec {
      name = "nimble_pool";
      version = "1.1.0";

      src = fetchHex {
        pkg = "nimble_pool";
        version = "${version}";
        sha256 = "af2e4e6b34197db81f7aad230c1118eac993acc0dae6bc83bac0126d4ae0813a";
      };

      beamDeps = [];
    };

    open_api_spex = buildMix rec {
      name = "open_api_spex";
      version = "3.20.0";

      src = fetchHex {
        pkg = "open_api_spex";
        version = "${version}";
        sha256 = "2e9beea71142ff09f8f935579b39406e2c6b5a3978e7235978d7faf2f90cd081";
      };

      beamDeps = [ jason plug ];
    };

    parse_trans = buildRebar3 rec {
      name = "parse_trans";
      version = "3.4.1";

      src = fetchHex {
        pkg = "parse_trans";
        version = "${version}";
        sha256 = "620a406ce75dada827b82e453c19cf06776be266f5a67cff34e1ef2cbb60e49a";
      };

      beamDeps = [];
    };

    phoenix = buildMix rec {
      name = "phoenix";
      version = "1.7.14";

      src = fetchHex {
        pkg = "phoenix";
        version = "${version}";
        sha256 = "c7859bc56cc5dfef19ecfc240775dae358cbaa530231118a9e014df392ace61a";
      };

      beamDeps = [ castore jason phoenix_pubsub phoenix_template phoenix_view plug plug_crypto telemetry websock_adapter ];
    };

    phoenix_ecto = buildMix rec {
      name = "phoenix_ecto";
      version = "4.6.2";

      src = fetchHex {
        pkg = "phoenix_ecto";
        version = "${version}";
        sha256 = "3f94d025f59de86be00f5f8c5dd7b5965a3298458d21ab1c328488be3b5fcd59";
      };

      beamDeps = [ ecto phoenix_html plug postgrex ];
    };

    phoenix_html = buildMix rec {
      name = "phoenix_html";
      version = "4.1.1";

      src = fetchHex {
        pkg = "phoenix_html";
        version = "${version}";
        sha256 = "f2f2df5a72bc9a2f510b21497fd7d2b86d932ec0598f0210fed4114adc546c6f";
      };

      beamDeps = [];
    };

    phoenix_html_helpers = buildMix rec {
      name = "phoenix_html_helpers";
      version = "1.0.1";

      src = fetchHex {
        pkg = "phoenix_html_helpers";
        version = "${version}";
        sha256 = "cffd2385d1fa4f78b04432df69ab8da63dc5cf63e07b713a4dcf36a3740e3090";
      };

      beamDeps = [ phoenix_html plug ];
    };

    phoenix_live_dashboard = buildMix rec {
      name = "phoenix_live_dashboard";
      version = "0.8.4";

      src = fetchHex {
        pkg = "phoenix_live_dashboard";
        version = "${version}";
        sha256 = "2984aae96994fbc5c61795a73b8fb58153b41ff934019cfb522343d2d3817d59";
      };

      beamDeps = [ ecto mime phoenix_live_view telemetry_metrics ];
    };

    phoenix_live_reload = buildMix rec {
      name = "phoenix_live_reload";
      version = "1.5.3";

      src = fetchHex {
        pkg = "phoenix_live_reload";
        version = "${version}";
        sha256 = "b4ec9cd73cb01ff1bd1cac92e045d13e7030330b74164297d1aee3907b54803c";
      };

      beamDeps = [ file_system phoenix ];
    };

    phoenix_live_view = buildMix rec {
      name = "phoenix_live_view";
      version = "0.20.17";

      src = fetchHex {
        pkg = "phoenix_live_view";
        version = "${version}";
        sha256 = "a61d741ffb78c85fdbca0de084da6a48f8ceb5261a79165b5a0b59e5f65ce98b";
      };

      beamDeps = [ floki jason phoenix phoenix_html phoenix_template phoenix_view plug telemetry ];
    };

    phoenix_pubsub = buildMix rec {
      name = "phoenix_pubsub";
      version = "2.1.3";

      src = fetchHex {
        pkg = "phoenix_pubsub";
        version = "${version}";
        sha256 = "bba06bc1dcfd8cb086759f0edc94a8ba2bc8896d5331a1e2c2902bf8e36ee502";
      };

      beamDeps = [];
    };

    phoenix_template = buildMix rec {
      name = "phoenix_template";
      version = "1.0.4";

      src = fetchHex {
        pkg = "phoenix_template";
        version = "${version}";
        sha256 = "2c0c81f0e5c6753faf5cca2f229c9709919aba34fab866d3bc05060c9c444206";
      };

      beamDeps = [ phoenix_html ];
    };

    phoenix_view = buildMix rec {
      name = "phoenix_view";
      version = "2.0.4";

      src = fetchHex {
        pkg = "phoenix_view";
        version = "${version}";
        sha256 = "4e992022ce14f31fe57335db27a28154afcc94e9983266835bb3040243eb620b";
      };

      beamDeps = [ phoenix_html phoenix_template ];
    };

    plug = buildMix rec {
      name = "plug";
      version = "1.16.1";

      src = fetchHex {
        pkg = "plug";
        version = "${version}";
        sha256 = "a13ff6b9006b03d7e33874945b2755253841b238c34071ed85b0e86057f8cddc";
      };

      beamDeps = [ mime plug_crypto telemetry ];
    };

    plug_crypto = buildMix rec {
      name = "plug_crypto";
      version = "2.1.0";

      src = fetchHex {
        pkg = "plug_crypto";
        version = "${version}";
        sha256 = "131216a4b030b8f8ce0f26038bc4421ae60e4bb95c5cf5395e1421437824c4fa";
      };

      beamDeps = [];
    };

    postgrex = buildMix rec {
      name = "postgrex";
      version = "0.18.0";

      src = fetchHex {
        pkg = "postgrex";
        version = "${version}";
        sha256 = "a042989ba1bc1cca7383ebb9e461398e3f89f868c92ce6671feb7ef132a252d1";
      };

      beamDeps = [ db_connection decimal jason ];
    };

    reactor = buildMix rec {
      name = "reactor";
      version = "0.8.5";

      src = fetchHex {
        pkg = "reactor";
        version = "${version}";
        sha256 = "17b1976b9d333e55382dc108779078d5bbdbcd2c3d4033ea6dd52437339fe469";
      };

      beamDeps = [ igniter libgraph spark splode telemetry ];
    };

    redoc_ui_plug = buildMix rec {
      name = "redoc_ui_plug";
      version = "0.2.1";

      src = fetchHex {
        pkg = "redoc_ui_plug";
        version = "${version}";
        sha256 = "7be01db31f210887e9fc18f8fbccc7788de32c482b204623556e415ed1fe714b";
      };

      beamDeps = [ jason plug ];
    };

    req = buildMix rec {
      name = "req";
      version = "0.5.2";

      src = fetchHex {
        pkg = "req";
        version = "${version}";
        sha256 = "0c63539ab4c2d6ced6114d2684276cef18ac185ee00674ee9af4b1febba1f986";
      };

      beamDeps = [ finch jason mime plug ];
    };

    rewrite = buildMix rec {
      name = "rewrite";
      version = "0.10.5";

      src = fetchHex {
        pkg = "rewrite";
        version = "${version}";
        sha256 = "51cc347a4269ad3a1e7a2c4122dbac9198302b082f5615964358b4635ebf3d4f";
      };

      beamDeps = [ glob_ex sourceror ];
    };

    sentry = buildMix rec {
      name = "sentry";
      version = "10.6.2";

      src = fetchHex {
        pkg = "sentry";
        version = "${version}";
        sha256 = "31bb84247274f9262fd300df0e3eb73302e4849cc6b7a6560bb2465f03fbd446";
      };

      beamDeps = [ hackney jason nimble_options nimble_ownership phoenix phoenix_live_view plug telemetry ];
    };

    slugify = buildMix rec {
      name = "slugify";
      version = "1.3.1";

      src = fetchHex {
        pkg = "slugify";
        version = "${version}";
        sha256 = "cb090bbeb056b312da3125e681d98933a360a70d327820e4b7f91645c4d8be76";
      };

      beamDeps = [];
    };

    sourceror = buildMix rec {
      name = "sourceror";
      version = "1.4.0";

      src = fetchHex {
        pkg = "sourceror";
        version = "${version}";
        sha256 = "16751ca55e3895f2228938b703ad399b0b27acfe288eff6c0e629ed3e6ec0358";
      };

      beamDeps = [];
    };

    spark = buildMix rec {
      name = "spark";
      version = "2.2.7";

      src = fetchHex {
        pkg = "spark";
        version = "${version}";
        sha256 = "e192add56a260382d4d270e1490401786f96545b86d67b466544cecb48c3f9a4";
      };

      beamDeps = [ igniter jason sourceror ];
    };

    spitfire = buildMix rec {
      name = "spitfire";
      version = "0.1.3";

      src = fetchHex {
        pkg = "spitfire";
        version = "${version}";
        sha256 = "d53b5107bcff526a05c5bb54c95e77b36834550affd5830c9f58760e8c543657";
      };

      beamDeps = [];
    };

    splode = buildMix rec {
      name = "splode";
      version = "0.2.4";

      src = fetchHex {
        pkg = "splode";
        version = "${version}";
        sha256 = "ca3b95f0d8d4b482b5357954fec857abd0fa3ea509d623334c1328e7382044c2";
      };

      beamDeps = [];
    };

    ssl_verify_fun = buildRebar3 rec {
      name = "ssl_verify_fun";
      version = "1.1.7";

      src = fetchHex {
        pkg = "ssl_verify_fun";
        version = "${version}";
        sha256 = "fe4c190e8f37401d30167c8c405eda19469f34577987c76dde613e838bbc67f8";
      };

      beamDeps = [];
    };

    stream_data = buildMix rec {
      name = "stream_data";
      version = "1.1.1";

      src = fetchHex {
        pkg = "stream_data";
        version = "${version}";
        sha256 = "45d0cd46bd06738463fd53f22b70042dbb58c384bb99ef4e7576e7bb7d3b8c8c";
      };

      beamDeps = [];
    };

    swoosh = buildMix rec {
      name = "swoosh";
      version = "1.16.9";

      src = fetchHex {
        pkg = "swoosh";
        version = "${version}";
        sha256 = "878b1a7a6c10ebbf725a3349363f48f79c5e3d792eb621643b0d276a38acc0a6";
      };

      beamDeps = [ bandit finch hackney jason mime plug req telemetry ];
    };

    systemd = buildRebar3 rec {
      name = "systemd";
      version = "0.6.2";

      src = fetchHex {
        pkg = "systemd";
        version = "${version}";
        sha256 = "5062b911800c1ab05157c7bf9a9fbe23dd24c58891c87fd12d2e3ed8fc1708b8";
      };

      beamDeps = [ enough ];
    };

    tailwind = buildMix rec {
      name = "tailwind";
      version = "0.2.3";

      src = fetchHex {
        pkg = "tailwind";
        version = "${version}";
        sha256 = "8e45e7a34a676a7747d04f7913a96c770c85e6be810a1d7f91e713d3a3655b5d";
      };

      beamDeps = [ castore ];
    };

    telemetry = buildRebar3 rec {
      name = "telemetry";
      version = "1.2.1";

      src = fetchHex {
        pkg = "telemetry";
        version = "${version}";
        sha256 = "dad9ce9d8effc621708f99eac538ef1cbe05d6a874dd741de2e689c47feafed5";
      };

      beamDeps = [];
    };

    telemetry_metrics = buildMix rec {
      name = "telemetry_metrics";
      version = "1.0.0";

      src = fetchHex {
        pkg = "telemetry_metrics";
        version = "${version}";
        sha256 = "f23713b3847286a534e005126d4c959ebcca68ae9582118ce436b521d1d47d5d";
      };

      beamDeps = [ telemetry ];
    };

    telemetry_poller = buildRebar3 rec {
      name = "telemetry_poller";
      version = "1.1.0";

      src = fetchHex {
        pkg = "telemetry_poller";
        version = "${version}";
        sha256 = "9eb9d9cbfd81cbd7cdd24682f8711b6e2b691289a0de6826e58452f28c103c8f";
      };

      beamDeps = [ telemetry ];
    };

    thousand_island = buildMix rec {
      name = "thousand_island";
      version = "1.3.5";

      src = fetchHex {
        pkg = "thousand_island";
        version = "${version}";
        sha256 = "2be6954916fdfe4756af3239fb6b6d75d0b8063b5df03ba76fd8a4c87849e180";
      };

      beamDeps = [ telemetry ];
    };

    typable = buildMix rec {
      name = "typable";
      version = "0.3.0";

      src = fetchHex {
        pkg = "typable";
        version = "${version}";
        sha256 = "880a0797752da1a4c508ac48f94711e04c86156f498065a83d160eef945858f8";
      };

      beamDeps = [];
    };

    unicode_util_compat = buildRebar3 rec {
      name = "unicode_util_compat";
      version = "0.7.0";

      src = fetchHex {
        pkg = "unicode_util_compat";
        version = "${version}";
        sha256 = "25eee6d67df61960cf6a794239566599b09e17e668d3700247bc498638152521";
      };

      beamDeps = [];
    };

    websock = buildMix rec {
      name = "websock";
      version = "0.5.3";

      src = fetchHex {
        pkg = "websock";
        version = "${version}";
        sha256 = "6105453d7fac22c712ad66fab1d45abdf049868f253cf719b625151460b8b453";
      };

      beamDeps = [];
    };

    websock_adapter = buildMix rec {
      name = "websock_adapter";
      version = "0.5.6";

      src = fetchHex {
        pkg = "websock_adapter";
        version = "${version}";
        sha256 = "e04378d26b0af627817ae84c92083b7e97aca3121196679b73c73b99d0d133ea";
      };

      beamDeps = [ bandit plug websock ];
    };

    xema = buildMix rec {
      name = "xema";
      version = "0.17.4";

      src = fetchHex {
        pkg = "xema";
        version = "${version}";
        sha256 = "faf638de7c424326f089475db8077c86506af971537eb2097e06124c5e0e4240";
      };

      beamDeps = [ conv_case decimal ];
    };
  };
in self

