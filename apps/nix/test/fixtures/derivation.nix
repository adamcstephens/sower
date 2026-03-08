# Test fixture: a derivation (leaf node)
{ }:
derivation {
  name = "test-derivation";
  system = builtins.currentSystem;
  builder = "/bin/sh";
  args = [
    "-c"
    "echo hello > $out"
  ];
}
