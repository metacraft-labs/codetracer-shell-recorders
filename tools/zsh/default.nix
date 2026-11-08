# The `zsh` the zsh launcher, the zsh cargo suite and the CLI guards run,
# taken from this repository's own flake: the `zsh` package of its `nixpkgs`
# input, at the revision `flake.lock` pins. It is the same `zsh` the dev
# shell (`nix develop`) puts on PATH, so `repro test` and `just test` run the
# tests against one binary. Read by `zsh_tools.nim`.
{
  system ? builtins.currentSystem,
}:
let
  projectRoot = ../..;
  # Only flake.nix and flake.lock: the expression must not depend on (and
  # copy) the rest of the checkout.
  source = builtins.path {
    path = projectRoot;
    name = "shell-recorders-owning-flake-source";
    filter =
      path: type:
      path == toString projectRoot
      || (
        type == "regular"
        && builtins.elem (builtins.baseNameOf path) [
          "flake.nix"
          "flake.lock"
        ]
      );
  };
  owner = builtins.getFlake (builtins.unsafeDiscardStringContext ("path:" + toString source));
in
assert builtins.elem system [
  "x86_64-linux"
  "aarch64-linux"
  "x86_64-darwin"
  "aarch64-darwin"
];
# The dev shell takes zsh from `import nixpkgs { inherit system; }`, which
# evaluates to the same derivation as `legacyPackages`.
owner.inputs.nixpkgs.legacyPackages.${system}.zsh
