import json
import pathlib
import sys

import jsonschema

manifest = json.loads((pathlib.Path(sys.argv[1]) / "seed.json").read_text())
target = sys.argv[2]
schema = json.loads(pathlib.Path(sys.argv[3]).read_text())
nixos = json.loads((pathlib.Path(sys.argv[4]) / "seed.json").read_text())
home = json.loads((pathlib.Path(sys.argv[5]) / "seed.json").read_text())
system = sys.argv[6]

assert manifest == {
    "version": 1,
    "name": "example",
    "seed_type": "nixos",
    "artifact": target,
    "tags": {"system": system},
}
artifact_ready = pathlib.Path(manifest["artifact"]) / "ready"
assert artifact_ready.read_text().strip() == "ready"
assert nixos == {
    **manifest,
    "tags": {
        "system": system,
        "nixos_version": "26.11",
        "origin": "configuration",
    },
}
assert home == {
    **manifest,
    "seed_type": "home-manager",
    "tags": {
        "system": system,
        "username": "alice",
        "homeDirectory": "/home/alice",
        "release": "26.11",
    },
}
validator = jsonschema.Draft7Validator(schema)
validator.validate(manifest)
for version in (None, "1", 2):
    changed = dict(manifest)
    if version is None:
        del changed["version"]
    else:
        changed["version"] = version
    assert not validator.is_valid(changed), version
for change in (
    {"tags": {"bad": 3}},
    {"artifact": "relative/path"},
    {"seed_type": "unknown"},
):
    assert not validator.is_valid({**manifest, **change}), change
for missing in ("name", "seed_type", "artifact", "tags"):
    changed = dict(manifest)
    del changed[missing]
    assert not validator.is_valid(changed), missing
assert not validator.is_valid({**manifest, "sid": "server-issued"})
