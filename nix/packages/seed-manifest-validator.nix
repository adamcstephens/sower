{ pkgs }:
pkgs.writers.writePython3Bin "validate-seed-manifest"
  {
    libraries = [ pkgs.python3Packages.jsonschema ];
  }
  ''
    import json
    import pathlib
    import sys

    import jsonschema

    schema = json.loads(pathlib.Path(sys.argv[1]).read_text())
    jsonschema.Draft7Validator.check_schema(schema)
    manifest = json.loads(pathlib.Path(sys.argv[2]).read_text())
    jsonschema.validate(manifest, schema)
  ''
