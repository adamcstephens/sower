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

    elixirMake = _unusedArgs: old: {
      preConfigure = ''
        export ELIXIR_MAKE_CACHE_DIR="$TEMPDIR/elixir_make_cache"
      '';
    };

    lazyHtml = _unusedArgs: old: {
      preConfigure = ''
        export ELIXIR_MAKE_CACHE_DIR="$TEMPDIR/elixir_make_cache"
      '';

      postPatch = ''
        substituteInPlace mix.exs           --replace-fail "Fine.include_dir()" '"${packages.fine}/src/c_include"'           --replace-fail '@lexbor_git_sha "244b84956a6dc7eec293781d051354f351274c46"' '@lexbor_git_sha ""'
      '';

      preBuild = ''
        install -Dm644           -t _build/c/third_party/lexbor/$LEXBOR_GIT_SHA/build           ${pkgs.lexbor}/lib/liblexbor_static.a
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
          version = "699ff303d6866b0b61b73c11859fcab898a8badf";
          drv = buildRebar3 {
            inherit version;
            name = "argon2";

            src = pkgs.fetchFromGitHub {
              owner = "adamcstephens";
              repo = "erl_argon2";
              rev = "699ff303d6866b0b61b73c11859fcab898a8badf";
              hash = "sha256-1aY0VjkP6BwE9HhyaQT0CDj470D6AlaOBZQkbAaqs64=";
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

      crontab =
        let
          version = "1.2.0";
          drv = buildMix {
            inherit version;
            name = "crontab";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "crontab";
              sha256 = "ebd7ef4d831e1b20fa4700f0de0284a04cac4347e813337978e25b4cc5cc2207";
            };

            beamDeps = [
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
          version = "2.8.1";
          drv = buildMix {
            inherit version;
            name = "db_connection";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "db_connection";
              sha256 = "a61a3d489b239d76f326e03b98794fb8e45168396c925ef25feb405ed09da8fd";
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

      ecto =
        let
          version = "3.13.5";
          drv = buildMix {
            inherit version;
            name = "ecto";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "ecto";
              sha256 = "df9efebf70cf94142739ba357499661ef5dbb559ef902b68ea1f3c1fabce36de";
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

      erlexec =
        let
          version = "2.2.2";
          drv = buildRebar3 {
            inherit version;
            name = "erlexec";

            src = fetchHex {
              inherit version;
              pkg = "erlexec";
              sha256 = "5e8e3c3773113785361b3b55218d92f7e91509cc9d679bf67c5c3703b394c900";
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
          version = "0.11.1";
          drv = buildMix {
            inherit version;
            name = "ex_json_schema";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "ex_json_schema";
              sha256 = "32d651a575a6ce2fd613f140b0fef8dd0acc7cf8e8bcd29a3a1be5c945700dd5";
            };

            beamDeps = [
              decimal
            ];
          };
        in
        drv;

      expo =
        let
          version = "1.1.1";
          drv = buildMix {
            inherit version;
            name = "expo";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "expo";
              sha256 = "5fb308b9cb359ae200b7e23d37c76978673aa1b06e2b3075d814ce12c5811640";
            };
          };
        in
        drv;

      exsync =
        let
          version = "0.4.1";
          drv = buildMix {
            inherit version;
            name = "exsync";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "exsync";
              sha256 = "cefb22aa805ec97ffc5b75a4e1dc54bcaf781e8b32564bf74abbe5803d1b5178";
            };

            beamDeps = [
              file_system
            ];
          };
        in
        drv;

      file_system =
        let
          version = "1.1.1";
          drv = buildMix {
            inherit version;
            name = "file_system";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "file_system";
              sha256 = "7a15ff97dfe526aeefb090a7a9d3d03aa907e100e262a0f8f7746b78f8f87a5d";
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

      gen_stage =
        let
          version = "1.3.2";
          drv = buildMix {
            inherit version;
            name = "gen_stage";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "gen_stage";
              sha256 = "0ffae547fa777b3ed889a6b9e1e64566217413d018cabd825f786e843ffe63e7";
            };
          };
        in
        drv;

      gettext =
        let
          version = "1.0.2";
          drv = buildMix {
            inherit version;
            name = "gettext";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "gettext";
              sha256 = "eab805501886802071ad290714515c8c4a17196ea76e5afc9d06ca85fb1bfeb3";
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
          version = "1.11.12";
          drv = buildMix {
            inherit version;
            name = "jose";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "jose";
              sha256 = "31e92b653e9210b696765cdd885437457de1add2a9011d92f8cf63e4641bab7b";
            };
          };
        in
        drv;

      libcluster =
        let
          version = "3.3.3";
          drv = buildMix {
            inherit version;
            name = "libcluster";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "libcluster";
              sha256 = "7c0a2275a0bb83c07acd17dab3c3bfb4897b145106750eeccc62d302e3bdfee5";
            };

            beamDeps = [
              jason
            ];
          };
        in
        drv;

      libcluster_consul =
        let
          version = "1.3.0";
          drv = buildMix {
            inherit version;
            name = "libcluster_consul";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "libcluster_consul";
              sha256 = "fb63bc580f931a5af041c582a565df52bca3c8005c2ada13cce71647e674da25";
            };

            beamDeps = [
              libcluster
            ];
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
              hpax
            ];
          };
        in
        drv;

      mint_web_socket =
        let
          version = "1.0.5";
          drv = buildMix {
            inherit version;
            name = "mint_web_socket";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "mint_web_socket";
              sha256 = "04b35663448fc758f3356cce4d6ac067ca418bbafe6972a3805df984b5f12e61";
            };

            beamDeps = [
              mint
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
          version = "3.6.0";
          drv = buildMix {
            inherit version;
            name = "oidcc";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "oidcc";
              sha256 = "99b26b1db95d617150416b18a7a84bb09525007fdbbcf963a60edb6156c6a1ce";
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
          version = "3.22.1";
          drv = buildMix {
            inherit version;
            name = "open_api_spex";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "open_api_spex";
              sha256 = "fa51ecd04ececbad89a8ede55ebd9db7aa9e55cc7ddbb46455522e0f3c098290";
            };

            beamDeps = [
              decimal
              jason
              plug
            ];
          };
        in
        drv;

      optimus =
        let
          version = "0.5.1";
          drv = buildMix {
            inherit version;
            name = "optimus";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "optimus";
              sha256 = "95c669e25e05e7f2a47bc1ff25ac237a19505f56135e9bfe88bc63ddbe60c07a";
            };
          };
        in
        drv;

      permit =
        let
          version = "0.3.0";
          drv = buildMix {
            inherit version;
            name = "permit";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "permit";
              sha256 = "aac92428febf4e3856b90a267126a0c68183a86d7785ef70c9ea4bc07cc7764b";
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
          version = "1.8.1";
          drv = buildMix {
            inherit version;
            name = "phoenix";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix";
              sha256 = "84d77d2b2e77c3c7e7527099bd01ef5c8560cd149c036d6b3a40745f11cd2fb2";
            };

            beamDeps = [
              bandit
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
          version = "4.7.0";
          drv = buildMix {
            inherit version;
            name = "phoenix_ecto";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix_ecto";
              sha256 = "1d75011e4254cb4ddf823e81823a9629559a1be93b4321a6a5f11a5306fbf4cc";
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
          version = "4.3.0";
          drv = buildMix {
            inherit version;
            name = "phoenix_html";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix_html";
              sha256 = "3eaa290a78bab0f075f791a46a981bbe769d94bc776869f4f3063a14f30497ad";
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
          version = "1.1.17";
          drv = buildMix {
            inherit version;
            name = "phoenix_live_view";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix_live_view";
              sha256 = "fa82307dd9305657a8236d6b48e60ef2e8d9f742ee7ed832de4b8bcb7e0e5ed2";
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
          version = "2.2.0";
          drv = buildMix {
            inherit version;
            name = "phoenix_pubsub";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix_pubsub";
              sha256 = "adc313a5bf7136039f63cfd9668fde73bba0765e0614cba80c06ac9460ff3e96";
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

      quantum =
        let
          version = "3.5.3";
          drv = buildMix {
            inherit version;
            name = "quantum";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "quantum";
              sha256 = "500fd3fa77dcd723ed9f766d4a175b684919ff7b6b8cfd9d7d0564d58eba8734";
            };

            beamDeps = [
              crontab
              gen_stage
              telemetry
              telemetry_registry
            ];
          };
        in
        drv;

      req =
        let
          version = "0.5.16";
          drv = buildMix {
            inherit version;
            name = "req";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "req";
              sha256 = "974a7a27982b9b791df84e8f6687d21483795882a7840e8309abdbe08bb06f09";
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

      slipstream =
        let
          version = "1.2.0";
          drv = buildMix {
            inherit version;
            name = "slipstream";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "slipstream";
              sha256 = "f2fceddbb3c97331d348586e77c6425f4d150242dfaf392d22e8bd22f93d1f1e";
            };

            beamDeps = [
              jason
              mint_web_socket
              nimble_options
              telemetry
            ];
          };
        in
        drv;

      systemd =
        let
          version = "62723b2a99afca491cc5c8f15c7f72d108e84f4b";
          drv = buildRebar3 {
            inherit version;
            name = "systemd";

            src = pkgs.fetchFromGitHub {
              owner = "hauleth";
              repo = "erlang-systemd";
              rev = "62723b2a99afca491cc5c8f15c7f72d108e84f4b";
              hash = "sha256-OfUNTPhDGMQHYjoKTgKhxRa2eejwykx2D6V15J5jPO8=";
            };

            beamDeps = [
              enough
            ];
          };
        in
        drv;

      tailwind =
        let
          version = "0.4.1";
          drv = buildMix {
            inherit version;
            name = "tailwind";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "tailwind";
              sha256 = "6249d4f9819052911120dbdbe9e532e6bd64ea23476056adb7f730aa25c220d1";
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
          version = "1.3.0";
          drv = buildRebar3 {
            inherit version;
            name = "telemetry_poller";

            src = fetchHex {
              inherit version;
              pkg = "telemetry_poller";
              sha256 = "51f18bed7128544a50f75897db9974436ea9bfba560420b646af27a9a9b35211";
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
          version = "1.4.2";
          drv = buildMix {
            inherit version;
            name = "thousand_island";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "thousand_island";
              sha256 = "1c7637f16558fc1c35746d5ee0e83b18b8e59e18d28affd1f2fa1645f8bc7473";
            };

            beamDeps = [
              telemetry
            ];
          };
        in
        drv;

      typedstruct =
        let
          version = "0.5.4";
          drv = buildMix {
            inherit version;
            name = "typedstruct";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "typedstruct";
              sha256 = "ffaef36d5dbaebdbf4ed07f7fb2ebd1037b2c1f757db6fb8e7bcbbfabbe608d8";
            };
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
          version = "0.5.9";
          drv = buildMix {
            inherit version;
            name = "websock_adapter";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "websock_adapter";
              sha256 = "5534d5c9adad3c18a0f58a9371220d75a803bf0b9a3d87e6fe072faaeed76a08";
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
