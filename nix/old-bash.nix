# Plain GNU Bash of an old release, built only so the tests can run the
# recorders under the oldest Bash the specification supports (and under one
# it does not). These shells are test fixtures: they carry none of the
# distribution patches, including the 2014 "Shellshock" fixes, and must never
# be put on the dev shell's PATH or used to run anything else.
#
# Old Bash sources predate C99/C23 defaults and today's stricter GCC
# diagnostics, so they are compiled as gnu89 with the warnings that recent
# compilers promote to errors turned back into warnings. `format` hardening
# is disabled because these releases pass non-literal format strings.
# Only tested on Linux (x86_64); the dev shell does not build them on Darwin.
{
  stdenv,
  fetchurl,
  version,
  hash,
}:
stdenv.mkDerivation {
  pname = "bash";
  inherit version;
  src = fetchurl {
    url = "mirror://gnu/bash/bash-${version}.tar.gz";
    inherit hash;
  };
  configureFlags = [
    "--without-bash-malloc"
    "--disable-nls"
  ];
  env.NIX_CFLAGS_COMPILE = toString [
    "-std=gnu89"
    "-Wno-implicit-function-declaration"
    "-Wno-implicit-int"
    "-Wno-incompatible-pointer-types"
    "-Wno-int-conversion"
  ];
  # The old Makefiles are not reliably parallel-safe.
  enableParallelBuilding = false;
  hardeningDisable = [ "format" ];
  doCheck = false;
}
