{
  lib,
  beamPackages,
  cmake,
  extend,
  lexbor,
  fetchFromGitHub,
  oniguruma,
  overrides ? (x: y: { }),
  overrideFenixOverlay ? null,
  rustlerPrecompiledOverrides ? { },
  pkg-config,
  vips,
  writeText,
}:

let
  buildMix = lib.makeOverridable beamPackages.buildMix;
  buildRebar3 = lib.makeOverridable beamPackages.buildRebar3;

  workarounds = {
    portCompiler = _unusedArgs: old: {
      buildPlugins = [ beamPackages.pc ];
    };

    rustlerPrecompiled =
      {
        toolchain ? null,
        buildInputs ? [ ],
        nativeBuildInputs ? [ ],
        env ? { },
        ...
      }:
      old:
      let
        extendedPkgs = extend fenixOverlay;
        fenixOverlay =
          if overrideFenixOverlay == null then
            import "${
              fetchTarball {
                url = "https://github.com/nix-community/fenix/archive/6399553b7a300c77e7f07342904eb696a5b6bf9d.tar.gz";
                sha256 = "sha256-C6tT7K1Lx6VsYw1BY5S3OavtapUvEnDQtmQB5DSgbCc=";
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
          (
            (extendedPkgs.makeRustPlatform {
              inherit (fenix) cargo rustc;
            }).buildRustPackage
            {
              inherit env buildInputs;
              pname = "${old.beamModuleName}-native";
              version = old.version;
              src = nativeDir;
              cargoLock = {
                lockFile = "${nativeDir}/Cargo.lock";
              };
              nativeBuildInputs = [ extendedPkgs.cmake ] ++ nativeBuildInputs;
              doCheck = false;
            }
          ).overrideAttrs
            rustlerPrecompiledOverrides.${old.beamModuleName} or { };

      in
      {
        nativeBuildInputs = [ extendedPkgs.cargo ];

        env.RUSTLER_PRECOMPILED_FORCE_BUILD_ALL = "true";
        env.RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH = "unused-but-required";

        preConfigure = ''
          mkdir -p priv/native
          for lib in ${native}/lib/*
          do
            dest="$(basename "$lib")"
            if [[ "''${dest##*.}" = "dylib" ]]
            then
              dest="''${dest%.dylib}.so"
            fi
            ln -s "$lib" "priv/native/$dest"
          done
        '';

        preBuild = ''
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
              | sed 's/defmodule \(.*\) do/config :${old.beamModuleName}, \1, skip_compilation?: true/'
            echo "***********************************************"
            exit 1
          }
          trap suggestion ERR
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
        substituteInPlace mix.exs \
          --replace-fail "Fine.include_dir()" '"${packages.fine}/src/c_include"' \
          --replace-fail '@lexbor_git_sha "244b84956a6dc7eec293781d051354f351274c46"' '@lexbor_git_sha ""'
      '';

      preBuild = ''
        install -Dm644           -t _build/c/third_party/lexbor/$LEXBOR_GIT_SHA/build           ${lexbor}/lib/liblexbor_static.a
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
              name = "nightly-2025-06-23";
              sha256 = "sha256-UAoZcxg3iWtS+2n8TFNfANFt/GmkuOMDf7QAE0fRxeA=";
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

      argon2id_elixir =
        let
          version = "1.1.3";
          drv = buildMix {
            inherit version;
            name = "argon2id_elixir";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "argon2id_elixir";
              sha256 = "87ba6dec1580c0d4209741724f2821e330a8514ccfb9ed67564113f0382267de";
            };

            beamDeps = [
              rustler
            ];
          };
        in
        drv;

      bandit =
        let
          version = "1.11.1";
          drv = buildMix {
            inherit version;
            name = "bandit";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "bandit";
              sha256 = "d4401016df9abbc6dcd325c0b78b2b193e7c7c96bb68f31e576112be025d84a5";
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

      boruta =
        let
          version = "2.3.6";
          drv = buildMix {
            inherit version;
            name = "boruta";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "boruta";
              sha256 = "24ec7feb928fb7651d87a2b8e4fc1207daa19074d6f67d915d3254bb96d47980";
            };

            beamDeps = [
              ecto_sql
              ex_json_schema
              finch
              jason
              joken
              jose
              nebulex
              nebulex_distributed
              phoenix
              plug
              postgrex
              puid
              secure_random
              shards
            ];
          };
        in
        drv;

      cc_precompiler =
        let
          version = "0.1.11";
          drv = buildMix {
            inherit version;
            name = "cc_precompiler";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "cc_precompiler";
              sha256 = "3427232caf0835f94680e5bcf082408a70b48ad68a5f5c0b02a3bea9f3a075b9";
            };

            beamDeps = [
              elixir_make
            ];
          };
        in
        drv.override (workarounds.elixirMake { } drv);

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

      crypto_rand =
        let
          version = "1.0.4";
          drv = buildMix {
            inherit version;
            name = "crypto_rand";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "crypto_rand";
              sha256 = "ad1862fd3e1c938f60982902632474868ea96901d75dd53f0ec32dd55e123549";
            };
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
          version = "2.10.1";
          drv = buildMix {
            inherit version;
            name = "db_connection";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "db_connection";
              sha256 = "18ed94c6e627b4bf452dbd4df61b69a35a1e768525140bc1917b7a685026a6a3";
            };

            beamDeps = [
              telemetry
            ];
          };
        in
        drv;

      decimal =
        let
          version = "3.1.0";
          drv = buildMix {
            inherit version;
            name = "decimal";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "decimal";
              sha256 = "e8b3efb3bb3a13cb5e4268ffe128569067b1972e9dee013537c71a5b073168f9";
            };
          };
        in
        drv;

      ecto =
        let
          version = "3.14.0";
          drv = buildMix {
            inherit version;
            name = "ecto";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "ecto";
              sha256 = "130d69ffb4285f9ce4792b65dfbb994fd13ea4cbc3cbea2524b199aa3de84af3";
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
          version = "3.14.0";
          drv = buildMix {
            inherit version;
            name = "ecto_sql";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "ecto_sql";
              sha256 = "f4d8d36faf294c9417b5a37ec7ac8217ee2abdef5fcf197ba690f361548d3949";
            };

            beamDeps = [
              db_connection
              decimal
              ecto
              postgrex
              telemetry
            ];
          };
        in
        drv;

      elixir_make =
        let
          version = "0.9.0";
          drv = buildMix {
            inherit version;
            name = "elixir_make";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "elixir_make";
              sha256 = "db23d4fd8b757462ad02f8aa73431a426fe6671c80b200d9710caf3d1dd0ffdb";
            };
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

      ex_ast =
        let
          version = "0.12.0";
          drv = buildMix {
            inherit version;
            name = "ex_ast";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "ex_ast";
              sha256 = "66b4797f157d32f0a63c6da227515f78816c0ac8f621f6d7a2b22108e7b4dd85";
            };

            beamDeps = [
              jason
              sourceror
            ];
          };
        in
        drv;

      ex_aws =
        let
          version = "2.7.0";
          drv = buildMix {
            inherit version;
            name = "ex_aws";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "ex_aws";
              sha256 = "bfe9d744d4fd4c1f40314ee7fab504d5547d1f01cd377fff1568cbe630b06d65";
            };

            beamDeps = [
              jason
              mime
              req
              sweet_xml
              telemetry
            ];
          };
        in
        drv;

      ex_aws_s3 =
        let
          version = "2.5.9";
          drv = buildMix {
            inherit version;
            name = "ex_aws_s3";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "ex_aws_s3";
              sha256 = "a480d2bb2da64610014021629800e1e9457ca5e4a62f6775bffd963360c2bf90";
            };

            beamDeps = [
              ex_aws
              sweet_xml
            ];
          };
        in
        drv;

      ex_hash_ring =
        let
          version = "7.0.0";
          drv = buildMix {
            inherit version;
            name = "ex_hash_ring";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "ex_hash_ring";
              sha256 = "9f61f33f043a69e9df9febe6df05ddb0ec78227a43aad8407503e2cd81715c5b";
            };
          };
        in
        drv;

      ex_json_schema =
        let
          version = "0.11.4";
          drv = buildMix {
            inherit version;
            name = "ex_json_schema";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "ex_json_schema";
              sha256 = "0bbe87044ef0154be2a91ab6927d69c5fcccdb21908a135653fc10dcbbb79c3b";
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

      faker =
        let
          version = "0.18.0";
          drv = buildMix {
            inherit version;
            name = "faker";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "faker";
              sha256 = "bfbdd83958d78e2788e99ec9317c4816e651ad05e24cfd1196ce5db5b3e81797";
            };
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
          version = "0.22.0";
          drv = buildMix {
            inherit version;
            name = "finch";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "finch";
              sha256 = "b94e83c47780fc6813f746a1f1a34ee65cda42da4c5ea26a68f0acc4498e23dc";
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

      fine =
        let
          version = "0.1.6";
          drv = buildMix {
            inherit version;
            name = "fine";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "fine";
              sha256 = "5638eb4495488e885ebec167fa57973e5c35e1a50c344eb7666c90ec1c4e3b12";
            };
          };
        in
        drv;

      floki =
        let
          version = "0.38.3";
          drv = buildMix {
            inherit version;
            name = "floki";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "floki";
              sha256 = "025aa1f5f24a70cb31bfbc7011419228596f3b062d7feda617238ba4926f83cb";
            };
          };
        in
        drv;

      flop =
        let
          version = "0.26.3";
          drv = buildMix {
            inherit version;
            name = "flop";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "flop";
              sha256 = "cd77588229778ac55560c90dfbe15ab6486773f067d6e52db9fa703b8c9a9d2d";
            };

            beamDeps = [
              ecto
              nimble_options
            ];
          };
        in
        drv;

      flop_phoenix =
        let
          version = "0.26.0";
          drv = buildMix {
            inherit version;
            name = "flop_phoenix";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "flop_phoenix";
              sha256 = "ec6312843aa5b468beb5daf7a6d40adf37b24f387953c869f677eeffc0fdfde9";
            };

            beamDeps = [
              flop
              phoenix
              phoenix_html
              phoenix_live_view
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

      glob_ex =
        let
          version = "0.1.11";
          drv = buildMix {
            inherit version;
            name = "glob_ex";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "glob_ex";
              sha256 = "342729363056e3145e61766b416769984c329e4378f1d558b63e341020525de4";
            };
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

      igniter =
        let
          version = "0.8.0";
          drv = buildMix {
            inherit version;
            name = "igniter";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "igniter";
              sha256 = "fcd99096fde4797f7b48bebddcfc58785569acd696346a3eb385bf813f47a7cc";
            };

            beamDeps = [
              ex_ast
              glob_ex
              jason
              owl
              req
              rewrite
              sourceror
              spitfire
            ];
          };
        in
        drv;

      jason =
        let
          version = "1.4.5";
          drv = buildMix {
            inherit version;
            name = "jason";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "jason";
              sha256 = "b0c823996102bcd0239b3c2444eb00409b72f6a140c1950bc8b457d836b30684";
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

      lazy_html =
        let
          version = "0.1.11";
          drv = buildMix {
            inherit version;
            name = "lazy_html";
            appConfigPath = ../../config;

            nativeBuildInputs = [
              lexbor
            ];

            src = fetchHex {
              inherit version;
              pkg = "lazy_html";
              sha256 = "3b1be592929c31eca1a21673d25696e5c14cddfe922d9d1a3e3b48be4163883b";
            };

            beamDeps = [
              cc_precompiler
              elixir_make
              fine
            ];
          };
        in
        drv.override (workarounds.lazyHtml { } drv);

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
          version = "1.8.0";
          drv = buildMix {
            inherit version;
            name = "mint";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "mint";
              sha256 = "f3c572c11355eccf00f22275e9b42463bc17bd28db13be1e28f8e0bb4adbc849";
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

      mix_test_watch =
        let
          version = "1.4.0";
          drv = buildMix {
            inherit version;
            name = "mix_test_watch";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "mix_test_watch";
              sha256 = "2b4693e17c8ead2ef56d4f48a0329891e8c2d0d73752c0f09272a2b17dc38d1b";
            };

            beamDeps = [
              file_system
            ];
          };
        in
        drv;

      nebulex =
        let
          version = "3.0.4";
          drv = buildMix {
            inherit version;
            name = "nebulex";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "nebulex";
              sha256 = "446afc6d3f701ba991f1fb0eee36c600f888530e52f30f80b308480ad65faab6";
            };

            beamDeps = [
              nimble_options
              telemetry
            ];
          };
        in
        drv;

      nebulex_distributed =
        let
          version = "3.2.2";
          drv = buildMix {
            inherit version;
            name = "nebulex_distributed";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "nebulex_distributed";
              sha256 = "e8f200e31d1124ddb5407687c4330a265db4d92183a219d3f7a4ba72a30174c7";
            };

            beamDeps = [
              ex_hash_ring
              nebulex
              nebulex_local
              nebulex_streams
              partitioned_buffer
              telemetry
            ];
          };
        in
        drv;

      nebulex_local =
        let
          version = "3.0.0";
          drv = buildMix {
            inherit version;
            name = "nebulex_local";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "nebulex_local";
              sha256 = "7a087d9f071369ba272cd688c2bc4b758926ab3a2e239bce1b529653a14bdad1";
            };

            beamDeps = [
              nebulex
              nimble_options
              shards
              telemetry
            ];
          };
        in
        drv;

      nebulex_streams =
        let
          version = "0.2.0";
          drv = buildMix {
            inherit version;
            name = "nebulex_streams";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "nebulex_streams";
              sha256 = "4cd38507756d16fa314cadf4452ea6c501fa49a77bf9bf2c46719b84c83d8d20";
            };

            beamDeps = [
              nebulex
              nimble_options
              phoenix_pubsub
              telemetry
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

      oban =
        let
          version = "2.22.1";
          drv = buildMix {
            inherit version;
            name = "oban";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "oban";
              sha256 = "af2508c156c5b0ec30b21b0883babf7e2716af35ed5d264095896103fe3cea37";
            };

            beamDeps = [
              ecto_sql
              igniter
              jason
              postgrex
              telemetry
            ];
          };
        in
        drv;

      oidcc =
        let
          version = "3.7.2";
          drv = buildMix {
            inherit version;
            name = "oidcc";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "oidcc";
              sha256 = "e3f1ed91509fdeb31ec8b9de4ecda0e80cb68b463a9f5b7a9ee1ee40e521e445";
            };

            beamDeps = [
              igniter
              jose
              telemetry
              telemetry_registry
            ];
          };
        in
        drv;

      open_api_spex =
        let
          version = "3.22.3";
          drv = buildMix {
            inherit version;
            name = "open_api_spex";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "open_api_spex";
              sha256 = "5f74f1878fdc38f8e961b0b943ac7af88dcf3a82a0c0ef6680ddfd3d161aecbd";
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
          version = "0.6.1";
          drv = buildMix {
            inherit version;
            name = "optimus";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "optimus";
              sha256 = "c0db4107a51f5af94de8b05e4208333ebb8016a3bfdbcd74df6e5c99829db17f";
            };
          };
        in
        drv;

      owl =
        let
          version = "0.13.0";
          drv = buildMix {
            inherit version;
            name = "owl";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "owl";
              sha256 = "59bf9d11ce37a4db98f57cb68fbfd61593bf419ec4ed302852b6683d3d2f7475";
            };
          };
        in
        drv;

      partitioned_buffer =
        let
          version = "0.4.2";
          drv = buildMix {
            inherit version;
            name = "partitioned_buffer";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "partitioned_buffer";
              sha256 = "64019407fd6e0822d591ac7060c1180e3f746691bbc5ace29c7a0100e469ef6e";
            };

            beamDeps = [
              nimble_options
              telemetry
            ];
          };
        in
        drv;

      permit =
        let
          version = "0.4.0";
          drv = buildMix {
            inherit version;
            name = "permit";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "permit";
              sha256 = "e2171e0ef75f14107394f19c5f23c59365ec96cbe3831536eaa2a3e3c4d3cb2b";
            };
          };
        in
        drv;

      permit_ecto =
        let
          version = "0.3.0";
          drv = buildMix {
            inherit version;
            name = "permit_ecto";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "permit_ecto";
              sha256 = "f824489a9dc1ae69792cd171258b733794641802ac1c04cbf77c1d58eabefd3d";
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
          version = "1.8.7";
          drv = buildMix {
            inherit version;
            name = "phoenix";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix";
              sha256 = "47352f72d6ab31009ef77516b1b3a14745be97b54061fd458031b9d8294869d5";
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
          version = "1.1.30";
          drv = buildMix {
            inherit version;
            name = "phoenix_live_view";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix_live_view";
              sha256 = "a353c51ac1e3190910f01a6100c7d5cc02c5e22e7374fd817bd3aedd21149039";
            };

            beamDeps = [
              igniter
              jason
              lazy_html
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
          version = "1.19.2";
          drv = buildMix {
            inherit version;
            name = "plug";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "plug";
              sha256 = "b6fce20a56af5e60fa5dfecf3f907bb98ec981be43c79a3809a499bc3d133de0";
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
          version = "0.22.2";
          drv = buildMix {
            inherit version;
            name = "postgrex";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "postgrex";
              sha256 = "8946382ddb06294f56026ac4278b3cc212bac8a2c82ed68b4087819ed1abc53b";
            };

            beamDeps = [
              db_connection
              decimal
              jason
            ];
          };
        in
        drv;

      puid =
        let
          version = "1.1.2";
          drv = buildMix {
            inherit version;
            name = "puid";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "puid";
              sha256 = "fbd1691e29e576c4fbf23852f4d256774702ad1f2a91b37e4344f7c278f1ffaa";
            };

            beamDeps = [
              crypto_rand
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
          version = "0.5.18";
          drv = buildMix {
            inherit version;
            name = "req";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "req";
              sha256 = "fa03812c440a9754bf34355e0c5d4f3ed316458db62e3284b7a352ef8dc0b996";
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

      rewrite =
        let
          version = "1.3.0";
          drv = buildMix {
            inherit version;
            name = "rewrite";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "rewrite";
              sha256 = "d111ac7ff3a58a802ef4f193bbd1831e00a9c57b33276e5068e8390a212714a5";
            };

            beamDeps = [
              glob_ex
              sourceror
              text_diff
            ];
          };
        in
        drv;

      rexec =
        let
          version = "0.1.0";
          drv = buildMix {
            inherit version;
            name = "rexec";
            appConfigPath = ../../config;

            src = builtins.fetchGit {
              url = "https://codeberg.org/adamcstephens/rexec.git";
              rev = "eb4760ce8a51c8296b553681ef202ea124d896c6";
              allRefs = true;
            };
          };
        in
        drv;

      rustler =
        let
          version = "0.36.2";
          drv = buildMix {
            inherit version;
            name = "rustler";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "rustler";
              sha256 = "93832a6dbc1166739a19cd0c25e110e4cf891f16795deb9361dfcae95f6c88fe";
            };

            beamDeps = [
              jason
              toml
            ];
          };
        in
        drv;

      secure_random =
        let
          version = "0.5.1";
          drv = buildMix {
            inherit version;
            name = "secure_random";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "secure_random";
              sha256 = "1b9754f15e3940a143baafd19da12293f100044df69ea12db5d72878312ae6ab";
            };
          };
        in
        drv;

      shards =
        let
          version = "1.1.1";
          drv = buildRebar3 {
            inherit version;
            name = "shards";

            src = fetchHex {
              inherit version;
              pkg = "shards";
              sha256 = "169a045dae6668cda15fbf86d31bf433d0dbbaec42c8c23ca4f8f2d405ea8eda";
            };
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
          version = "1.2.2";
          drv = buildMix {
            inherit version;
            name = "slipstream";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "slipstream";
              sha256 = "ccb873ddb21aadb37c5c7745014febe6da0aa2cef0c4e73e7d08ce11d18aacd0";
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

      sourceror =
        let
          version = "1.12.0";
          drv = buildMix {
            inherit version;
            name = "sourceror";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "sourceror";
              sha256 = "755703683bd014ebcd5de9acc24b68fb874a660a568d1d63f8f98cd8a6ef9cd0";
            };
          };
        in
        drv;

      spitfire =
        let
          version = "0.3.12";
          drv = buildMix {
            inherit version;
            name = "spitfire";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "spitfire";
              sha256 = "a389931287b85330c0e954ab06447e198516ab368a232a0200ed77ca13ca9acf";
            };
          };
        in
        drv;

      sweet_xml =
        let
          version = "0.7.5";
          drv = buildMix {
            inherit version;
            name = "sweet_xml";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "sweet_xml";
              sha256 = "193b28a9b12891cae351d81a0cead165ffe67df1b73fe5866d10629f4faefb12";
            };
          };
        in
        drv;

      systemd =
        let
          version = "0.6.2+build.155.ref62723b2";
          drv = buildRebar3 {
            inherit version;
            name = "systemd";

            src = fetchFromGitHub {
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
          version = "1.4.2";
          drv = buildRebar3 {
            inherit version;
            name = "telemetry";

            src = fetchHex {
              inherit version;
              pkg = "telemetry";
              sha256 = "928f6495066506077862c0d1646609eed891a4326bee3126ba54b60af61febb1";
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

      text_diff =
        let
          version = "0.1.0";
          drv = buildMix {
            inherit version;
            name = "text_diff";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "text_diff";
              sha256 = "d1ffaaecab338e49357b6daa82e435f877e0649041ace7755583a0ea3362dbd7";
            };
          };
        in
        drv;

      thousand_island =
        let
          version = "1.4.3";
          drv = buildMix {
            inherit version;
            name = "thousand_island";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "thousand_island";
              sha256 = "6e4ce09b0fd761a58594d02814d40f77daff460c48a7354a15ab353bb998ea0b";
            };

            beamDeps = [
              telemetry
            ];
          };
        in
        drv;

      toml =
        let
          version = "0.7.0";
          drv = buildMix {
            inherit version;
            name = "toml";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "toml";
              sha256 = "0690246a2478c1defd100b0c9b89b4ea280a22be9a7b313a8a058a2408a2fa70";
            };
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

      zoneinfo =
        let
          version = "0.1.8";
          drv = buildMix {
            inherit version;
            name = "zoneinfo";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "zoneinfo";
              sha256 = "3999755971bbf85f0c8c75a724be560199bb63406660585849f0eb680e2333f7";
            };
          };
        in
        drv;

    };
in
self
