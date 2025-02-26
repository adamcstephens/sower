{ lib, beamPackages, overrides ? (x: y: {}) }:

let
  buildRebar3 = lib.makeOverridable beamPackages.buildRebar3;
  buildMix = lib.makeOverridable beamPackages.buildMix;
  buildErlangMk = lib.makeOverridable beamPackages.buildErlangMk;

  self = packages // (overrides self packages);

  packages = with beamPackages; with self; {
    acceptor_pool = buildRebar3 rec {
      name = "acceptor_pool";
      version = "1.0.0";

      src = fetchHex {
        pkg = "acceptor_pool";
        version = "${version}";
        sha256 = "0cbcd83fdc8b9ad2eee2067ef8b91a14858a5883cb7cd800e6fcd5803e158788";
      };

      beamDeps = [];
    };

    argon2 = buildRebar3 rec {
      name = "argon2";
      version = "1.2.0";

      src = fetchHex {
        pkg = "argon2";
        version = "${version}";
        sha256 = "76ae94bee3eee9a34079e92993c9fb3f49fbd9976680452cc84d0335244911a3";
      };

      beamDeps = [];
    };

    bandit = buildMix rec {
      name = "bandit";
      version = "1.6.7";

      src = fetchHex {
        pkg = "bandit";
        version = "${version}";
        sha256 = "551ba8ff5e4fc908cbeb8c9f0697775fb6813a96d9de5f7fe02e34e76fd7d184";
      };

      beamDeps = [ hpax plug telemetry thousand_island websock ];
    };

    castore = buildMix rec {
      name = "castore";
      version = "1.0.12";

      src = fetchHex {
        pkg = "castore";
        version = "${version}";
        sha256 = "3dca286b2186055ba0c9449b4e95b97bf1b57b47c1f2644555879e659960c224";
      };

      beamDeps = [];
    };

    chatterbox = buildRebar3 rec {
      name = "chatterbox";
      version = "0.15.1";

      src = fetchHex {
        pkg = "ts_chatterbox";
        version = "${version}";
        sha256 = "4f75b91451338bc0da5f52f3480fa6ef6e3a2aeecfc33686d6b3d0a0948f31aa";
      };

      beamDeps = [ hpack ];
    };

    cloak = buildMix rec {
      name = "cloak";
      version = "1.1.4";

      src = fetchHex {
        pkg = "cloak";
        version = "${version}";
        sha256 = "92b20527b9aba3d939fab0dd32ce592ff86361547cfdc87d74edce6f980eb3d7";
      };

      beamDeps = [ jason ];
    };

    cloak_ecto = buildMix rec {
      name = "cloak_ecto";
      version = "1.3.0";

      src = fetchHex {
        pkg = "cloak_ecto";
        version = "${version}";
        sha256 = "314beb0c123b8a800418ca1d51065b27ba3b15f085977e65c0f7b2adab2de1cc";
      };

      beamDeps = [ cloak ecto ];
    };

    ctx = buildRebar3 rec {
      name = "ctx";
      version = "0.6.0";

      src = fetchHex {
        pkg = "ctx";
        version = "${version}";
        sha256 = "a14ed2d1b67723dbebbe423b28d7615eb0bdcba6ff28f2d1f1b0a7e1d4aa5fc2";
      };

      beamDeps = [];
    };

    cuid2_ex = buildMix rec {
      name = "cuid2_ex";
      version = "0.2.0";

      src = fetchHex {
        pkg = "cuid2_ex";
        version = "${version}";
        sha256 = "49c3b81c1864f146e1cc3674ad3984ec16583c253e08d4d71d69b808e0054ea1";
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
      version = "2.3.0";

      src = fetchHex {
        pkg = "decimal";
        version = "${version}";
        sha256 = "a4d66355cb29cb47c3cf30e71329e58361cfcb37c34235ef3bf1d7bf3773aeac";
      };

      beamDeps = [];
    };

    ecto = buildMix rec {
      name = "ecto";
      version = "3.12.5";

      src = fetchHex {
        pkg = "ecto";
        version = "${version}";
        sha256 = "6eb18e80bef8bb57e17f5a7f068a1719fbda384d40fc37acb8eb8aeca493b6ea";
      };

      beamDeps = [ decimal jason telemetry ];
    };

    ecto_sql = buildMix rec {
      name = "ecto_sql";
      version = "3.12.1";

      src = fetchHex {
        pkg = "ecto_sql";
        version = "${version}";
        sha256 = "aff5b958a899762c5f09028c847569f7dfb9cc9d63bdb8133bff8a5546de6bf5";
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
      version = "0.9.0";

      src = fetchHex {
        pkg = "esbuild";
        version = "${version}";
        sha256 = "b415027f71d5ab57ef2be844b2a10d0c1b5a492d431727f43937adce22ba45ae";
      };

      beamDeps = [ jason ];
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
      version = "1.1.0";

      src = fetchHex {
        pkg = "expo";
        version = "${version}";
        sha256 = "fbadf93f4700fb44c331362177bdca9eeb8097e8b0ef525c9cc501cb9917c960";
      };

      beamDeps = [];
    };

    file_system = buildMix rec {
      name = "file_system";
      version = "1.1.0";

      src = fetchHex {
        pkg = "file_system";
        version = "${version}";
        sha256 = "bfcf81244f416871f2a2e15c1b515287faa5db9c6bcf290222206d120b3d43f6";
      };

      beamDeps = [];
    };

    finch = buildMix rec {
      name = "finch";
      version = "0.19.0";

      src = fetchHex {
        pkg = "finch";
        version = "${version}";
        sha256 = "fc5324ce209125d1e2fa0fcd2634601c52a787aff1cd33ee833664a5af4ea2b6";
      };

      beamDeps = [ mime mint nimble_options nimble_pool telemetry ];
    };

    floki = buildMix rec {
      name = "floki";
      version = "0.37.0";

      src = fetchHex {
        pkg = "floki";
        version = "${version}";
        sha256 = "516a0c15a69f78c47dc8e0b9b3724b29608aa6619379f91b1ffa47109b5d0dd3";
      };

      beamDeps = [];
    };

    gettext = buildMix rec {
      name = "gettext";
      version = "0.26.2";

      src = fetchHex {
        pkg = "gettext";
        version = "${version}";
        sha256 = "aa978504bcf76511efdc22d580ba08e2279caab1066b76bb9aa81c4a1e0a32a5";
      };

      beamDeps = [ expo ];
    };

    gproc = buildRebar3 rec {
      name = "gproc";
      version = "0.9.1";

      src = fetchHex {
        pkg = "gproc";
        version = "${version}";
        sha256 = "905088e32e72127ed9466f0bac0d8e65704ca5e73ee5a62cb073c3117916d507";
      };

      beamDeps = [];
    };

    grpcbox = buildRebar3 rec {
      name = "grpcbox";
      version = "0.17.1";

      src = fetchHex {
        pkg = "grpcbox";
        version = "${version}";
        sha256 = "4a3b5d7111daabc569dc9cbd9b202a3237d81c80bf97212fbc676832cb0ceb17";
      };

      beamDeps = [ acceptor_pool chatterbox ctx gproc ];
    };

    hpack = buildRebar3 rec {
      name = "hpack";
      version = "0.3.0";

      src = fetchHex {
        pkg = "hpack_erl";
        version = "${version}";
        sha256 = "d6137d7079169d8c485c6962dfe261af5b9ef60fbc557344511c1e65e3d95fb0";
      };

      beamDeps = [];
    };

    hpax = buildMix rec {
      name = "hpax";
      version = "1.0.2";

      src = fetchHex {
        pkg = "hpax";
        version = "${version}";
        sha256 = "2f09b4c1074e0abd846747329eaa26d535be0eb3d189fa69d812bfb8bfefd32f";
      };

      beamDeps = [];
    };

    jason = buildMix rec {
      name = "jason";
      version = "1.4.4";

      src = fetchHex {
        pkg = "jason";
        version = "${version}";
        sha256 = "c5eb0cab91f094599f94d55bc63409236a8ec69a21a67814529e8d5f6cc90b3b";
      };

      beamDeps = [ decimal ];
    };

    joken = buildMix rec {
      name = "joken";
      version = "2.6.2";

      src = fetchHex {
        pkg = "joken";
        version = "${version}";
        sha256 = "5134b5b0a6e37494e46dbf9e4dad53808e5e787904b7c73972651b51cce3d72b";
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

    libcluster = buildMix rec {
      name = "libcluster";
      version = "3.3.3";

      src = fetchHex {
        pkg = "libcluster";
        version = "${version}";
        sha256 = "7c0a2275a0bb83c07acd17dab3c3bfb4897b145106750eeccc62d302e3bdfee5";
      };

      beamDeps = [ jason ];
    };

    libcluster_consul = buildMix rec {
      name = "libcluster_consul";
      version = "1.3.0";

      src = fetchHex {
        pkg = "libcluster_consul";
        version = "${version}";
        sha256 = "fb63bc580f931a5af041c582a565df52bca3c8005c2ada13cce71647e674da25";
      };

      beamDeps = [ libcluster ];
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

    mint = buildMix rec {
      name = "mint";
      version = "1.7.1";

      src = fetchHex {
        pkg = "mint";
        version = "${version}";
        sha256 = "fceba0a4d0f24301ddee3024ae116df1c3f4bb7a563a731f45fdfeb9d39a231b";
      };

      beamDeps = [ castore hpax ];
    };

    mix_test_watch = buildMix rec {
      name = "mix_test_watch";
      version = "1.2.0";

      src = fetchHex {
        pkg = "mix_test_watch";
        version = "${version}";
        sha256 = "278dc955c20b3fb9a3168b5c2493c2e5cffad133548d307e0a50c7f2cfbf34f6";
      };

      beamDeps = [ file_system ];
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

    oidcc = buildMix rec {
      name = "oidcc";
      version = "3.2.6";

      src = fetchHex {
        pkg = "oidcc";
        version = "${version}";
        sha256 = "0530b902adce9117e797af41801b41e5e3d2a0288839bf69f2b54b19914fc522";
      };

      beamDeps = [ jose telemetry telemetry_registry ];
    };

    open_api_spex = buildMix rec {
      name = "open_api_spex";
      version = "3.21.2";

      src = fetchHex {
        pkg = "open_api_spex";
        version = "${version}";
        sha256 = "f42ae6ed668b895ebba3e02773cfb4b41050df26f803f2ef634c72a7687dc387";
      };

      beamDeps = [ decimal jason plug ];
    };

    opentelemetry = buildRebar3 rec {
      name = "opentelemetry";
      version = "1.5.0";

      src = fetchHex {
        pkg = "opentelemetry";
        version = "${version}";
        sha256 = "cdf4f51d17b592fc592b9a75f86a6f808c23044ba7cf7b9534debbcc5c23b0ee";
      };

      beamDeps = [ opentelemetry_api ];
    };

    opentelemetry_api = buildMix rec {
      name = "opentelemetry_api";
      version = "1.4.0";

      src = fetchHex {
        pkg = "opentelemetry_api";
        version = "${version}";
        sha256 = "3dfbbfaa2c2ed3121c5c483162836c4f9027def469c41578af5ef32589fcfc58";
      };

      beamDeps = [];
    };

    opentelemetry_bandit = buildMix rec {
      name = "opentelemetry_bandit";
      version = "0.2.0";

      src = fetchHex {
        pkg = "opentelemetry_bandit";
        version = "${version}";
        sha256 = "57e31355a860250c9203ae34f0bf0290a14b72ab02b154535e1b2512a0767bca";
      };

      beamDeps = [ nimble_options opentelemetry_api opentelemetry_semantic_conventions otel_http plug telemetry ];
    };

    opentelemetry_exporter = buildRebar3 rec {
      name = "opentelemetry_exporter";
      version = "1.8.0";

      src = fetchHex {
        pkg = "opentelemetry_exporter";
        version = "${version}";
        sha256 = "a1f9f271f8d3b02b81462a6bfef7075fd8457fdb06adff5d2537df5e2264d9af";
      };

      beamDeps = [ grpcbox opentelemetry opentelemetry_api tls_certificate_check ];
    };

    opentelemetry_phoenix = buildMix rec {
      name = "opentelemetry_phoenix";
      version = "2.0.1";

      src = fetchHex {
        pkg = "opentelemetry_phoenix";
        version = "${version}";
        sha256 = "a24fdccdfa6b890c8892c6366beab4a15a27ec0c692b0f77ec2a862e7b235f6e";
      };

      beamDeps = [ nimble_options opentelemetry_api opentelemetry_process_propagator opentelemetry_semantic_conventions opentelemetry_telemetry otel_http plug telemetry ];
    };

    opentelemetry_process_propagator = buildMix rec {
      name = "opentelemetry_process_propagator";
      version = "0.3.0";

      src = fetchHex {
        pkg = "opentelemetry_process_propagator";
        version = "${version}";
        sha256 = "7243cb6de1523c473cba5b1aefa3f85e1ff8cc75d08f367104c1e11919c8c029";
      };

      beamDeps = [ opentelemetry_api ];
    };

    opentelemetry_semantic_conventions = buildMix rec {
      name = "opentelemetry_semantic_conventions";
      version = "1.27.0";

      src = fetchHex {
        pkg = "opentelemetry_semantic_conventions";
        version = "${version}";
        sha256 = "9681ccaa24fd3d810b4461581717661fd85ff7019b082c2dff89c7d5b1fc2864";
      };

      beamDeps = [];
    };

    opentelemetry_telemetry = buildMix rec {
      name = "opentelemetry_telemetry";
      version = "1.1.2";

      src = fetchHex {
        pkg = "opentelemetry_telemetry";
        version = "${version}";
        sha256 = "641ab469deb181957ac6d59bce6e1321d5fe2a56df444fc9c19afcad623ab253";
      };

      beamDeps = [ opentelemetry_api telemetry ];
    };

    otel_http = buildRebar3 rec {
      name = "otel_http";
      version = "0.2.0";

      src = fetchHex {
        pkg = "otel_http";
        version = "${version}";
        sha256 = "f2beadf922c8cfeb0965488dd736c95cc6ea8b9efce89466b3904d317d7cc717";
      };

      beamDeps = [];
    };

    permit = buildMix rec {
      name = "permit";
      version = "0.2.1";

      src = fetchHex {
        pkg = "permit";
        version = "${version}";
        sha256 = "c38448dbc360c2d5717453fbc04c4ba4562efc63caad241f56bda22711a721a0";
      };

      beamDeps = [];
    };

    permit_ecto = buildMix rec {
      name = "permit_ecto";
      version = "0.2.3";

      src = fetchHex {
        pkg = "permit_ecto";
        version = "${version}";
        sha256 = "0b2b3a2b7a4e85b7f6f6278d61976f3e5b40484454f8fe58a90f79b4edc2ca1e";
      };

      beamDeps = [ ecto ecto_sql permit ];
    };

    phoenix = buildMix rec {
      name = "phoenix";
      version = "1.7.20";

      src = fetchHex {
        pkg = "phoenix";
        version = "${version}";
        sha256 = "6be2ab98302e8784a31829e0d50d8bdfa81a23cd912c395bafd8b8bfb5a086c2";
      };

      beamDeps = [ castore jason phoenix_pubsub phoenix_template plug plug_crypto telemetry websock_adapter ];
    };

    phoenix_ecto = buildMix rec {
      name = "phoenix_ecto";
      version = "4.6.3";

      src = fetchHex {
        pkg = "phoenix_ecto";
        version = "${version}";
        sha256 = "909502956916a657a197f94cc1206d9a65247538de8a5e186f7537c895d95764";
      };

      beamDeps = [ ecto phoenix_html plug postgrex ];
    };

    phoenix_html = buildMix rec {
      name = "phoenix_html";
      version = "4.2.1";

      src = fetchHex {
        pkg = "phoenix_html";
        version = "${version}";
        sha256 = "cff108100ae2715dd959ae8f2a8cef8e20b593f8dfd031c9cba92702cf23e053";
      };

      beamDeps = [];
    };

    phoenix_live_dashboard = buildMix rec {
      name = "phoenix_live_dashboard";
      version = "0.8.6";

      src = fetchHex {
        pkg = "phoenix_live_dashboard";
        version = "${version}";
        sha256 = "1681ab813ec26ca6915beb3414aa138f298e17721dc6a2bde9e6eb8a62360ff6";
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
      version = "1.0.4";

      src = fetchHex {
        pkg = "phoenix_live_view";
        version = "${version}";
        sha256 = "a9865316ddf8d78f382d63af278d20436b52d262b60239956817a61279514366";
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
      version = "0.20.0";

      src = fetchHex {
        pkg = "postgrex";
        version = "${version}";
        sha256 = "d36ef8b36f323d29505314f704e21a1a038e2dc387c6409ee0cd24144e187c0f";
      };

      beamDeps = [ db_connection decimal jason ];
    };

    req = buildMix rec {
      name = "req";
      version = "0.5.8";

      src = fetchHex {
        pkg = "req";
        version = "${version}";
        sha256 = "d7fc5898a566477e174f26887821a3c5082b243885520ee4b45555f5d53f40ef";
      };

      beamDeps = [ finch jason mime plug ];
    };

    shortuuid = buildMix rec {
      name = "shortuuid";
      version = "4.0.0";

      src = fetchHex {
        pkg = "shortuuid";
        version = "${version}";
        sha256 = "b28297cfeae47e5d1b8f786f4de43a81969b2a18ebeef673d1880387d6b81181";
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
      version = "0.2.4";

      src = fetchHex {
        pkg = "tailwind";
        version = "${version}";
        sha256 = "c6e4a82b8727bab593700c998a4d98cf3d8025678bfde059aed71d0000c3e463";
      };

      beamDeps = [ castore ];
    };

    telemetry = buildRebar3 rec {
      name = "telemetry";
      version = "1.3.0";

      src = fetchHex {
        pkg = "telemetry";
        version = "${version}";
        sha256 = "7015fc8919dbe63764f4b4b87a95b7c0996bd539e0d499be6ec9d7f3875b79e6";
      };

      beamDeps = [];
    };

    telemetry_metrics = buildMix rec {
      name = "telemetry_metrics";
      version = "1.1.0";

      src = fetchHex {
        pkg = "telemetry_metrics";
        version = "${version}";
        sha256 = "e7b79e8ddfde70adb6db8a6623d1778ec66401f366e9a8f5dd0955c56bc8ce67";
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

    telemetry_registry = buildMix rec {
      name = "telemetry_registry";
      version = "0.3.2";

      src = fetchHex {
        pkg = "telemetry_registry";
        version = "${version}";
        sha256 = "e7ed191eb1d115a3034af8e1e35e4e63d5348851d556646d46ca3d1b4e16bab9";
      };

      beamDeps = [ telemetry ];
    };

    thousand_island = buildMix rec {
      name = "thousand_island";
      version = "1.3.11";

      src = fetchHex {
        pkg = "thousand_island";
        version = "${version}";
        sha256 = "555c18c62027f45d9c80df389c3d01d86ba11014652c00be26e33b1b64e98d29";
      };

      beamDeps = [ telemetry ];
    };

    tls_certificate_check = buildRebar3 rec {
      name = "tls_certificate_check";
      version = "1.27.0";

      src = fetchHex {
        pkg = "tls_certificate_check";
        version = "${version}";
        sha256 = "51a5ad3dbd72d4694848965f3b5076e8b55d70eb8d5057fcddd536029ab8a23c";
      };

      beamDeps = [ ssl_verify_fun ];
    };

    typedstruct = buildMix rec {
      name = "typedstruct";
      version = "0.5.3";

      src = fetchHex {
        pkg = "typedstruct";
        version = "${version}";
        sha256 = "b53b8186701417c0b2782bf02a2db5524f879b8488f91d1d83b97d84c2943432";
      };

      beamDeps = [];
    };

    ueberauth = buildMix rec {
      name = "ueberauth";
      version = "0.10.8";

      src = fetchHex {
        pkg = "ueberauth";
        version = "${version}";
        sha256 = "f2d3172e52821375bccb8460e5fa5cb91cfd60b19b636b6e57e9759b6f8c10c1";
      };

      beamDeps = [ plug ];
    };

    ueberauth_oidcc = buildMix rec {
      name = "ueberauth_oidcc";
      version = "0.4.1";

      src = fetchHex {
        pkg = "ueberauth_oidcc";
        version = "${version}";
        sha256 = "ba4447d428df74d5cff8b6717e1249163649d946d4aefd22f7445a9979adab54";
      };

      beamDeps = [ oidcc plug ueberauth ];
    };

    uuidv7 = buildMix rec {
      name = "uuidv7";
      version = "1.0.0";

      src = fetchHex {
        pkg = "uuidv7";
        version = "${version}";
        sha256 = "0ecd337108456f7d8b1a9a54ef435443d3f8c10a5b685bd866ef9e396b444cbc";
      };

      beamDeps = [ ecto ];
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
      version = "0.5.8";

      src = fetchHex {
        pkg = "websock_adapter";
        version = "${version}";
        sha256 = "315b9a1865552212b5f35140ad194e67ce31af45bcee443d4ecb96b5fd3f3782";
      };

      beamDeps = [ bandit plug websock ];
    };
  };
in self

