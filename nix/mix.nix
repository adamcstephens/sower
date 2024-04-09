{ lib, beamPackages, overrides ? (x: y: {}) }:

let
  buildRebar3 = lib.makeOverridable beamPackages.buildRebar3;
  buildMix = lib.makeOverridable beamPackages.buildMix;
  buildErlangMk = lib.makeOverridable beamPackages.buildErlangMk;

  self = packages // (overrides self packages);

  packages = with beamPackages; with self; {
    ash = buildMix rec {
      name = "ash";
      version = "3.0.0-rc.17";

      src = fetchHex {
        pkg = "ash";
        version = "${version}";
        sha256 = "73f2b7db8b11d52995b1ad629b7f78d00f3de97b882d50c443e404227fbd1141";
      };

      beamDeps = [ comparable decimal ecto ets jason plug reactor spark splode stream_data telemetry ];
    };

    ash_phoenix = buildMix rec {
      name = "ash_phoenix";
      version = "2.0.0-rc.4";

      src = fetchHex {
        pkg = "ash_phoenix";
        version = "${version}";
        sha256 = "d735e445405361dbbc7e93df99246b48bd8d6bd1dbf6e55490d3ba21b5b8f7ca";
      };

      beamDeps = [ ash phoenix phoenix_html phoenix_live_view ];
    };

    ash_postgres = buildMix rec {
      name = "ash_postgres";
      version = "2.0.0-rc.5";

      src = fetchHex {
        pkg = "ash_postgres";
        version = "${version}";
        sha256 = "9577ea507ea9024d6255a1072f54098d923e347b33853b7f46f3b384cdba519c";
      };

      beamDeps = [ ash ash_sql ecto ecto_sql jason postgrex ];
    };

    ash_sql = buildMix rec {
      name = "ash_sql";
      version = "0.1.1-rc.4";

      src = fetchHex {
        pkg = "ash_sql";
        version = "${version}";
        sha256 = "329065f9d119f55444908933cfb9e4a47ea82bfd23ac46c040d517f669d9d385";
      };

      beamDeps = [ ash ecto ecto_sql ];
    };

    bandit = buildMix rec {
      name = "bandit";
      version = "1.4.2";

      src = fetchHex {
        pkg = "bandit";
        version = "${version}";
        sha256 = "3db8bacea631bd926cc62ccad58edfee4252d1b4c5cccbbad9825df2722b884f";
      };

      beamDeps = [ hpax plug telemetry thousand_island websock ];
    };

    castore = buildMix rec {
      name = "castore";
      version = "1.0.6";

      src = fetchHex {
        pkg = "castore";
        version = "${version}";
        sha256 = "374c6e7ca752296be3d6780a6d5b922854ffcc74123da90f2f328996b962d33a";
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
      version = "0.36.1";

      src = fetchHex {
        pkg = "floki";
        version = "${version}";
        sha256 = "21ba57abb8204bcc70c439b423fc0dd9f0286de67dc82773a14b0200ada0995f";
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

    mint = buildMix rec {
      name = "mint";
      version = "1.5.2";

      src = fetchHex {
        pkg = "mint";
        version = "${version}";
        sha256 = "d77d9e9ce4eb35941907f1d3df38d8f750c357865353e21d335bdcdf6d892a02";
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

    phoenix = buildMix rec {
      name = "phoenix";
      version = "1.7.11";

      src = fetchHex {
        pkg = "phoenix";
        version = "${version}";
        sha256 = "b1ec57f2e40316b306708fe59b92a16b9f6f4bf50ccfa41aa8c7feb79e0ec02a";
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
      version = "2.0.0";

      src = fetchHex {
        pkg = "plug_crypto";
        version = "${version}";
        sha256 = "53695bae57cc4e54566d993eb01074e4d894b65a3766f1c43e2c61a1b0f45ea9";
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

    sourceror = buildMix rec {
      name = "sourceror";
      version = "1.0.2";

      src = fetchHex {
        pkg = "sourceror";
        version = "${version}";
        sha256 = "832335e87d0913658f129d58b2a7dc0490ddd4487b02de6d85bca0169ec2bd79";
      };

      beamDeps = [];
    };

    spark = buildMix rec {
      name = "spark";
      version = "2.1.13";

      src = fetchHex {
        pkg = "spark";
        version = "${version}";
        sha256 = "2d5580313bbf6717d650a27554a66c83e10d164e7087e3c4082cdb23b5dc5c64";
      };

      beamDeps = [ jason sourceror ];
    };

    splode = buildMix rec {
      name = "splode";
      version = "0.2.2";

      src = fetchHex {
        pkg = "splode";
        version = "${version}";
        sha256 = "8e02f47fac4bff7cfd29a65611ee3ab728dcc9c70a5c2e438addb8f25713265a";
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
      version = "1.16.3";

      src = fetchHex {
        pkg = "swoosh";
        version = "${version}";
        sha256 = "ff70980087650a72951ebd109a286d83c270e2b6610aba447140562adff8cf0a";
      };

      beamDeps = [ bandit finch jason mime plug telemetry ];
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
      version = "0.6.2";

      src = fetchHex {
        pkg = "telemetry_metrics";
        version = "${version}";
        sha256 = "9b43db0dc33863930b9ef9d27137e78974756f5f198cae18409970ed6fa5b561";
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

