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
      castore = buildMix rec {
        name = "castore";
        version = "1.0.5";

        src = fetchHex {
          pkg = "castore";
          version = "${version}";
          sha256 = "8d7c597c3e4a64c395980882d4bca3cebb8d74197c590dc272cfd3b6a6310578";
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

      jason = buildMix rec {
        name = "jason";
        version = "1.4.1";

        src = fetchHex {
          pkg = "jason";
          version = "${version}";
          sha256 = "fbb01ecdfd565b56261302f7e1fcc27c4fb8f32d56eab74db621fc154604a7a1";
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

      mint = buildMix rec {
        name = "mint";
        version = "1.5.2";

        src = fetchHex {
          pkg = "mint";
          version = "${version}";
          sha256 = "d77d9e9ce4eb35941907f1d3df38d8f750c357865353e21d335bdcdf6d892a02";
        };

        beamDeps = [
          castore
          hpax
        ];
      };

      nimble_options = buildMix rec {
        name = "nimble_options";
        version = "1.1.0";

        src = fetchHex {
          pkg = "nimble_options";
          version = "${version}";
          sha256 = "8bbbb3941af3ca9acc7835f5655ea062111c9c27bcac53e004460dfd19008a99";
        };

        beamDeps = [ ];
      };

      nimble_ownership = buildMix rec {
        name = "nimble_ownership";
        version = "0.2.1";

        src = fetchHex {
          pkg = "nimble_ownership";
          version = "${version}";
          sha256 = "bf38d2ef4fb990521a4ecf112843063c1f58a5c602484af4c7977324042badee";
        };

        beamDeps = [ ];
      };

      nimble_pool = buildMix rec {
        name = "nimble_pool";
        version = "1.0.0";

        src = fetchHex {
          pkg = "nimble_pool";
          version = "${version}";
          sha256 = "80be3b882d2d351882256087078e1b1952a28bf98d0a287be87e4a24a710b67a";
        };

        beamDeps = [ ];
      };

      req = buildMix rec {
        name = "req";
        version = "0.4.11";

        src = fetchHex {
          pkg = "req";
          version = "${version}";
          sha256 = "bbf4f2393c649fa4146a3b8470e2a7e8c9b23e4100a16c75f5e7d1d3d33144f3";
        };

        beamDeps = [
          finch
          jason
          mime
          nimble_ownership
        ];
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
    };
in
self
