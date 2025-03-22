{
  pkgs,
  lib,
  beamPackages,
  overrides ? (x: y: { }),
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
        fenixOverlay = import "${
          fetchTarball {
            url = "https://github.com/nix-community/fenix/archive/056c9393c821a4df356df6ce7f14c722dc8717ec.tar.gz";
            sha256 = "sha256:1cdfh6nj81gjmn689snigidyq7w98gd8hkl5rvhly6xj7vyppmnd";
          }
        }/overlay.nix";
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
              ] ++ extendedPkgs.lib.lists.optional extendedPkgs.stdenv.isDarwin extendedPkgs.darwin.IOKit;
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

      acceptor_pool =
        let
          version = "1.0.0";
          drv = buildRebar3 {
            inherit version;
            name = "acceptor_pool";

            src = fetchHex {
              inherit version;
              pkg = "acceptor_pool";
              sha256 = "0cbcd83fdc8b9ad2eee2067ef8b91a14858a5883cb7cd800e6fcd5803e158788";
            };
          };
        in
        drv;

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
          version = "1.6.7";
          drv = buildMix {
            inherit version;
            name = "bandit";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "bandit";
              sha256 = "551ba8ff5e4fc908cbeb8c9f0697775fb6813a96d9de5f7fe02e34e76fd7d184";
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
          version = "1.0.12";
          drv = buildMix {
            inherit version;
            name = "castore";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "castore";
              sha256 = "3dca286b2186055ba0c9449b4e95b97bf1b57b47c1f2644555879e659960c224";
            };
          };
        in
        drv;

      chatterbox =
        let
          version = "0.15.1";
          drv = buildRebar3 {
            inherit version;
            name = "chatterbox";

            src = fetchHex {
              inherit version;
              pkg = "ts_chatterbox";
              sha256 = "4f75b91451338bc0da5f52f3480fa6ef6e3a2aeecfc33686d6b3d0a0948f31aa";
            };

            beamDeps = [
              hpack
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

      ctx =
        let
          version = "0.6.0";
          drv = buildRebar3 {
            inherit version;
            name = "ctx";

            src = fetchHex {
              inherit version;
              pkg = "ctx";
              sha256 = "a14ed2d1b67723dbebbe423b28d7615eb0bdcba6ff28f2d1f1b0a7e1d4aa5fc2";
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
          version = "2.7.0";
          drv = buildMix {
            inherit version;
            name = "db_connection";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "db_connection";
              sha256 = "dcf08f31b2701f857dfc787fbad78223d61a32204f217f15e881dd93e4bdd3ff";
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
          version = "2.2.0";
          drv = buildMix {
            inherit version;
            name = "deps_nix";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "deps_nix";
              sha256 = "cc302e2b3edc51dc658b32552f3bbef276f722f78936ac923b38fa60f899f645";
            };

            beamDeps = [
              mint
            ];
          };
        in
        drv;

      ecto =
        let
          version = "3.12.5";
          drv = buildMix {
            inherit version;
            name = "ecto";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "ecto";
              sha256 = "6eb18e80bef8bb57e17f5a7f068a1719fbda384d40fc37acb8eb8aeca493b6ea";
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
          version = "3.12.1";
          drv = buildMix {
            inherit version;
            name = "ecto_sql";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "ecto_sql";
              sha256 = "aff5b958a899762c5f09028c847569f7dfb9cc9d63bdb8133bff8a5546de6bf5";
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
          version = "0.9.0";
          drv = buildMix {
            inherit version;
            name = "esbuild";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "esbuild";
              sha256 = "b415027f71d5ab57ef2be844b2a10d0c1b5a492d431727f43937adce22ba45ae";
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
          version = "0.19.0";
          drv = buildMix {
            inherit version;
            name = "finch";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "finch";
              sha256 = "fc5324ce209125d1e2fa0fcd2634601c52a787aff1cd33ee833664a5af4ea2b6";
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

      gproc =
        let
          version = "0.9.1";
          drv = buildRebar3 {
            inherit version;
            name = "gproc";

            src = fetchHex {
              inherit version;
              pkg = "gproc";
              sha256 = "905088e32e72127ed9466f0bac0d8e65704ca5e73ee5a62cb073c3117916d507";
            };
          };
        in
        drv;

      grpcbox =
        let
          version = "0.17.1";
          drv = buildRebar3 {
            inherit version;
            name = "grpcbox";

            src = fetchHex {
              inherit version;
              pkg = "grpcbox";
              sha256 = "4a3b5d7111daabc569dc9cbd9b202a3237d81c80bf97212fbc676832cb0ceb17";
            };

            beamDeps = [
              acceptor_pool
              chatterbox
              ctx
              gproc
            ];
          };
        in
        drv;

      hpack =
        let
          version = "0.3.0";
          drv = buildRebar3 {
            inherit version;
            name = "hpack";

            src = fetchHex {
              inherit version;
              pkg = "hpack_erl";
              sha256 = "d6137d7079169d8c485c6962dfe261af5b9ef60fbc557344511c1e65e3d95fb0";
            };
          };
        in
        drv;

      hpax =
        let
          version = "1.0.2";
          drv = buildMix {
            inherit version;
            name = "hpax";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "hpax";
              sha256 = "2f09b4c1074e0abd846747329eaa26d535be0eb3d189fa69d812bfb8bfefd32f";
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
          version = "2.0.6";
          drv = buildMix {
            inherit version;
            name = "mime";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "mime";
              sha256 = "c9945363a6b26d747389aac3643f8e0e09d30499a138ad64fe8fd1d13d9b153e";
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
          version = "3.2.6";
          drv = buildMix {
            inherit version;
            name = "oidcc";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "oidcc";
              sha256 = "0530b902adce9117e797af41801b41e5e3d2a0288839bf69f2b54b19914fc522";
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
          version = "3.21.2";
          drv = buildMix {
            inherit version;
            name = "open_api_spex";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "open_api_spex";
              sha256 = "f42ae6ed668b895ebba3e02773cfb4b41050df26f803f2ef634c72a7687dc387";
            };

            beamDeps = [
              decimal
              jason
              plug
            ];
          };
        in
        drv;

      opentelemetry =
        let
          version = "1.5.0";
          drv = buildRebar3 {
            inherit version;
            name = "opentelemetry";

            src = fetchHex {
              inherit version;
              pkg = "opentelemetry";
              sha256 = "cdf4f51d17b592fc592b9a75f86a6f808c23044ba7cf7b9534debbcc5c23b0ee";
            };

            beamDeps = [
              opentelemetry_api
            ];
          };
        in
        drv;

      opentelemetry_api =
        let
          version = "1.4.0";
          drv = buildMix {
            inherit version;
            name = "opentelemetry_api";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "opentelemetry_api";
              sha256 = "3dfbbfaa2c2ed3121c5c483162836c4f9027def469c41578af5ef32589fcfc58";
            };
          };
        in
        drv;

      opentelemetry_bandit =
        let
          version = "0.2.0";
          drv = buildMix {
            inherit version;
            name = "opentelemetry_bandit";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "opentelemetry_bandit";
              sha256 = "57e31355a860250c9203ae34f0bf0290a14b72ab02b154535e1b2512a0767bca";
            };

            beamDeps = [
              nimble_options
              opentelemetry_api
              opentelemetry_semantic_conventions
              otel_http
              plug
              telemetry
            ];
          };
        in
        drv;

      opentelemetry_exporter =
        let
          version = "1.8.0";
          drv = buildRebar3 {
            inherit version;
            name = "opentelemetry_exporter";

            src = fetchHex {
              inherit version;
              pkg = "opentelemetry_exporter";
              sha256 = "a1f9f271f8d3b02b81462a6bfef7075fd8457fdb06adff5d2537df5e2264d9af";
            };

            beamDeps = [
              grpcbox
              opentelemetry
              opentelemetry_api
              tls_certificate_check
            ];
          };
        in
        drv;

      opentelemetry_phoenix =
        let
          version = "2.0.1";
          drv = buildMix {
            inherit version;
            name = "opentelemetry_phoenix";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "opentelemetry_phoenix";
              sha256 = "a24fdccdfa6b890c8892c6366beab4a15a27ec0c692b0f77ec2a862e7b235f6e";
            };

            beamDeps = [
              nimble_options
              opentelemetry_api
              opentelemetry_process_propagator
              opentelemetry_semantic_conventions
              opentelemetry_telemetry
              otel_http
              plug
              telemetry
            ];
          };
        in
        drv;

      opentelemetry_process_propagator =
        let
          version = "0.3.0";
          drv = buildMix {
            inherit version;
            name = "opentelemetry_process_propagator";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "opentelemetry_process_propagator";
              sha256 = "7243cb6de1523c473cba5b1aefa3f85e1ff8cc75d08f367104c1e11919c8c029";
            };

            beamDeps = [
              opentelemetry_api
            ];
          };
        in
        drv;

      opentelemetry_semantic_conventions =
        let
          version = "1.27.0";
          drv = buildMix {
            inherit version;
            name = "opentelemetry_semantic_conventions";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "opentelemetry_semantic_conventions";
              sha256 = "9681ccaa24fd3d810b4461581717661fd85ff7019b082c2dff89c7d5b1fc2864";
            };
          };
        in
        drv;

      opentelemetry_telemetry =
        let
          version = "1.1.2";
          drv = buildMix {
            inherit version;
            name = "opentelemetry_telemetry";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "opentelemetry_telemetry";
              sha256 = "641ab469deb181957ac6d59bce6e1321d5fe2a56df444fc9c19afcad623ab253";
            };

            beamDeps = [
              opentelemetry_api
              telemetry
            ];
          };
        in
        drv;

      otel_http =
        let
          version = "0.2.0";
          drv = buildRebar3 {
            inherit version;
            name = "otel_http";

            src = fetchHex {
              inherit version;
              pkg = "otel_http";
              sha256 = "f2beadf922c8cfeb0965488dd736c95cc6ea8b9efce89466b3904d317d7cc717";
            };
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
          version = "0.2.3";
          drv = buildMix {
            inherit version;
            name = "permit_ecto";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "permit_ecto";
              sha256 = "0b2b3a2b7a4e85b7f6f6278d61976f3e5b40484454f8fe58a90f79b4edc2ca1e";
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
          version = "1.7.20";
          drv = buildMix {
            inherit version;
            name = "phoenix";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix";
              sha256 = "6be2ab98302e8784a31829e0d50d8bdfa81a23cd912c395bafd8b8bfb5a086c2";
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
          version = "4.6.3";
          drv = buildMix {
            inherit version;
            name = "phoenix_ecto";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix_ecto";
              sha256 = "909502956916a657a197f94cc1206d9a65247538de8a5e186f7537c895d95764";
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
          version = "0.8.6";
          drv = buildMix {
            inherit version;
            name = "phoenix_live_dashboard";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix_live_dashboard";
              sha256 = "1681ab813ec26ca6915beb3414aa138f298e17721dc6a2bde9e6eb8a62360ff6";
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
          version = "1.0.4";
          drv = buildMix {
            inherit version;
            name = "phoenix_live_view";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix_live_view";
              sha256 = "a9865316ddf8d78f382d63af278d20436b52d262b60239956817a61279514366";
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
          version = "1.16.1";
          drv = buildMix {
            inherit version;
            name = "plug";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "plug";
              sha256 = "a13ff6b9006b03d7e33874945b2755253841b238c34071ed85b0e86057f8cddc";
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
          version = "2.1.0";
          drv = buildMix {
            inherit version;
            name = "plug_crypto";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "plug_crypto";
              sha256 = "131216a4b030b8f8ce0f26038bc4421ae60e4bb95c5cf5395e1421437824c4fa";
            };
          };
        in
        drv;

      postgrex =
        let
          version = "0.20.0";
          drv = buildMix {
            inherit version;
            name = "postgrex";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "postgrex";
              sha256 = "d36ef8b36f323d29505314f704e21a1a038e2dc387c6409ee0cd24144e187c0f";
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
          version = "0.5.8";
          drv = buildMix {
            inherit version;
            name = "req";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "req";
              sha256 = "d7fc5898a566477e174f26887821a3c5082b243885520ee4b45555f5d53f40ef";
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
          version = "4.0.0";
          drv = buildMix {
            inherit version;
            name = "shortuuid";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "shortuuid";
              sha256 = "b28297cfeae47e5d1b8f786f4de43a81969b2a18ebeef673d1880387d6b81181";
            };
          };
        in
        drv;

      ssl_verify_fun =
        let
          version = "1.1.7";
          drv = buildMix {
            inherit version;
            name = "ssl_verify_fun";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "ssl_verify_fun";
              sha256 = "fe4c190e8f37401d30167c8c405eda19469f34577987c76dde613e838bbc67f8";
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
          version = "0.2.4";
          drv = buildMix {
            inherit version;
            name = "tailwind";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "tailwind";
              sha256 = "c6e4a82b8727bab593700c998a4d98cf3d8025678bfde059aed71d0000c3e463";
            };

            beamDeps = [
              castore
            ];
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
          version = "1.3.11";
          drv = buildMix {
            inherit version;
            name = "thousand_island";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "thousand_island";
              sha256 = "555c18c62027f45d9c80df389c3d01d86ba11014652c00be26e33b1b64e98d29";
            };

            beamDeps = [
              telemetry
            ];
          };
        in
        drv;

      tls_certificate_check =
        let
          version = "1.27.0";
          drv = buildRebar3 {
            inherit version;
            name = "tls_certificate_check";

            src = fetchHex {
              inherit version;
              pkg = "tls_certificate_check";
              sha256 = "51a5ad3dbd72d4694848965f3b5076e8b55d70eb8d5057fcddd536029ab8a23c";
            };

            beamDeps = [
              ssl_verify_fun
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
          version = "0.4.1";
          drv = buildMix {
            inherit version;
            name = "ueberauth_oidcc";
            appConfigPath = ../../config;

            src = fetchHex {
              inherit version;
              pkg = "ueberauth_oidcc";
              sha256 = "ba4447d428df74d5cff8b6717e1249163649d946d4aefd22f7445a9979adab54";
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
