## ``zsh``, as a tool the test edges can name.
##
## The zsh launcher (``zsh-recorder/``) is a zsh program: the zsh cargo
## suite, the zsh CLI guard and the CLI-convention guard all run it under
## ``zsh``. An edge sees only the tools declared in ``uses:`` and attached to
## it, never the caller's ``PATH``. reprobuild's stdlib has no ``zsh``
## package, so without this module ``uses: "zsh"`` resolves only against the
## caller's ``PATH``, and a host without one (a CI runner with a bare
## ``PATH``) stops at tool resolution. This repository therefore declares
## the zsh it already depends on:
##
## * Linux / macOS: the ``zsh`` package of this flake's ``nixpkgs`` input
##   (``tools/zsh/default.nix``), the same derivation the dev shell
##   provides. Its lock identity hashes the expression and the flake files,
##   so a ``flake.lock`` bump re-provisions it.
## * Windows: none. There is no native zsh, and ``repro.nim`` neither
##   declares zsh nor attaches it there.
import blake3
import repro_project_dsl

const zshExpressionSources = staticRead("tools/zsh/default.nix") & "\0" &
  staticRead("flake.nix") & "\0" & staticRead("flake.lock")
let zshExpressionIdentity =
  blake3.toHex(blake3.digest(zshExpressionSources))

package zsh:
  provisioning:
    nixPackage "zsh", executablePath = "bin/zsh",
      expressionFile = "tools/zsh/default.nix",
      lockIdentity = "owning-shell-recorders-flake-zsh:" & zshExpressionIdentity
