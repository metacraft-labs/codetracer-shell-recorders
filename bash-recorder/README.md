# codetracer-bash-recorder

A Bash trace recorder that captures step-by-step execution and emits the
canonical CodeTracer CTFS `.ct` container.

## Architecture

* `launcher.sh` — CLI entry point.  Resolves the target script, sets up
  the FD 3 FIFO between the recorder and the trace writer, and forwards
  argv as `--args ...` so the implicit `<toplevel>` call records the
  script's positional parameters.  Wrapped by `codetracer-bash-recorder`
  for binary-name compliance with `Recorder-CLI-Conventions.md` §1.
* `recorder.sh` — DEBUG/ERR/RETURN-trap-based instrumentation layer.
  Emits the line-oriented wire protocol consumed by
  `crates/ct-shell-trace-writer/`.

## Usage

```bash
codetracer-bash-recorder --out-dir ./traces -- script.sh arg1 arg2
codetracer-bash-recorder --help
codetracer-bash-recorder --version
```

The recorder follows `codetracer-specs/Recorder-CLI-Conventions.md`:

| Convention §        | Compliance                                                                     |
| ------------------- | ------------------------------------------------------------------------------ |
| §1 Binary name      | `codetracer-bash-recorder` (wrapper script delegates to `launcher.sh`)         |
| §3 `--out-dir`/`-o` | Required (or `CODETRACER_BASH_RECORDER_OUT_DIR`)                               |
| §3 `--help`/`-h`    | Prints binary name + version, options, env vars, and `ct print` instructions   |
| §3 `--version`/`-V` | Prints `codetracer-bash-recorder <version>` from the top-level `VERSION` file  |
| §4 Output format    | CTFS-only — no `--format` flag; convert via `ct print` from the trace-format-nim repo |
| §5 Env vars         | `CODETRACER_BASH_RECORDER_OUT_DIR`, `CODETRACER_BASH_RECORDER_DISABLED`        |

## Output

The trace bundle written to `--out-dir` contains:

```
<out-dir>/
  <script>.ct                  # CTFS container with the multi-stream event log
  trace_metadata.json          # program + args (sidecar; same data inside .ct)
  trace_paths.json             # registered source file paths
  symbols.json                 # function names for symbol search
  trace_db_metadata.json       # language-specific metadata (bash version, recorder, ...)
  files/                       # copies of every source file referenced by the trace
```

To inspect the bundle:

```bash
ct print --json   <out-dir>/<script>.ct   # full JSON dump
ct print --summary <out-dir>/<script>.ct  # high-level overview
ct print --follow <out-dir>/<script>.ct   # human-readable event stream
```

`ct print` ships with `codetracer-trace-format-nim`; the recorder
itself is hard-pinned to CTFS to keep the toolchain's on-disk
representation canonical.

## Environment variables

| Variable                            | Effect                                                                  |
| ----------------------------------- | ----------------------------------------------------------------------- |
| `CODETRACER_BASH_RECORDER_OUT_DIR`  | Default value for `--out-dir`.  CLI flag wins.                          |
| `CODETRACER_BASH_RECORDER_DISABLED` | When set to `1`/`true`/`yes`, exec the target script directly with no recording.  Useful for short-circuiting the recorder in CI when the binary is on PATH but tracing is undesired. |
