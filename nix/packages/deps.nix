{
  pkgs,
  lib,
  beamPackages,
  overrides ? (x: y: { }),
  overrideFenixOverlay ? null,
}:

let
  buildMix = lib.makeOverridable beamPackages.buildMix;
  buildRebar3 = lib.makeOverridable beamPackages.buildRebar3;

  workarounds = {
    portCompiler = _unusedArgs: old: {
      buildPlugins = [ pkgs.beamPackages.pc ];
    };

    rustlerPrecompiled =
      {
        toolchain ? null,
        ...
      }:
      old:
      let
        extendedPkgs = pkgs.extend fenixOverlay;
        fenixOverlay =
          if overrideFenixOverlay == null then
            import "${
              fetchTarball {
                url = "https://github.com/nix-community/fenix/archive/056c9393c821a4df356df6ce7f14c722dc8717ec.tar.gz";
                sha256 = "sha256:1cdfh6nj81gjmn689snigidyq7w98gd8hkl5rvhly6xj7vyppmnd";
              }
            }/overlay.nix"
          else
            overrideFenixOverlay;
        nativeDir = "${old.src}/native/${with builtins; head (attrNames (readDir "${old.src}/native"))}";
        fenix =
          if toolchain == null then
            extendedPkgs.fenix.stable
          else
            extendedPkgs.fenix.fromToolchainName toolchain;
        native =
          (extendedPkgs.makeRustPlatform {
            inherit (fenix) cargo rustc;
          }).buildRustPackage
            {
              pname = "${old.packageName}-native";
              version = old.version;
              src = nativeDir;
              cargoLock = {
                lockFile = "${nativeDir}/Cargo.lock";
              };
              nativeBuildInputs = [
                extendedPkgs.cmake
              ];
              doCheck = false;
            };

      in
      {
        nativeBuildInputs = [ extendedPkgs.cargo ];

        env.RUSTLER_PRECOMPILED_FORCE_BUILD_ALL = "true";
        env.RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH = "unused-but-required";

        preConfigure = ''
          mkdir -p priv/native
          for lib in ${native}/lib/*
          do
            ln -s "$lib" "priv/native/$(basename "$lib")"
          done
        '';

        buildPhase = ''
          suggestion() {
            echo "***********************************************"
            echo "                 deps_nix                      "
            echo
            echo " Rust dependency build failed.                 "
            echo
            echo " If you saw network errors, you might need     "
            echo " to disable compilation on the appropriate     "
            echo " RustlerPrecompiled module in your             "
            echo " application config.                           "
            echo
            echo " We think you need this:                       "
            echo
            echo -n " "
            grep -Rl 'use RustlerPrecompiled' lib \
              | xargs grep 'defmodule' \
              | sed 's/defmodule \(.*\) do/config :${old.packageName}, \1, skip_compilation?: true/'
            echo "***********************************************"
            exit 1
          }
          trap suggestion ERR
          ${old.buildPhase}
        '';
      };
  };

  defaultOverrides = (
    final: prev:

    let
      apps = {
        crc32cer = [
          {
            name = "portCompiler";
          }
        ];
        explorer = [
          {
            name = "rustlerPrecompiled";
            toolchain = {
              name = "nightly-2024-11-01";
              sha256 = "sha256-wq7bZ1/IlmmLkSa3GUJgK17dTWcKyf5A+ndS9yRwB88=";
            };
          }
        ];
        snappyer = [
          {
            name = "portCompiler";
          }
        ];
      };

      applyOverrides =
        appName: drv:
        let
          allOverridesForApp = builtins.foldl' (
            acc: workaround: acc // (workarounds.${workaround.name} workaround) drv
          ) { } apps.${appName};

        in
        if builtins.hasAttr appName apps then drv.override allOverridesForApp else drv;

    in
    builtins.mapAttrs applyOverrides prev
  );

  self = packages // (defaultOverrides self packages) // (overrides self packages);

  packages =
    with beamPackages;
    with self;
    {

      argon2 =
        let
          version = "1.2.0";
          drv = buildRebar3 {
            inherit version;
            name = "argon2";

            src = fetchHex {
              inherit version;
              pkg = "argon2";
              sha256 = "76ae94bee3eee9a34079e92993c9fb3f49fbd9976680452cc84d0335244911a3";
            };
          };
        in
        drv;

      bandit =
        let
          version = "1.8.0";
          drv = buildMix {
            inherit version;
            name = "bandit";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "bandit";
              sha256 = "8458ff4eed20ff2a2ea69d4854883a077c33ea42b51f6811b044ceee0fa15422";
            };

            beamDeps = [
              hpax
              plug
              telemetry
              thousand_island
              websock
            ];
          };
        in
        drv;

      castore =
        let
          version = "1.0.15";
          drv = buildMix {
            inherit version;
            name = "castore";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "castore";
              sha256 = "96ce4c69d7d5d7a0761420ef743e2f4096253931a3ba69e5ff8ef1844fe446d3";
            };
          };
        in
        drv;

      cloak =
        let
          version = "1.1.4";
          drv = buildMix {
            inherit version;
            name = "cloak";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "cloak";
              sha256 = "92b20527b9aba3d939fab0dd32ce592ff86361547cfdc87d74edce6f980eb3d7";
            };

            beamDeps = [
              jason
            ];
          };
        in
        drv;

      cloak_ecto =
        let
          version = "1.3.0";
          drv = buildMix {
            inherit version;
            name = "cloak_ecto";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "cloak_ecto";
              sha256 = "314beb0c123b8a800418ca1d51065b27ba3b15f085977e65c0f7b2adab2de1cc";
            };

            beamDeps = [
              cloak
              ecto
            ];
          };
        in
        drv;

      cuid2_ex =
        let
          version = "0.2.0";
          drv = buildMix {
            inherit version;
            name = "cuid2_ex";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "cuid2_ex";
              sha256 = "49c3b81c1864f146e1cc3674ad3984ec16583c253e08d4d71d69b808e0054ea1";
            };
          };
        in
        drv;

      db_connection =
        let
          version = "2.8.0";
          drv = buildMix {
            inherit version;
            name = "db_connection";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "db_connection";
              sha256 = "008399dae5eee1bf5caa6e86d204dcb44242c82b1ed5e22c881f2c34da201b15";
            };

            beamDeps = [
              telemetry
            ];
          };
        in
        drv;

      decimal =
        let
          version = "2.3.0";
          drv = buildMix {
            inherit version;
            name = "decimal";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "decimal";
              sha256 = "a4d66355cb29cb47c3cf30e71329e58361cfcb37c34235ef3bf1d7bf3773aeac";
            };
          };
        in
        drv;

      deps_nix =
        let
          version = "2.4.0";
          drv = buildMix {
            inherit version;
            name = "deps_nix";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "deps_nix";
              sha256 = "0f953f79b716d8627fd5a301615f1364d753e6c22e1380cdbd6a32f9e972370d";
            };

            beamDeps = [
              mint
            ];
          };
        in
        drv;

      ecto =
        let
          version = "3.13.2";
          drv = buildMix {
            inherit version;
            name = "ecto";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "ecto";
              sha256 = "669d9291370513ff56e7b7e7081b7af3283d02e046cf3d403053c557894a0b3e";
            };

            beamDeps = [
              decimal
              jason
              telemetry
            ];
          };
        in
        drv;

      ecto_sql =
        let
          version = "3.13.2";
          drv = buildMix {
            inherit version;
            name = "ecto_sql";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "ecto_sql";
              sha256 = "539274ab0ecf1a0078a6a72ef3465629e4d6018a3028095dc90f60a19c371717";
            };

            beamDeps = [
              db_connection
              ecto
              postgrex
              telemetry
            ];
          };
        in
        drv;

      enough =
        let
          version = "0.1.0";
          drv = buildRebar3 {
            inherit version;
            name = "enough";

            src = fetchHex {
              inherit version;
              pkg = "enough";
              sha256 = "0460c7abda5f5e0ea592b12bc6976b8a5c4b96e42f332059cd396525374bf9a1";
            };
          };
        in
        drv;

      esbuild =
        let
          version = "0.10.0";
          drv = buildMix {
            inherit version;
            name = "esbuild";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "esbuild";
              sha256 = "468489cda427b974a7cc9f03ace55368a83e1a7be12fba7e30969af78e5f8c70";
            };

            beamDeps = [
              jason
            ];
          };
        in
        drv;

      ex_json_schema =
        let
          version = "0.10.2";
          drv = buildMix {
            inherit version;
            name = "ex_json_schema";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "ex_json_schema";
              sha256 = "37f43be60f8407659d4d0155a7e45e7f406dab1f827051d3d35858a709baf6a6";
            };

            beamDeps = [
              decimal
            ];
          };
        in
        drv;

      expo =
        let
          version = "1.1.0";
          drv = buildMix {
            inherit version;
            name = "expo";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "expo";
              sha256 = "fbadf93f4700fb44c331362177bdca9eeb8097e8b0ef525c9cc501cb9917c960";
            };
          };
        in
        drv;

      finch =
        let
          version = "0.20.0";
          drv = buildMix {
            inherit version;
            name = "finch";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "finch";
              sha256 = "2658131a74d051aabfcba936093c903b8e89da9a1b63e430bee62045fa9b2ee2";
            };

            beamDeps = [
              mime
              mint
              nimble_options
              nimble_pool
              telemetry
            ];
          };
        in
        drv;

      gettext =
        let
          version = "0.26.2";
          drv = buildMix {
            inherit version;
            name = "gettext";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "gettext";
              sha256 = "aa978504bcf76511efdc22d580ba08e2279caab1066b76bb9aa81c4a1e0a32a5";
            };

            beamDeps = [
              expo
            ];
          };
        in
        drv;

      hpax =
        let
          version = "1.0.3";
          drv = buildMix {
            inherit version;
            name = "hpax";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "hpax";
              sha256 = "8eab6e1cfa8d5918c2ce4ba43588e894af35dbd8e91e6e55c817bca5847df34a";
            };
          };
        in
        drv;

      jason =
        let
          version = "1.4.4";
          drv = buildMix {
            inherit version;
            name = "jason";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "jason";
              sha256 = "c5eb0cab91f094599f94d55bc63409236a8ec69a21a67814529e8d5f6cc90b3b";
            };

            beamDeps = [
              decimal
            ];
          };
        in
        drv;

      joken =
        let
          version = "2.6.2";
          drv = buildMix {
            inherit version;
            name = "joken";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "joken";
              sha256 = "5134b5b0a6e37494e46dbf9e4dad53808e5e787904b7c73972651b51cce3d72b";
            };

            beamDeps = [
              jose
            ];
          };
        in
        drv;

      jose =
        let
          version = "1.11.10";
          drv = buildMix {
            inherit version;
            name = "jose";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "jose";
              sha256 = "0d6cd36ff8ba174db29148fc112b5842186b68a90ce9fc2b3ec3afe76593e614";
            };
          };
        in
        drv;

      mime =
        let
          version = "2.0.7";
          drv = buildMix {
            inherit version;
            name = "mime";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "mime";
              sha256 = "6171188e399ee16023ffc5b76ce445eb6d9672e2e241d2df6050f3c771e80ccd";
            };
          };
        in
        drv;

      mint =
        let
          version = "1.7.1";
          drv = buildMix {
            inherit version;
            name = "mint";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "mint";
              sha256 = "fceba0a4d0f24301ddee3024ae116df1c3f4bb7a563a731f45fdfeb9d39a231b";
            };

            beamDeps = [
              castore
              hpax
            ];
          };
        in
        drv;

      nimble_options =
        let
          version = "1.1.1";
          drv = buildMix {
            inherit version;
            name = "nimble_options";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "nimble_options";
              sha256 = "821b2470ca9442c4b6984882fe9bb0389371b8ddec4d45a9504f00a66f650b44";
            };
          };
        in
        drv;

      nimble_pool =
        let
          version = "1.1.0";
          drv = buildMix {
            inherit version;
            name = "nimble_pool";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "nimble_pool";
              sha256 = "af2e4e6b34197db81f7aad230c1118eac993acc0dae6bc83bac0126d4ae0813a";
            };
          };
        in
        drv;

      oidcc =
        let
          version = "3.5.2";
          drv = buildMix {
            inherit version;
            name = "oidcc";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "oidcc";
              sha256 = "474e7eddbf90ec4c8c50aeefe9a1ffb46ced72e6a11c2bb0c6eece9794821c2a";
            };

            beamDeps = [
              jose
              telemetry
              telemetry_registry
            ];
          };
        in
        drv;

      open_api_spex =
        let
          version = "3.22.0";
          drv = buildMix {
            inherit version;
            name = "open_api_spex";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "open_api_spex";
              sha256 = "dd751ddbdd709bb4a5313e9a24530da6e66594773c7242a0c2592cbd9f589063";
            };

            beamDeps = [
              decimal
              jason
              plug
            ];
          };
        in
        drv;

      permit =
        let
          version = "0.2.1";
          drv = buildMix {
            inherit version;
            name = "permit";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "permit";
              sha256 = "c38448dbc360c2d5717453fbc04c4ba4562efc63caad241f56bda22711a721a0";
            };
          };
        in
        drv;

      permit_ecto =
        let
          version = "0.2.4";
          drv = buildMix {
            inherit version;
            name = "permit_ecto";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "permit_ecto";
              sha256 = "4cc4a600d7331483674f5837a3f203d7a9b1cc1faf805a49f9ff5fd9ccc21ee9";
            };

            beamDeps = [
              ecto
              ecto_sql
              permit
            ];
          };
        in
        drv;

      phoenix =
        let
          version = "1.7.21";
          drv = buildMix {
            inherit version;
            name = "phoenix";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix";
              sha256 = "336dce4f86cba56fed312a7d280bf2282c720abb6074bdb1b61ec8095bdd0bc9";
            };

            beamDeps = [
              castore
              jason
              phoenix_pubsub
              phoenix_template
              plug
              plug_crypto
              telemetry
              websock_adapter
            ];
          };
        in
        drv;

      phoenix_ecto =
        let
          version = "4.6.5";
          drv = buildMix {
            inherit version;
            name = "phoenix_ecto";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix_ecto";
              sha256 = "26ec3208eef407f31b748cadd044045c6fd485fbff168e35963d2f9dfff28d4b";
            };

            beamDeps = [
              ecto
              phoenix_html
              plug
              postgrex
            ];
          };
        in
        drv;

      phoenix_html =
        let
          version = "4.2.1";
          drv = buildMix {
            inherit version;
            name = "phoenix_html";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix_html";
              sha256 = "cff108100ae2715dd959ae8f2a8cef8e20b593f8dfd031c9cba92702cf23e053";
            };
          };
        in
        drv;

      phoenix_live_dashboard =
        let
          version = "0.8.7";
          drv = buildMix {
            inherit version;
            name = "phoenix_live_dashboard";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix_live_dashboard";
              sha256 = "3a8625cab39ec261d48a13b7468dc619c0ede099601b084e343968309bd4d7d7";
            };

            beamDeps = [
              ecto
              mime
              phoenix_live_view
              telemetry_metrics
            ];
          };
        in
        drv;

      phoenix_live_view =
        let
          version = "1.0.18";
          drv = buildMix {
            inherit version;
            name = "phoenix_live_view";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix_live_view";
              sha256 = "724934fd0a68ecc57281cee863674454b06163fed7f5b8005b5e201ba4b23316";
            };

            beamDeps = [
              jason
              phoenix
              phoenix_html
              phoenix_template
              plug
              telemetry
            ];
          };
        in
        drv;

      phoenix_pubsub =
        let
          version = "2.1.3";
          drv = buildMix {
            inherit version;
            name = "phoenix_pubsub";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix_pubsub";
              sha256 = "bba06bc1dcfd8cb086759f0edc94a8ba2bc8896d5331a1e2c2902bf8e36ee502";
            };
          };
        in
        drv;

      phoenix_template =
        let
          version = "1.0.4";
          drv = buildMix {
            inherit version;
            name = "phoenix_template";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix_template";
              sha256 = "2c0c81f0e5c6753faf5cca2f229c9709919aba34fab866d3bc05060c9c444206";
            };

            beamDeps = [
              phoenix_html
            ];
          };
        in
        drv;

      plug =
        let
          version = "1.18.1";
          drv = buildMix {
            inherit version;
            name = "plug";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "plug";
              sha256 = "57a57db70df2b422b564437d2d33cf8d33cd16339c1edb190cd11b1a3a546cc2";
            };

            beamDeps = [
              mime
              plug_crypto
              telemetry
            ];
          };
        in
        drv;

      plug_crypto =
        let
          version = "2.1.1";
          drv = buildMix {
            inherit version;
            name = "plug_crypto";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "plug_crypto";
              sha256 = "6470bce6ffe41c8bd497612ffde1a7e4af67f36a15eea5f921af71cf3e11247c";
            };
          };
        in
        drv;

      postgrex =
        let
          version = "0.21.1";
          drv = buildMix {
            inherit version;
            name = "postgrex";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "postgrex";
              sha256 = "27d8d21c103c3cc68851b533ff99eef353e6a0ff98dc444ea751de43eb48bdac";
            };

            beamDeps = [
              db_connection
              decimal
              jason
            ];
          };
        in
        drv;

      req =
        let
          version = "0.5.15";
          drv = buildMix {
            inherit version;
            name = "req";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "req";
              sha256 = "a6513a35fad65467893ced9785457e91693352c70b58bbc045b47e5eb2ef0c53";
            };

            beamDeps = [
              finch
              jason
              mime
              plug
            ];
          };
        in
        drv;

      shortuuid =
        let
          version = "4.1.0";
          drv = buildMix {
            inherit version;
            name = "shortuuid";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "shortuuid";
              sha256 = "7336719118b3cca1ac73e95810199b0b9b7d00f9d71bd2c2d27fed4c4f74388e";
            };
          };
        in
        drv;

      systemd =
        let
          version = "0.6.2";
          drv = buildRebar3 {
            inherit version;
            name = "systemd";

            src = fetchHex {
              inherit version;
              pkg = "systemd";
              sha256 = "5062b911800c1ab05157c7bf9a9fbe23dd24c58891c87fd12d2e3ed8fc1708b8";
            };

            beamDeps = [
              enough
            ];
          };
        in
        drv;

      tailwind =
        let
          version = "0.3.1";
          drv = buildMix {
            inherit version;
            name = "tailwind";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "tailwind";
              sha256 = "98a45febdf4a87bc26682e1171acdedd6317d0919953c353fcd1b4f9f4b676a2";
            };
          };
        in
        drv;

      telemetry =
        let
          version = "1.3.0";
          drv = buildRebar3 {
            inherit version;
            name = "telemetry";

            src = fetchHex {
              inherit version;
              pkg = "telemetry";
              sha256 = "7015fc8919dbe63764f4b4b87a95b7c0996bd539e0d499be6ec9d7f3875b79e6";
            };
          };
        in
        drv;

      telemetry_metrics =
        let
          version = "1.1.0";
          drv = buildMix {
            inherit version;
            name = "telemetry_metrics";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "telemetry_metrics";
              sha256 = "e7b79e8ddfde70adb6db8a6623d1778ec66401f366e9a8f5dd0955c56bc8ce67";
            };

            beamDeps = [
              telemetry
            ];
          };
        in
        drv;

      telemetry_poller =
        let
          version = "1.1.0";
          drv = buildRebar3 {
            inherit version;
            name = "telemetry_poller";

            src = fetchHex {
              inherit version;
              pkg = "telemetry_poller";
              sha256 = "9eb9d9cbfd81cbd7cdd24682f8711b6e2b691289a0de6826e58452f28c103c8f";
            };

            beamDeps = [
              telemetry
            ];
          };
        in
        drv;

      telemetry_registry =
        let
          version = "0.3.2";
          drv = buildMix {
            inherit version;
            name = "telemetry_registry";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "telemetry_registry";
              sha256 = "e7ed191eb1d115a3034af8e1e35e4e63d5348851d556646d46ca3d1b4e16bab9";
            };

            beamDeps = [
              telemetry
            ];
          };
        in
        drv;

      thousand_island =
        let
          version = "1.3.14";
          drv = buildMix {
            inherit version;
            name = "thousand_island";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "thousand_island";
              sha256 = "d0d24a929d31cdd1d7903a4fe7f2409afeedff092d277be604966cd6aa4307ef";
            };

            beamDeps = [
              telemetry
            ];
          };
        in
        drv;

      ueberauth =
        let
          version = "0.10.8";
          drv = buildMix {
            inherit version;
            name = "ueberauth";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "ueberauth";
              sha256 = "f2d3172e52821375bccb8460e5fa5cb91cfd60b19b636b6e57e9759b6f8c10c1";
            };

            beamDeps = [
              plug
            ];
          };
        in
        drv;

      ueberauth_oidcc =
        let
          version = "0.4.2";
          drv = buildMix {
            inherit version;
            name = "ueberauth_oidcc";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "ueberauth_oidcc";
              sha256 = "b9ea3c981464a5052e4f4fbf0a3c716e124da056aca30b9754654c5c6f90f8c2";
            };

            beamDeps = [
              oidcc
              plug
              ueberauth
            ];
          };
        in
        drv;

      uuidv7 =
        let
          version = "1.0.0";
          drv = buildMix {
            inherit version;
            name = "uuidv7";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "uuidv7";
              sha256 = "0ecd337108456f7d8b1a9a54ef435443d3f8c10a5b685bd866ef9e396b444cbc";
            };

            beamDeps = [
              ecto
            ];
          };
        in
        drv;

      websock =
        let
          version = "0.5.3";
          drv = buildMix {
            inherit version;
            name = "websock";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "websock";
              sha256 = "6105453d7fac22c712ad66fab1d45abdf049868f253cf719b625151460b8b453";
            };
          };
        in
        drv;

      websock_adapter =
        let
          version = "0.5.8";
          drv = buildMix {
            inherit version;
            name = "websock_adapter";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "websock_adapter";
              sha256 = "315b9a1865552212b5f35140ad194e67ce31af45bcee443d4ecb96b5fd3f3782";
            };

            beamDeps = [
              bandit
              plug
              websock
            ];
          };
        in
        drv;

    };
in
self
