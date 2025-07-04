{
  beamPackages,
  callPackages,
  lib,
  rustPlatform,
}:

callPackages ./deps.nix {
  inherit lib beamPackages;
  overrides = self: prev: {
    argon2 = prev.argon2.override (
      old:
      let
        version = "1.2.0"; # or old.version

        native = rustPlatform.buildRustPackage {
          pname = "argon2";
          version = version;
          src = "${old.src}/native";
          cargoHash = "sha256-D7mONUH6f/RmFwfx51sLr6XWlIELNTFPvFm9TrbEMl4=";
          useFetchCargoVendor = true;
        };
      in
      {
        # pre-build the make target
        preBuild = ''
          mkdir -p priv/
          substituteInPlace native/Makefile --replace-fail '$(PROJECT)' 'argon2'
          cp ${native}/lib/libargon2.so priv/argon2.so
        '';

        # move native into expected location
        # postInstall = ''
        #   mv $out/lib/erlang/lib/argon2/priv/argon2.so $out/lib/erlang/lib/argon2/priv/argon2.so
        # '';
      }
    );

    esbuild = prev.esbuild.override (old: {
      patches = [ ./esbuild-loadpaths.patch ];
    });

    typedstruct = prev.typedstruct.override (old: {
      preConfigure = ''
        substituteInPlace mix.exs --replace-fail 'version = vsn()' 'version = "${old.version}"'
      '';
    });

    typed_struct_ecto_changeset = prev.typed_struct_ecto_changeset.override (old: {
      beamDeps = [ self.typedstruct ];

      preConfigure = ''
        substituteInPlace mix.exs --replace-fail \
          '{:typed_struct, "~> 0.3.0", only: [:dev, :test], runtime: false}' \
          '{:typedstruct, "${self.typedstruct.version}"}'
      '';
    });

    tailwind = prev.tailwind.override (old: {
      patches = [ ./tailwind-loadpaths.patch ];
    });
  };
}
