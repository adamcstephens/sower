{
  beamPackages,
  callPackages,
  lib,
  version,
}:

beamPackages.mixRelease {
  pname = "sower-agent";
  inherit version;

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../agent
      ../../client-elixir
    ];
  };

  preConfigure = ''
    cd agent
  '';

  mixNixDeps = callPackages ../../agent/deps.nix {
    inherit lib beamPackages;
    overrides = self: prev: {
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
    };
  };

  postInstall = ''
    mv $out/bin/sower_agent $out/bin/sower-agent
  '';

  # Disable checks for now
  doCheck = false;

  meta.mainProgram = "sower-agent";
}
