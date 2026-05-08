# codetracer-zsh-recorder

A Zsh trace recorder that captures step-by-step execution and emits the
canonical CodeTracer CTFS `.ct` container.  Architecturally identical
to the Bash recorder; see `../bash-recorder/README.md` for the wire
protocol and pipe layout — only the trap-handler implementation differs
(zsh's DEBUG/ZERR/RETURN traps + `funcstack`/`funcsourcetrace` instead
of bash's `BASH_LINENO[0]` + `FUNCNAME`).

## Usage

```zsh
codetracer-zsh-recorder --out-dir ./traces -- script.zsh arg1 arg2
codetracer-zsh-recorder --help
codetracer-zsh-recorder --version
```

The recorder follows `codetracer-specs/Recorder-CLI-Conventions.md`:

| Convention §        | Compliance                                                                     |
| ------------------- | ------------------------------------------------------------------------------ |
| §1 Binary name      | `codetracer-zsh-recorder` (wrapper script delegates to `launcher.zsh`)         |
| §3 `--out-dir`/`-o` | Required (or `CODETRACER_ZSH_RECORDER_OUT_DIR`)                                |
| §3 `--help`/`-h`    | Prints binary name + version, options, env vars, and `ct print` instructions   |
| §3 `--version`/`-V` | Prints `codetracer-zsh-recorder <version>` from the top-level `VERSION` file   |
| §4 Output format    | CTFS-only — no `--format` flag; convert via `ct print` from the trace-format-nim repo |
| §5 Env vars         | `CODETRACER_ZSH_RECORDER_OUT_DIR`, `CODETRACER_ZSH_RECORDER_DISABLED`          |

## Output

```
<out-dir>/
  <script>.ct                  # CTFS container
  trace_metadata.json
  trace_paths.json
  symbols.json
  trace_db_metadata.json       # language=zsh, zsh_version=...
  files/
```

Use `ct print --json|--summary|--follow <out-dir>/<script>.ct` from
`codetracer-trace-format-nim` to inspect the bundle.

## Environment variables

| Variable                           | Effect                                                                   |
| ---------------------------------- | ------------------------------------------------------------------------ |
| `CODETRACER_ZSH_RECORDER_OUT_DIR`  | Default value for `--out-dir`.                                           |
| `CODETRACER_ZSH_RECORDER_DISABLED` | When set to `1`/`true`/`yes`, exec the target script directly with no recording. |
