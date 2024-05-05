{ lib, beamPackages, overrides ? (x: y: {}) }:

let
  buildRebar3 = lib.makeOverridable beamPackages.buildRebar3;
  buildMix = lib.makeOverridable beamPackages.buildMix;
  buildErlangMk = lib.makeOverridable beamPackages.buildErlangMk;

  self = packages // (overrides self packages);

  packages = with beamPackages; with self; {
    ash = buildMix rec {
      name = "ash";
      version = "3.0.0-rc.45";

      src = fetchHex {
        pkg = "ash";
        version = "${version}";
        sha256 = "1a3261257aee24a59c66db289163b9e16d91cdbc0c6b3ac7eaf64a8a8e45c842";
      };

      beamDeps = [ comparable decimal ecto ets jason plug reactor spark splode stream_data telemetry ];
    };

    ash_phoenix = buildMix rec {
      name = "ash_phoenix";
      version = "2.0.0-rc.8";

      src = fetchHex {
        pkg = "ash_phoenix";
        version = "${version}";
        sha256 = "891ac97c7ee1fe96ad6fd0b56f7081930d10bab92cee753d3d2ed026221be372";
      };

      beamDeps = [ ash phoenix phoenix_html phoenix_live_view ];
    };

    ash_postgres = buildMix rec {
      name = "ash_postgres";
      version = "2.0.0-rc.14";

      src = fetchHex {
        pkg = "ash_postgres";
        version = "${version}";
        sha256 = "d8f870020bfd4b53ba9f07a019fdaf8086c24c51cfd722fbb576a2b92dc50e88";
      };

      beamDeps = [ ash ash_sql ecto ecto_sql jason postgrex ];
    };

    ash_sql = buildMix rec {
      name = "ash_sql";
      version = "0.1.1-rc.17";

      src = fetchHex {
        pkg = "ash_sql";
        version = "${version}";
        sha256 = "0eda1e606959d6fb85c665f7465397792f0c128761db8177f1683807020e5f67";
      };

      beamDeps = [ ash ecto ecto_sql ];
    };

    bandit = buildMix rec {
      name = "bandit";
      version = "1.5.0";

      src = fetchHex {
        pkg = "bandit";
        version = "${version}";
        sha256 = "92d18d9a7228a597e0d4661ef69a874ea82d63ff49c7d801a5c68cb18ebbbd72";
      };

      beamDeps = [ hpax plug telemetry thousand_island websock ];
    };

    castore = buildMix rec {
      name = "castore";
      version = "1.0.7";

      src = fetchHex {
        pkg = "castore";
        version = "${version}";
        sha256 = "da7785a4b0d2a021cd1292a60875a784b6caef71e76bf4917bdee1f390455cf5";
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

    db_connection = buildMix rec {
      name = "db_connection";
      version = "2.6.0";

      src = fetchHex {
        pkg = "db_connection";
        version = "${version}";
        sha256 = "c2f992d15725e721ec7fbc1189d4ecdb8afef76648c746a8e1cad35e3b8a35f3";
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
      version = "3.11.1";

      src = fetchHex {
        pkg = "ecto_sql";
        version = "${version}";
        sha256 = "ce14063ab3514424276e7e360108ad6c2308f6d88164a076aac8a387e1fea634";
      };

      beamDeps = [ db_connection ecto postgrex telemetry ];
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
      version = "0.1.2";

      src = fetchHex {
        pkg = "hpax";
        version = "${version}";
        sha256 = "2c87843d5a23f5f16748ebe77969880e29809580efdaccd615cd3bed628a8c13";
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

    jason = buildMix rec {
      name = "jason";
      version = "1.4.1";

      src = fetchHex {
        pkg = "jason";
        version = "${version}";
        sha256 = "fbb01ecdfd565b56261302f7e1fcc27c4fb8f32d56eab74db621fc154604a7a1";
      };

      beamDeps = [ decimal ];
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
      version = "1.1.1";

      src = fetchHex {
        pkg = "makeup";
        version = "${version}";
        sha256 = "5dc62fbdd0de44de194898b6710692490be74baa02d9d108bc29f007783b0b48";
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
      version = "2.0.5";

      src = fetchHex {
        pkg = "mime";
        version = "${version}";
        sha256 = "da0d64a365c45bc9935cc5c8a7fc5e49a0e0f9932a761c55d6c52b142780a05c";
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
      version = "1.6.0";

      src = fetchHex {
        pkg = "mint";
        version = "${version}";
        sha256 = "3c5ae85d90a5aca0a49c0d8b67360bbe407f3b54f1030a111047ff988e8fefaa";
      };

      beamDeps = [ castore hpax ];
    };

    nimble_options = buildMix rec {
      name = "nimble_options";
      version = "1.1.0";

      src = fetchHex {
        pkg = "nimble_options";
        version = "${version}";
        sha256 = "8bbbb3941af3ca9acc7835f5655ea062111c9c27bcac53e004460dfd19008a99";
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
      version = "1.7.12";

      src = fetchHex {
        pkg = "phoenix";
        version = "${version}";
        sha256 = "d646192fbade9f485b01bc9920c139bfdd19d0f8df3d73fd8eaf2dfbe0d2837c";
      };

      beamDeps = [ castore jason phoenix_pubsub phoenix_template plug plug_crypto telemetry websock_adapter ];
    };

    phoenix_ecto = buildMix rec {
      name = "phoenix_ecto";
      version = "4.5.1";

      src = fetchHex {
        pkg = "phoenix_ecto";
        version = "${version}";
        sha256 = "ebe43aa580db129e54408e719fb9659b7f9e0d52b965c5be26cdca416ecead28";
      };

      beamDeps = [ ecto phoenix_html plug ];
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

    phoenix_live_dashboard = buildMix rec {
      name = "phoenix_live_dashboard";
      version = "0.8.3";

      src = fetchHex {
        pkg = "phoenix_live_dashboard";
        version = "${version}";
        sha256 = "f9470a0a8bae4f56430a23d42f977b5a6205fdba6559d76f932b876bfaec652d";
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
      version = "0.20.14";

      src = fetchHex {
        pkg = "phoenix_live_view";
        version = "${version}";
        sha256 = "82f6d006c5264f979ed5eb75593d808bbe39020f20df2e78426f4f2d570e2402";
      };

      beamDeps = [ floki jason phoenix phoenix_html phoenix_template plug telemetry ];
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

    plug = buildMix rec {
      name = "plug";
      version = "1.15.3";

      src = fetchHex {
        pkg = "plug";
        version = "${version}";
        sha256 = "cc4365a3c010a56af402e0809208873d113e9c38c401cabd88027ef4f5c01fd2";
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
      version = "0.17.5";

      src = fetchHex {
        pkg = "postgrex";
        version = "${version}";
        sha256 = "50b8b11afbb2c4095a3ba675b4f055c416d0f3d7de6633a595fc131a828a67eb";
      };

      beamDeps = [ db_connection decimal jason ];
    };

    reactor = buildMix rec {
      name = "reactor";
      version = "0.8.1";

      src = fetchHex {
        pkg = "reactor";
        version = "${version}";
        sha256 = "ae3936d97a3e4a316744f70c77b85345b08b70da334024c26e6b5eb8ede1246b";
      };

      beamDeps = [ libgraph spark splode telemetry ];
    };

    sentry = buildMix rec {
      name = "sentry";
      version = "10.5.0";

      src = fetchHex {
        pkg = "sentry";
        version = "${version}";
        sha256 = "375e2e3dee2bc42da2ebee88a9d8fc65ccd26451da2588b94c6b166eb869f147";
      };

      beamDeps = [ hackney jason nimble_options nimble_ownership phoenix phoenix_live_view plug telemetry ];
    };

    sourceror = buildMix rec {
      name = "sourceror";
      version = "1.0.3";

      src = fetchHex {
        pkg = "sourceror";
        version = "${version}";
        sha256 = "56c21ef146c00b51bc3bb78d1f047cb732d193256a7c4ba91eaf828d3ae826af";
      };

      beamDeps = [];
    };

    spark = buildMix rec {
      name = "spark";
      version = "2.1.20";

      src = fetchHex {
        pkg = "spark";
        version = "${version}";
        sha256 = "e7a4f8f8ca7a477918af1eb65e20f2015f783a9a23e5f73d1020edf5b2ef69be";
      };

      beamDeps = [ jason sourceror ];
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
      version = "0.6.0";

      src = fetchHex {
        pkg = "stream_data";
        version = "${version}";
        sha256 = "b92b5031b650ca480ced047578f1d57ea6dd563f5b57464ad274718c9c29501c";
      };

      beamDeps = [];
    };

    swoosh = buildMix rec {
      name = "swoosh";
      version = "1.16.5";

      src = fetchHex {
        pkg = "swoosh";
        version = "${version}";
        sha256 = "b2324cf696b09ee52e5e1049dcc77880a11fe618a381e2df1c5ca5d69c380eb0";
      };

      beamDeps = [ bandit finch hackney jason mime plug telemetry ];
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
      version = "0.2.2";

      src = fetchHex {
        pkg = "tailwind";
        version = "${version}";
        sha256 = "ccfb5025179ea307f7f899d1bb3905cd0ac9f687ed77feebc8f67bdca78565c4";
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
  };
in self

