{
  beamPackages,
  callPackages,
  lib,
  rustPlatform,
}:

callPackages ./deps.nix {
  inherit lib beamPackages;
  overrides = self: prev: {
    argon2id_elixir = prev.argon2id_elixir.override (
      old:
      let
        inherit (old) version;

        native = rustPlatform.buildRustPackage {
          pname = "argon2";
          version = version;
          src = "${old.src}/native/argon2";
          cargoHash = "sha256-VOtvGETrErqX3ph1Hk73RcaFcvgXiwQs70kHxwqC5SY=";
        };
      in
      {
        preBuild = ''
          substituteInPlace lib/argon2_elixir/native.ex --replace-fail 'crate: "argon2"' 'crate: "argon2", skip_compilation?: true'

          mkdir -p priv/native/
          cp ${native}/lib/libargon2.so priv/native/
        '';
      }
    );

    # certifi = prev.certifi.override (_: {
    #   env.DEBUG = "1";
    #   env.DIAGNOSTIC = "1";
    # });

    esbuild = prev.esbuild.override (old: {
      patches = [ ./esbuild-loadpaths.patch ];
    });

    typedstruct = prev.typedstruct.override (old: {
      preConfigure = ''
        substituteInPlace mix.exs --replace-fail 'version = vsn()' 'version = "${old.version}"'
      '';
    });

    tailwind = prev.tailwind.override (old: {
      patches = [ ./tailwind-loadpaths.patch ];
    });
  };
}
