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
  stdenv,
  pkg-config,
  sqlite,
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
            dest="''${dest#lib}"
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

      argon2_elixir =
        let
          version = "4.1.3";
          drv = buildMix {
            inherit version;
            name = "argon2_elixir";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "argon2_elixir";
              sha256 = "7c295b8d8e0eaf6f43641698f962526cdf87c6feb7d14bd21e599271b510608c";
            };

            beamDeps = [
              comeonin
              elixir_make
            ];
          };
        in
        drv.override (workarounds.elixirMake { } drv);

      bandit =
        let
          version = "1.15.0";
          drv = buildMix {
            inherit version;
            name = "bandit";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "bandit";
              sha256 = "e3b29c4a5107f4bf7dfaa263c50b9b97ddcc132622197c110e2e10a921641c44";
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
          version = "2.3.8";
          drv = buildMix {
            inherit version;
            name = "boruta";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "boruta";
              sha256 = "27c703836793c852fb98d94d58ef9bb93ca7a51fce2196e16d19ee7d5cfecc62";
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

      comeonin =
        let
          version = "5.5.1";
          drv = buildMix {
            inherit version;
            name = "comeonin";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "comeonin";
              sha256 = "65aac8f19938145377cee73973f192c5645873dcf550a8a6b18187d17c13ccdb";
            };
          };
        in
        drv;

      crontab =
        let
          version = "1.2.1";
          drv = buildMix {
            inherit version;
            name = "crontab";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "crontab";
              sha256 = "ab550a005380d30c05038a1abff66989591e7703b2cc0d83f446a86fab258150";
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
          version = "2.10.2";
          drv = buildMix {
            inherit version;
            name = "db_connection";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "db_connection";
              sha256 = "510b14482330f1af6490a2fa0efd8d4f1435d1529b165647df22ac0f2df0fa93";
            };

            beamDeps = [
              telemetry
            ];
          };
        in
        drv;

      decimal =
        let
          version = "3.2.0";
          drv = buildMix {
            inherit version;
            name = "decimal";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "decimal";
              sha256 = "190bca80580ce61aa69bb0eacadd7677710205c770225c2c2c07e32a5c31b234";
            };
          };
        in
        drv;

      ecto =
        let
          version = "3.14.3";
          drv = buildMix {
            inherit version;
            name = "ecto";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "ecto";
              sha256 = "da2548bd3ced0f56c27d54255389bbbb8f110150ce15cffc95ec0cafa364465c";
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
          version = "0.10.1";
          drv = buildMix {
            inherit version;
            name = "elixir_make";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "elixir_make";
              sha256 = "ce1eaa234bc87f0279718e793fd6f8ad35b4e8ee8d412329e3879eee8d40adba";
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

      envar =
        let
          version = "1.1.0";
          drv = buildMix {
            inherit version;
            name = "envar";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "envar";
              sha256 = "97028ab4a040a5c19e613fdf46a41cf51c6e848d99077e525b338e21d2993320";
            };
          };
        in
        drv;

      esbuild =
        let
          version = "0.10.1";
          drv = buildMix {
            inherit version;
            name = "esbuild";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "esbuild";
              sha256 = "890f251330052dcacafa40c409769e7c42e3876fb0ae450707bde831be7b34ea";
            };

            beamDeps = [
              jason
            ];
          };
        in
        drv;

      ex_ast =
        let
          version = "0.16.0";
          drv = buildMix {
            inherit version;
            name = "ex_ast";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "ex_ast";
              sha256 = "700303b0cb693cb36dbac3a2f66a609282b108114fa20179395f36a13a9043b4";
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
          version = "2.8.0";
          drv = buildMix {
            inherit version;
            name = "ex_aws";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "ex_aws";
              sha256 = "7c2263797be64502ceabd9ff91a4030599676c886b3f1e1840fc74bef807f7df";
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
          version = "2.6.0";
          drv = buildMix {
            inherit version;
            name = "ex_aws_s3";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "ex_aws_s3";
              sha256 = "7cb0014e973abc50916e47cab5cd94e9a97a9a3aac325e72b5407f882b3dadd2";
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
          version = "0.11.5";
          drv = buildMix {
            inherit version;
            name = "ex_json_schema";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "ex_json_schema";
              sha256 = "61ed2a8f07bd115e7ab6d45c147642a8c73b962bc419fadbb248046b9d3d0f20";
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

      fields =
        let
          version = "2.12.0";
          drv = buildMix {
            inherit version;
            name = "fields";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "fields";
              sha256 = "6174a777fa37207470f925488e44ccc1a4974da672e6bfcc05441c8b83c2d844";
            };

            beamDeps = [
              argon2_elixir
              ecto
              envar
              html_sanitize_ex
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
          version = "0.25.0";
          drv = buildMix {
            inherit version;
            name = "finch";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "finch";
              sha256 = "9fd9a2c47a9033f4d70fad6e7d656948c08bc6652699de20e609a5917c0bb0a5";
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
          version = "0.2.0";
          drv = buildMix {
            inherit version;
            name = "fine";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "fine";
              sha256 = "6f69a9e8dadbfd017b27f611b000362870683ae65f28aec904f36ec4c5058db5";
            };
          };
        in
        drv;

      floki =
        let
          version = "0.38.5";
          drv = buildMix {
            inherit version;
            name = "floki";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "floki";
              sha256 = "c8c5b04455f01b076cd489fee7dc26b49edf9851ef61146e743f4676114bf6b0";
            };
          };
        in
        drv;

      flop =
        let
          version = "0.29.1";
          drv = buildMix {
            inherit version;
            name = "flop";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "flop";
              sha256 = "9f616c9e1578044026d3b41a690a1e6944faa7678380ceb360e77e271199f4a4";
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
          version = "0.27.0";
          drv = buildMix {
            inherit version;
            name = "flop_phoenix";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "flop_phoenix";
              sha256 = "37f9ddf36b61ae88855efdc53810f377de6cd13337a2d5db848badc0eb204dd7";
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
          version = "0.1.12";
          drv = buildMix {
            inherit version;
            name = "glob_ex";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "glob_ex";
              sha256 = "2e2fac83f113514434c7eaf267b4c38af2f91766f1cab2c5db7053b7fc1ee0bb";
            };
          };
        in
        drv;

      hpax =
        let
          version = "1.1.0";
          drv = buildMix {
            inherit version;
            name = "hpax";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "hpax";
              sha256 = "0b8d0f05832f55571d65ac720f79bf8994138ffbb133209dc4685eae0ad456a8";
            };
          };
        in
        drv;

      html_sanitize_ex =
        let
          version = "1.5.6";
          drv = buildMix {
            inherit version;
            name = "html_sanitize_ex";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "html_sanitize_ex";
              sha256 = "b7592ad4a6d8d509b84e2dd3b2e4db4ed61315da711c8d98c68d4e9546c40df4";
            };

            beamDeps = [
              mochiweb
            ];
          };
        in
        drv;

      igniter =
        let
          version = "0.8.5";
          drv = buildMix {
            inherit version;
            name = "igniter";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "igniter";
              sha256 = "3593e74a12fb82dcdc86207c12890505cfd3f0f0e9e0db11446fbcd7cf7a089e";
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
          version = "2.8.0";
          drv = buildMix {
            inherit version;
            name = "joken";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "joken";
              sha256 = "a76cc8ae7cca4c8144c1ed335c3d9a229c84e69a20a750a4eba24a1d549a89f6";
            };

            beamDeps = [
              jose
            ];
          };
        in
        drv;

      jose =
        let
          version = "1.11.13";
          drv = buildMix {
            inherit version;
            name = "jose";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "jose";
              sha256 = "15d8bd0f01ab29d1771e8da1f60f9c98725b23a17f7312cdd40e8e2757bd98c7";
            };
          };
        in
        drv;

      lazy_html =
        let
          version = "0.1.15";
          drv = buildMix {
            inherit version;
            name = "lazy_html";
            appConfigPath = ../../config;

            buildInputs = [
              lexbor
            ];

            src = fetchHex {
              inherit version;
              pkg = "lazy_html";
              sha256 = "139b5a6ebb6a9181b2da660f7aeb47c12b1af48c79524a57ebf207552301df4a";
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
          version = "1.11.0";
          drv = buildMix {
            inherit version;
            name = "mint";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "mint";
              sha256 = "c6279ba2d6aa3a383a1d4cfbe7b59f42e6efd400f58d8e2acfeac48a438693ab";
            };

            beamDeps = [
              hpax
            ];
          };
        in
        drv;

      mint_web_socket =
        let
          version = "1.0.6";
          drv = buildMix {
            inherit version;
            name = "mint_web_socket";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "mint_web_socket";
              sha256 = "0c360e9012413f1c115a63532601eb5d63731aab7010949178769760686c1698";
            };

            beamDeps = [
              mint
            ];
          };
        in
        drv;

      mix_audit =
        let
          version = "2.1.5";
          drv = buildMix {
            inherit version;
            name = "mix_audit";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "mix_audit";
              sha256 = "87f9298e21da32f697af535475860dc1d3617a010e0b418d2ec6142bc8b42d69";
            };

            beamDeps = [
              jason
              yaml_elixir
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

      mochiweb =
        let
          version = "3.6.1";
          drv = buildRebar3 {
            inherit version;
            name = "mochiweb";

            src = fetchHex {
              inherit version;
              pkg = "mochiweb";
              sha256 = "23bc48bc8a129b4e894648c01a1ec77405e879b8b3d7e170711cca6ac1dc819c";
            };
          };
        in
        drv;

      nebulex =
        let
          version = "3.1.0";
          drv = buildMix {
            inherit version;
            name = "nebulex";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "nebulex";
              sha256 = "7ea06e05ae76918056ecddc21ccdbf2c271f528e5bb75d4f2b6505b4063c7257";
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
          version = "3.3.0";
          drv = buildMix {
            inherit version;
            name = "nebulex_distributed";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "nebulex_distributed";
              sha256 = "544adfb194ebfdb1d42edc8e6494f1c1aa6172d34b8d2f4e4c930388beb8dd7f";
            };

            beamDeps = [
              ex_hash_ring
              nebulex
              nebulex_local
              nebulex_streams
              telemetry
              tidefall
            ];
          };
        in
        drv;

      nebulex_local =
        let
          version = "3.1.0";
          drv = buildMix {
            inherit version;
            name = "nebulex_local";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "nebulex_local";
              sha256 = "dbf4056cdf7ac6b4e6a3fb16bbd042acf2efa5d3af3e61a33be840655ee6c5b9";
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
          version = "0.2.1";
          drv = buildMix {
            inherit version;
            name = "nebulex_streams";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "nebulex_streams";
              sha256 = "a44c9f328011ea16b9c68b9c4f7df63f60ce6875ac8e23f03215373a7f23a450";
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
          version = "1.2.0";
          drv = buildMix {
            inherit version;
            name = "nimble_options";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "nimble_options";
              sha256 = "3a784a75ef9e407619c8c9e98239b1acd29216deb737044a8c1063e2671ce6d9";
            };
          };
        in
        drv;

      nimble_pool =
        let
          version = "1.2.0";
          drv = buildMix {
            inherit version;
            name = "nimble_pool";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "nimble_pool";
              sha256 = "bc442e72578c21842589fa8e5886b6175fa5245fdbbad35fc08db277ac2b2c0d";
            };
          };
        in
        drv;

      oban =
        let
          version = "2.24.2";
          drv = buildMix {
            inherit version;
            name = "oban";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "oban";
              sha256 = "605a3b61d554ab416e0cf462b5ea060f7d19ae3dbf1516ec6b5ee30aeb1a5d0b";
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
          version = "3.9.2";
          drv = buildMix {
            inherit version;
            name = "oidcc";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "oidcc";
              sha256 = "e469213a2518904e805ff4f8325a405ac740a74a381e711968d32636c10d9c9b";
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
          version = "3.22.4";
          drv = buildMix {
            inherit version;
            name = "open_api_spex";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "open_api_spex";
              sha256 = "f658d73396e2277e584085a6146481eb085d815a716089defe4f94b26cf8b05f";
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
          version = "0.13.1";
          drv = buildMix {
            inherit version;
            name = "owl";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "owl";
              sha256 = "351e768af8f2edc575cdaab1a5a2f6d6381be591758a026c701c703145508a0c";
            };
          };
        in
        drv;

      permit =
        let
          version = "0.4.1";
          drv = buildMix {
            inherit version;
            name = "permit";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "permit";
              sha256 = "f5d80a3dabbc5f65873079c376a5334578ca1abcc82d8e91e397c68962aa9a54";
            };

            beamDeps = [
              igniter
            ];
          };
        in
        drv;

      permit_ecto =
        let
          version = "0.3.1";
          drv = buildMix {
            inherit version;
            name = "permit_ecto";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "permit_ecto";
              sha256 = "fae416cc86a0a4a46d6080eb41a3399f4d3668878c5bc4a48ab1b33141ed078b";
            };

            beamDeps = [
              ecto
              ecto_sql
              igniter
              jason
              permit
            ];
          };
        in
        drv;

      phoenix =
        let
          version = "1.8.17";
          drv = buildMix {
            inherit version;
            name = "phoenix";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix";
              sha256 = "21fd4d6a33c6af4e86b95156a49815a59140c2ba4ef8cf19565dbb7be881633e";
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
          version = "4.4.0";
          drv = buildMix {
            inherit version;
            name = "phoenix_html";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix_html";
              sha256 = "94832038da7ab8f86d4c0d36f7797a269fd06fe611f25c69f55108c075505228";
            };
          };
        in
        drv;

      phoenix_live_dashboard =
        let
          version = "0.9.1";
          drv = buildMix {
            inherit version;
            name = "phoenix_live_dashboard";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix_live_dashboard";
              sha256 = "de25e1a28cfb64413d8bdaf3ba5b64da1a19e0ed44a02320119523cc45da051d";
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
          version = "1.2.15";
          drv = buildMix {
            inherit version;
            name = "phoenix_live_view";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix_live_view";
              sha256 = "06de7d327a964c81e93a4d64f67088852bf3512f30c04af563101feaac1deaf1";
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
          version = "2.4.1";
          drv = buildMix {
            inherit version;
            name = "phoenix_pubsub";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix_pubsub";
              sha256 = "352fba7a87bf61395b6e97da66944ad9b1bfe5459e5981039f60d68270bd9700";
            };
          };
        in
        drv;

      phoenix_template =
        let
          version = "1.1.0";
          drv = buildMix {
            inherit version;
            name = "phoenix_template";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix_template";
              sha256 = "eba70070de79b2c3501ef205a74a69f98ab352f3785aa15da9ed161f9fe0fd5d";
            };

            beamDeps = [
              phoenix_html
            ];
          };
        in
        drv;

      plug =
        let
          version = "1.20.4";
          drv = buildMix {
            inherit version;
            name = "plug";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "plug";
              sha256 = "96ee42c0b8b35bcb14e3e65afb85abe9bb7745a8576e8c602802bbb01e5acf72";
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
          version = "2.2.1";
          drv = buildMix {
            inherit version;
            name = "plug_crypto";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "plug_crypto";
              sha256 = "4417ccbd8f85e627321cd07d2ab9c4b621f1fd883b9905af241f9b4b780b94b6";
            };
          };
        in
        drv;

      postgrex =
        let
          version = "0.23.0";
          drv = buildMix {
            inherit version;
            name = "postgrex";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "postgrex";
              sha256 = "f001ab3fd56f5ef2b8b3cd4a512005614fcaeccca068ddb29e57d338a7f104ec";
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
          version = "0.7.5";
          drv = buildMix {
            inherit version;
            name = "req";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "req";
              sha256 = "576853c4bf403faa3c1fa5d093e0759227083b78f8a6864c67d62c0a9c45514d";
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
          version = "1.3.1";
          drv = buildMix {
            inherit version;
            name = "rewrite";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "rewrite";
              sha256 = "20b33e1161bcba0a30d842d983c08bfbb6baad83238399067364a5d2c5a206ae";
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

            src = fetchFromGitHub {
              owner = "adamcstephens";
              repo = "rexec";
              rev = "49e84639f25eaee5aab7daa59622483cdf917f84";
              hash = "sha256-tJ1pwy0WUSEP7H0Qq10lrILlfOB6HXm9X3jz1pyhiTE=";
            };
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
          version = "4.3.0";
          drv = buildMix {
            inherit version;
            name = "shortuuid";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "shortuuid";
              sha256 = "be660d08094567b3189a3e6128b710c2a7cef105745fc38912b066962107c056";
            };
          };
        in
        drv;

      slipstream =
        let
          version = "1.3.0";
          drv = buildMix {
            inherit version;
            name = "slipstream";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "slipstream";
              sha256 = "b8893394e0dadef22a1ca7615a1d9e1c7d883cf6491867aee14fa3a2dbd562a4";
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
          version = "1.13.0";
          drv = buildMix {
            inherit version;
            name = "sourceror";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "sourceror";
              sha256 = "d72dd66dd2b82cc8e818b54ba0ab2ef0314c83ffcf231b1ad2ade00fa2ee3375";
            };
          };
        in
        drv;

      spitfire =
        let
          version = "0.4.3";
          drv = buildMix {
            inherit version;
            name = "spitfire";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "spitfire";
              sha256 = "4f771bbdf00fe6eda6e2a7e488c42ead48142fea697349510a41fabb41376632";
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
          version = "0.5.2";
          drv = buildMix {
            inherit version;
            name = "tailwind";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "tailwind";
              sha256 = "e0e5fd9799fb9231b97e52ce074d9ff509043d1946713a71fbc608e81eff7e66";
            };
          };
        in
        drv;

      telemetry =
        let
          version = "1.4.3";
          drv = buildRebar3 {
            inherit version;
            name = "telemetry";

            src = fetchHex {
              inherit version;
              pkg = "telemetry";
              sha256 = "17a63581cf2e832a238287f5fe6811e8ca1f333249f1376ad653164a3c4770d4";
            };
          };
        in
        drv;

      telemetry_metrics =
        let
          version = "1.2.0";
          drv = buildMix {
            inherit version;
            name = "telemetry_metrics";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "telemetry_metrics";
              sha256 = "71dde12fc29b58b9c77ec17ec319109e5ca848d010fc1965ed4463bba1837c07";
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
          version = "1.6.0";
          drv = buildMix {
            inherit version;
            name = "thousand_island";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "thousand_island";
              sha256 = "4d4720470f091fc21a1311777c2ac66916c43621bffc068590c9f9bb3cd057a3";
            };

            beamDeps = [
              telemetry
            ];
          };
        in
        drv;

      tidefall =
        let
          version = "1.0.0";
          drv = buildMix {
            inherit version;
            name = "tidefall";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "tidefall";
              sha256 = "7e373c0417dbbb42f5655bbbe1c65da2e4ea2a623acd8e9431eb0b0c9e6bd8fd";
            };

            beamDeps = [
              nimble_options
              telemetry
            ];
          };
        in
        drv;

      typedstruct =
        let
          version = "0.6.3";
          drv = buildMix {
            inherit version;
            name = "typedstruct";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "typedstruct";
              sha256 = "d9e58c49efc6c6ab523be304f08f683b02c1434c97fcac15e30cb743c8a6941a";
            };
          };
        in
        drv;

      ueberauth =
        let
          version = "0.11.0";
          drv = buildMix {
            inherit version;
            name = "ueberauth";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "ueberauth";
              sha256 = "59bc851cddc77a1697e65536ee54250930e93cc3bef0a0b547b3f42bb757bffd";
            };

            beamDeps = [
              plug
            ];
          };
        in
        drv;

      ueberauth_oidcc =
        let
          version = "0.5.0";
          drv = buildMix {
            inherit version;
            name = "ueberauth_oidcc";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "ueberauth_oidcc";
              sha256 = "9b0ec502ee6c3e6978abd402e3a0afaa7416fe67cac52df9feb932f05f8c2ace";
            };

            beamDeps = [
              jose
              oidcc
              plug
              plug_crypto
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
          version = "0.7.2";
          drv = buildMix {
            inherit version;
            name = "websock_adapter";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "websock_adapter";
              sha256 = "f9e80710008783864177c81e9d8418d05769ce10a26e9e538f5ed72e283f7358";
            };

            beamDeps = [
              bandit
              plug
              websock
            ];
          };
        in
        drv;

      yamerl =
        let
          version = "0.10.0";
          drv = buildRebar3 {
            inherit version;
            name = "yamerl";

            src = fetchHex {
              inherit version;
              pkg = "yamerl";
              sha256 = "346adb2963f1051dc837a2364e4acf6eb7d80097c0f53cbdc3046ec8ec4b4e6e";
            };
          };
        in
        drv;

      yaml_elixir =
        let
          version = "2.12.2";
          drv = buildMix {
            inherit version;
            name = "yaml_elixir";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "yaml_elixir";
              sha256 = "e7c1b10122f973e6558462d51c39026ba0e14afbc6745318e990ea82cfe9e159";
            };

            beamDeps = [
              yamerl
            ];
          };
        in
        drv;

      zoneinfo =
        let
          version = "0.1.9";
          drv = buildMix {
            inherit version;
            name = "zoneinfo";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "zoneinfo";
              sha256 = "8bc3266afe79ab668de4fb2a7f182152c90f610bdd8519528e8ea1af70e0dea8";
            };
          };
        in
        drv;

    };
in
self
