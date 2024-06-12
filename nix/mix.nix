{
  lib,
  beamPackages,
  overrides ? (x: y: { }),
}:

let
  buildRebar3 = lib.makeOverridable beamPackages.buildRebar3;
  buildMix = lib.makeOverridable beamPackages.buildMix;
  buildErlangMk = lib.makeOverridable beamPackages.buildErlangMk;

  self = packages // (overrides self packages);

  packages =
    with beamPackages;
    with self;
    {
      ash = buildMix rec {
        name = "ash";
        version = "3.0.8";

        src = fetchHex {
          pkg = "ash";
          version = "${version}";
          sha256 = "92436ab7c465d8a8706383cb9cfd9fbf074d4bd8632b86895a6e6bf3b9eee2cd";
        };

        beamDeps = [
          comparable
          decimal
          ecto
          ets
          jason
          plug
          reactor
          spark
          splode
          stream_data
          telemetry
        ];
      };

      ash_authentication = buildMix rec {
        name = "ash_authentication";
        version = "4.0.0";

        src = fetchHex {
          pkg = "ash_authentication";
          version = "${version}";
          sha256 = "9da852e60c89596e35363f7866f6500bad1639b5e8c626a77ccad20d40db91f5";
        };

        beamDeps = [
          ash
          ash_postgres
          assent
          bcrypt_elixir
          castore
          finch
          jason
          joken
          plug
          spark
          splode
        ];
      };

      ash_authentication_phoenix = buildMix rec {
        name = "ash_authentication_phoenix";
        version = "2.0.0";

        src = fetchHex {
          pkg = "ash_authentication_phoenix";
          version = "${version}";
          sha256 = "6a7c24d57ef6f7a4456d5ba139c8221df6a7ed81f15707a23fc33ad369e43a36";
        };

        beamDeps = [
          ash
          ash_authentication
          ash_phoenix
          bcrypt_elixir
          jason
          phoenix
          phoenix_html
          phoenix_html_helpers
          phoenix_live_view
          phoenix_view
          slugify
        ];
      };

      ash_json_api = buildMix rec {
        name = "ash_json_api";
        version = "1.1.0";

        src = fetchHex {
          pkg = "ash_json_api";
          version = "${version}";
          sha256 = "0db08bc19ac52d3adb31df5a2090cfa0da2937b413b9f4cd7738b0a876200454";
        };

        beamDeps = [
          ash
          jason
          json_xema
          open_api_spex
          plug
        ];
      };

      ash_phoenix = buildMix rec {
        name = "ash_phoenix";
        version = "2.0.2";

        src = fetchHex {
          pkg = "ash_phoenix";
          version = "${version}";
          sha256 = "fc7ee7bf3bbc8abe36e4e940d754bd326aa360092d01f64095fbbb31fe3fe606";
        };

        beamDeps = [
          ash
          phoenix
          phoenix_html
          phoenix_live_view
        ];
      };

      ash_postgres = buildMix rec {
        name = "ash_postgres";
        version = "2.0.6";

        src = fetchHex {
          pkg = "ash_postgres";
          version = "${version}";
          sha256 = "9b096d4ba605bcf6909fa04f4dee3f982141b89822bb1a2e52a58065615ddf88";
        };

        beamDeps = [
          ash
          ash_sql
          ecto
          ecto_sql
          jason
          postgrex
        ];
      };

      ash_sql = buildMix rec {
        name = "ash_sql";
        version = "0.2.0";

        src = fetchHex {
          pkg = "ash_sql";
          version = "${version}";
          sha256 = "bc8997b6fdf52a0144c17969aef88bd2dc22958c8d1b1c18fbcfb4bec3b849f1";
        };

        beamDeps = [
          ash
          ecto
          ecto_sql
        ];
      };

      assent = buildMix rec {
        name = "assent";
        version = "0.2.10";

        src = fetchHex {
          pkg = "assent";
          version = "${version}";
          sha256 = "8483bf9621e994795a70a4ad8fda725abfb6a9675d63a9bfd4217c76d4a2d82a";
        };

        beamDeps = [
          certifi
          finch
          jason
          jose
          mint
          ssl_verify_fun
        ];
      };

      bandit = buildMix rec {
        name = "bandit";
        version = "1.5.2";

        src = fetchHex {
          pkg = "bandit";
          version = "${version}";
          sha256 = "35ddbdce7e8a2a3c6b5093f7299d70832a43ed2f4a1852885a61d334cab1b4ad";
        };

        beamDeps = [
          hpax
          plug
          telemetry
          thousand_island
          websock
        ];
      };

      bcrypt_elixir = buildMix rec {
        name = "bcrypt_elixir";
        version = "3.1.0";

        src = fetchHex {
          pkg = "bcrypt_elixir";
          version = "${version}";
          sha256 = "2ad2acb5a8bc049e8d5aa267802631912bb80d5f4110a178ae7999e69dca1bf7";
        };

        beamDeps = [
          comeonin
          elixir_make
        ];
      };

      castore = buildMix rec {
        name = "castore";
        version = "1.0.7";

        src = fetchHex {
          pkg = "castore";
          version = "${version}";
          sha256 = "da7785a4b0d2a021cd1292a60875a784b6caef71e76bf4917bdee1f390455cf5";
        };

        beamDeps = [ ];
      };

      certifi = buildRebar3 rec {
        name = "certifi";
        version = "2.12.0";

        src = fetchHex {
          pkg = "certifi";
          version = "${version}";
          sha256 = "ee68d85df22e554040cdb4be100f33873ac6051387baf6a8f6ce82272340ff1c";
        };

        beamDeps = [ ];
      };

      comeonin = buildMix rec {
        name = "comeonin";
        version = "5.4.0";

        src = fetchHex {
          pkg = "comeonin";
          version = "${version}";
          sha256 = "796393a9e50d01999d56b7b8420ab0481a7538d0caf80919da493b4a6e51faf1";
        };

        beamDeps = [ ];
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

        beamDeps = [ ];
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

        beamDeps = [ ];
      };

      deep_merge = buildMix rec {
        name = "deep_merge";
        version = "1.0.0";

        src = fetchHex {
          pkg = "deep_merge";
          version = "${version}";
          sha256 = "ce708e5f094b9cd4e8f2be4f00d2f4250c4095be93f8cd6d018c753894885430";
        };

        beamDeps = [ ];
      };

      ecto = buildMix rec {
        name = "ecto";
        version = "3.11.2";

        src = fetchHex {
          pkg = "ecto";
          version = "${version}";
          sha256 = "3c38bca2c6f8d8023f2145326cc8a80100c3ffe4dcbd9842ff867f7fc6156c65";
        };

        beamDeps = [
          decimal
          jason
          telemetry
        ];
      };

      ecto_sql = buildMix rec {
        name = "ecto_sql";
        version = "3.11.2";

        src = fetchHex {
          pkg = "ecto_sql";
          version = "${version}";
          sha256 = "73c07f995ac17dbf89d3cfaaf688fcefabcd18b7b004ac63b0dc4ef39499ed6b";
        };

        beamDeps = [
          db_connection
          ecto
          postgrex
          telemetry
        ];
      };

      elixir_make = buildMix rec {
        name = "elixir_make";
        version = "0.8.3";

        src = fetchHex {
          pkg = "elixir_make";
          version = "${version}";
          sha256 = "5c99a18571a756d4af7a4d89ca75c28ac899e6103af6f223982f09ce44942cc9";
        };

        beamDeps = [
          castore
          certifi
        ];
      };

      enough = buildRebar3 rec {
        name = "enough";
        version = "0.1.0";

        src = fetchHex {
          pkg = "enough";
          version = "${version}";
          sha256 = "0460c7abda5f5e0ea592b12bc6976b8a5c4b96e42f332059cd396525374bf9a1";
        };

        beamDeps = [ ];
      };

      esbuild = buildMix rec {
        name = "esbuild";
        version = "0.8.1";

        src = fetchHex {
          pkg = "esbuild";
          version = "${version}";
          sha256 = "25fc876a67c13cb0a776e7b5d7974851556baeda2085296c14ab48555ea7560f";
        };

        beamDeps = [
          castore
          jason
        ];
      };

      ets = buildMix rec {
        name = "ets";
        version = "0.9.0";

        src = fetchHex {
          pkg = "ets";
          version = "${version}";
          sha256 = "2861fdfb04bcaeff370f1a5904eec864f0a56dcfebe5921ea9aadf2a481c822b";
        };

        beamDeps = [ ];
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

        beamDeps = [ ];
      };

      file_system = buildMix rec {
        name = "file_system";
        version = "1.0.0";

        src = fetchHex {
          pkg = "file_system";
          version = "${version}";
          sha256 = "6752092d66aec5a10e662aefeed8ddb9531d79db0bc145bb8c40325ca1d8536d";
        };

        beamDeps = [ ];
      };

      finch = buildMix rec {
        name = "finch";
        version = "0.18.0";

        src = fetchHex {
          pkg = "finch";
          version = "${version}";
          sha256 = "69f5045b042e531e53edc2574f15e25e735b522c37e2ddb766e15b979e03aa65";
        };

        beamDeps = [
          castore
          mime
          mint
          nimble_options
          nimble_pool
          telemetry
        ];
      };

      floki = buildMix rec {
        name = "floki";
        version = "0.36.2";

        src = fetchHex {
          pkg = "floki";
          version = "${version}";
          sha256 = "a8766c0bc92f074e5cb36c4f9961982eda84c5d2b8e979ca67f5c268ec8ed580";
        };

        beamDeps = [ ];
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

        beamDeps = [
          certifi
          idna
          metrics
          mimerl
          parse_trans
          ssl_verify_fun
          unicode_util_compat
        ];
      };

      hpax = buildMix rec {
        name = "hpax";
        version = "0.1.2";

        src = fetchHex {
          pkg = "hpax";
          version = "${version}";
          sha256 = "2c87843d5a23f5f16748ebe77969880e29809580efdaccd615cd3bed628a8c13";
        };

        beamDeps = [ ];
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

        beamDeps = [ ];
      };

      json_xema = buildMix rec {
        name = "json_xema";
        version = "0.6.2";

        src = fetchHex {
          pkg = "json_xema";
          version = "${version}";
          sha256 = "50c84c537c95fcc76677f1f030af4aed188f538820fc488aeaa3f7dfe04d0edf";
        };

        beamDeps = [
          conv_case
          xema
        ];
      };

      libgraph = buildMix rec {
        name = "libgraph";
        version = "0.16.0";

        src = fetchHex {
          pkg = "libgraph";
          version = "${version}";
          sha256 = "41ca92240e8a4138c30a7e06466acc709b0cbb795c643e9e17174a178982d6bf";
        };

        beamDeps = [ ];
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

        beamDeps = [
          makeup
          nimble_parsec
        ];
      };

      metrics = buildRebar3 rec {
        name = "metrics";
        version = "1.0.1";

        src = fetchHex {
          pkg = "metrics";
          version = "${version}";
          sha256 = "69b09adddc4f74a40716ae54d140f93beb0fb8978d8636eaded0c31b6f099f16";
        };

        beamDeps = [ ];
      };

      mime = buildMix rec {
        name = "mime";
        version = "2.0.5";

        src = fetchHex {
          pkg = "mime";
          version = "${version}";
          sha256 = "da0d64a365c45bc9935cc5c8a7fc5e49a0e0f9932a761c55d6c52b142780a05c";
        };

        beamDeps = [ ];
      };

      mimerl = buildRebar3 rec {
        name = "mimerl";
        version = "1.3.0";

        src = fetchHex {
          pkg = "mimerl";
          version = "${version}";
          sha256 = "a1e15a50d1887217de95f0b9b0793e32853f7c258a5cd227650889b38839fe9d";
        };

        beamDeps = [ ];
      };

      mint = buildMix rec {
        name = "mint";
        version = "1.6.0";

        src = fetchHex {
          pkg = "mint";
          version = "${version}";
          sha256 = "3c5ae85d90a5aca0a49c0d8b67360bbe407f3b54f1030a111047ff988e8fefaa";
        };

        beamDeps = [
          castore
          hpax
        ];
      };

      nimble_options = buildMix rec {
        name = "nimble_options";
        version = "1.1.1";

        src = fetchHex {
          pkg = "nimble_options";
          version = "${version}";
          sha256 = "821b2470ca9442c4b6984882fe9bb0389371b8ddec4d45a9504f00a66f650b44";
        };

        beamDeps = [ ];
      };

      nimble_ownership = buildMix rec {
        name = "nimble_ownership";
        version = "0.3.1";

        src = fetchHex {
          pkg = "nimble_ownership";
          version = "${version}";
          sha256 = "4bf510adedff0449a1d6e200e43e57a814794c8b5b6439071274d248d272a549";
        };

        beamDeps = [ ];
      };

      nimble_parsec = buildMix rec {
        name = "nimble_parsec";
        version = "1.4.0";

        src = fetchHex {
          pkg = "nimble_parsec";
          version = "${version}";
          sha256 = "9c565862810fb383e9838c1dd2d7d2c437b3d13b267414ba6af33e50d2d1cf28";
        };

        beamDeps = [ ];
      };

      nimble_pool = buildMix rec {
        name = "nimble_pool";
        version = "1.1.0";

        src = fetchHex {
          pkg = "nimble_pool";
          version = "${version}";
          sha256 = "af2e4e6b34197db81f7aad230c1118eac993acc0dae6bc83bac0126d4ae0813a";
        };

        beamDeps = [ ];
      };

      open_api_spex = buildMix rec {
        name = "open_api_spex";
        version = "3.19.1";

        src = fetchHex {
          pkg = "open_api_spex";
          version = "${version}";
          sha256 = "392895827ce2984a3459c91a484e70708132d8c2c6c5363972b4b91d6bbac3dd";
        };

        beamDeps = [
          jason
          plug
        ];
      };

      parse_trans = buildRebar3 rec {
        name = "parse_trans";
        version = "3.4.1";

        src = fetchHex {
          pkg = "parse_trans";
          version = "${version}";
          sha256 = "620a406ce75dada827b82e453c19cf06776be266f5a67cff34e1ef2cbb60e49a";
        };

        beamDeps = [ ];
      };

      phoenix = buildMix rec {
        name = "phoenix";
        version = "1.7.12";

        src = fetchHex {
          pkg = "phoenix";
          version = "${version}";
          sha256 = "d646192fbade9f485b01bc9920c139bfdd19d0f8df3d73fd8eaf2dfbe0d2837c";
        };

        beamDeps = [
          castore
          jason
          phoenix_pubsub
          phoenix_template
          phoenix_view
          plug
          plug_crypto
          telemetry
          websock_adapter
        ];
      };

      phoenix_ecto = buildMix rec {
        name = "phoenix_ecto";
        version = "4.6.1";

        src = fetchHex {
          pkg = "phoenix_ecto";
          version = "${version}";
          sha256 = "0ae544ff99f3c482b0807c5cec2c8289e810ecacabc04959d82c3337f4703391";
        };

        beamDeps = [
          ecto
          phoenix_html
          plug
          postgrex
        ];
      };

      phoenix_html = buildMix rec {
        name = "phoenix_html";
        version = "4.1.1";

        src = fetchHex {
          pkg = "phoenix_html";
          version = "${version}";
          sha256 = "f2f2df5a72bc9a2f510b21497fd7d2b86d932ec0598f0210fed4114adc546c6f";
        };

        beamDeps = [ ];
      };

      phoenix_html_helpers = buildMix rec {
        name = "phoenix_html_helpers";
        version = "1.0.1";

        src = fetchHex {
          pkg = "phoenix_html_helpers";
          version = "${version}";
          sha256 = "cffd2385d1fa4f78b04432df69ab8da63dc5cf63e07b713a4dcf36a3740e3090";
        };

        beamDeps = [
          phoenix_html
          plug
        ];
      };

      phoenix_live_dashboard = buildMix rec {
        name = "phoenix_live_dashboard";
        version = "0.8.3";

        src = fetchHex {
          pkg = "phoenix_live_dashboard";
          version = "${version}";
          sha256 = "f9470a0a8bae4f56430a23d42f977b5a6205fdba6559d76f932b876bfaec652d";
        };

        beamDeps = [
          ecto
          mime
          phoenix_live_view
          telemetry_metrics
        ];
      };

      phoenix_live_reload = buildMix rec {
        name = "phoenix_live_reload";
        version = "1.5.3";

        src = fetchHex {
          pkg = "phoenix_live_reload";
          version = "${version}";
          sha256 = "b4ec9cd73cb01ff1bd1cac92e045d13e7030330b74164297d1aee3907b54803c";
        };

        beamDeps = [
          file_system
          phoenix
        ];
      };

      phoenix_live_view = buildMix rec {
        name = "phoenix_live_view";
        version = "0.20.14";

        src = fetchHex {
          pkg = "phoenix_live_view";
          version = "${version}";
          sha256 = "82f6d006c5264f979ed5eb75593d808bbe39020f20df2e78426f4f2d570e2402";
        };

        beamDeps = [
          floki
          jason
          phoenix
          phoenix_html
          phoenix_template
          phoenix_view
          plug
          telemetry
        ];
      };

      phoenix_pubsub = buildMix rec {
        name = "phoenix_pubsub";
        version = "2.1.3";

        src = fetchHex {
          pkg = "phoenix_pubsub";
          version = "${version}";
          sha256 = "bba06bc1dcfd8cb086759f0edc94a8ba2bc8896d5331a1e2c2902bf8e36ee502";
        };

        beamDeps = [ ];
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
        version = "2.0.3";

        src = fetchHex {
          pkg = "phoenix_view";
          version = "${version}";
          sha256 = "cd34049af41be2c627df99cd4eaa71fc52a328c0c3d8e7d4aa28f880c30e7f64";
        };

        beamDeps = [
          phoenix_html
          phoenix_template
        ];
      };

      plug = buildMix rec {
        name = "plug";
        version = "1.16.0";

        src = fetchHex {
          pkg = "plug";
          version = "${version}";
          sha256 = "cbf53aa1f5c4d758a7559c0bd6d59e286c2be0c6a1fac8cc3eee2f638243b93e";
        };

        beamDeps = [
          mime
          plug_crypto
          telemetry
        ];
      };

      plug_crypto = buildMix rec {
        name = "plug_crypto";
        version = "2.1.0";

        src = fetchHex {
          pkg = "plug_crypto";
          version = "${version}";
          sha256 = "131216a4b030b8f8ce0f26038bc4421ae60e4bb95c5cf5395e1421437824c4fa";
        };

        beamDeps = [ ];
      };

      postgrex = buildMix rec {
        name = "postgrex";
        version = "0.18.0";

        src = fetchHex {
          pkg = "postgrex";
          version = "${version}";
          sha256 = "a042989ba1bc1cca7383ebb9e461398e3f89f868c92ce6671feb7ef132a252d1";
        };

        beamDeps = [
          db_connection
          decimal
          jason
        ];
      };

      reactor = buildMix rec {
        name = "reactor";
        version = "0.8.4";

        src = fetchHex {
          pkg = "reactor";
          version = "${version}";
          sha256 = "49c1fd3c786603cec8140ce941c41c7ea72cc4411860ccdee9876c4ca2204f81";
        };

        beamDeps = [
          libgraph
          spark
          splode
          telemetry
        ];
      };

      redoc_ui_plug = buildMix rec {
        name = "redoc_ui_plug";
        version = "0.2.1";

        src = fetchHex {
          pkg = "redoc_ui_plug";
          version = "${version}";
          sha256 = "7be01db31f210887e9fc18f8fbccc7788de32c482b204623556e415ed1fe714b";
        };

        beamDeps = [
          jason
          plug
        ];
      };

      sentry = buildMix rec {
        name = "sentry";
        version = "10.6.0";

        src = fetchHex {
          pkg = "sentry";
          version = "${version}";
          sha256 = "31404d43d9235219c5a020236a8ee56de3bef3a87e2c6399795c564157b831af";
        };

        beamDeps = [
          hackney
          jason
          nimble_options
          nimble_ownership
          phoenix
          phoenix_live_view
          plug
          telemetry
        ];
      };

      slugify = buildMix rec {
        name = "slugify";
        version = "1.3.1";

        src = fetchHex {
          pkg = "slugify";
          version = "${version}";
          sha256 = "cb090bbeb056b312da3125e681d98933a360a70d327820e4b7f91645c4d8be76";
        };

        beamDeps = [ ];
      };

      sourceror = buildMix rec {
        name = "sourceror";
        version = "1.2.1";

        src = fetchHex {
          pkg = "sourceror";
          version = "${version}";
          sha256 = "e4d97087e67584a7585b5fe3d5a71bf8e7332f795dd1a44983d750003d5e750c";
        };

        beamDeps = [ ];
      };

      spark = buildMix rec {
        name = "spark";
        version = "2.1.22";

        src = fetchHex {
          pkg = "spark";
          version = "${version}";
          sha256 = "f764611d0b15ac132e72b2326539acc11fc4e63baa3e429f541bca292b5f7064";
        };

        beamDeps = [
          jason
          sourceror
        ];
      };

      splode = buildMix rec {
        name = "splode";
        version = "0.2.4";

        src = fetchHex {
          pkg = "splode";
          version = "${version}";
          sha256 = "ca3b95f0d8d4b482b5357954fec857abd0fa3ea509d623334c1328e7382044c2";
        };

        beamDeps = [ ];
      };

      ssl_verify_fun = buildRebar3 rec {
        name = "ssl_verify_fun";
        version = "1.1.7";

        src = fetchHex {
          pkg = "ssl_verify_fun";
          version = "${version}";
          sha256 = "fe4c190e8f37401d30167c8c405eda19469f34577987c76dde613e838bbc67f8";
        };

        beamDeps = [ ];
      };

      stream_data = buildMix rec {
        name = "stream_data";
        version = "1.1.0";

        src = fetchHex {
          pkg = "stream_data";
          version = "${version}";
          sha256 = "cccc411d5facf1bab86e7c671382d164f05f8992574c95349d3c8b317e14d953";
        };

        beamDeps = [ ];
      };

      swoosh = buildMix rec {
        name = "swoosh";
        version = "1.16.8";

        src = fetchHex {
          pkg = "swoosh";
          version = "${version}";
          sha256 = "33de50fa414c07ed55fcb28e60e72a44496e14f8753e46cbf80e7b15d1adaae2";
        };

        beamDeps = [
          bandit
          finch
          hackney
          jason
          mime
          plug
          telemetry
        ];
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

        beamDeps = [ ];
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

        beamDeps = [ ];
      };

      unicode_util_compat = buildRebar3 rec {
        name = "unicode_util_compat";
        version = "0.7.0";

        src = fetchHex {
          pkg = "unicode_util_compat";
          version = "${version}";
          sha256 = "25eee6d67df61960cf6a794239566599b09e17e668d3700247bc498638152521";
        };

        beamDeps = [ ];
      };

      websock = buildMix rec {
        name = "websock";
        version = "0.5.3";

        src = fetchHex {
          pkg = "websock";
          version = "${version}";
          sha256 = "6105453d7fac22c712ad66fab1d45abdf049868f253cf719b625151460b8b453";
        };

        beamDeps = [ ];
      };

      websock_adapter = buildMix rec {
        name = "websock_adapter";
        version = "0.5.6";

        src = fetchHex {
          pkg = "websock_adapter";
          version = "${version}";
          sha256 = "e04378d26b0af627817ae84c92083b7e97aca3121196679b73c73b99d0d133ea";
        };

        beamDeps = [
          bandit
          plug
          websock
        ];
      };

      xema = buildMix rec {
        name = "xema";
        version = "0.17.2";

        src = fetchHex {
          pkg = "xema";
          version = "${version}";
          sha256 = "965a44cd0846dde36a981889d7a3788c3f932893b688ec941b0ce71c363fa1cf";
        };

        beamDeps = [
          conv_case
          decimal
        ];
      };
    };
in
self
