use std::fs;
use std::io::{self, BufRead};
use std::path::PathBuf;
use std::process;

use ct_shell_trace_writer::trace_bridge::TraceBridge;
use ct_shell_trace_writer::wire_protocol;

// CTFS-only.  The shell recorders always write the canonical CTFS `.ct`
// container, with no output-format choice, like every CodeTracer recorder.
// The previous `--format binary|json` flag was removed in the 2026-05 convention
// compliance pass; conversion to JSON for debugging or golden snapshots is
// the job of `ct print` from `codetracer-trace-format-nim`.

fn print_usage() {
    eprintln!(
        "Usage: ct-shell-trace-writer --out-dir <path> [--program <name>] \
         [--args <arg1> <arg2> ...]"
    );
    eprintln!();
    eprintln!("Reads wire protocol events from stdin and writes a CodeTracer CTFS trace.");
    eprintln!();
    eprintln!("Options:");
    eprintln!("  --out-dir <path>      Directory where trace files are written (required)");
    eprintln!("  --program <name>      Override program name (normally from START event)");
    eprintln!("  --args <arg> ...      Script arguments; must come last: every token after");
    eprintln!("                        it is the script's, even one spelled like an option");
    eprintln!("  --version, -V         Print version and exit");
    eprintln!("  --help, -h            Print this help and exit");
    eprintln!();
    eprintln!("Output: CTFS-only.  Use `ct print` from codetracer-trace-format-nim");
    eprintln!("to convert the recorded `.ct` bundle to JSON / a follow stream.");
}

/// The settings of a recording run, parsed from the command line.
#[derive(Debug, PartialEq, Eq)]
struct CliArgs {
    output_dir: PathBuf,
    program: String,
    args: Vec<String>,
}

/// What the command line asks the writer to do.
#[derive(Debug, PartialEq, Eq)]
enum CliCommand {
    /// Read the event stream and write a trace.
    Run(CliArgs),
    /// Print the usage text and exit 0.
    Help,
    /// Print the version line and exit 0.
    Version,
}

/// Parse the writer's command line, without the program name (`argv[1..]`).
///
/// Options are read left to right. `--args` ends them: every token after it
/// is an argument of the recorded script, recorded as `$1`, `$2`, ... and
/// never interpreted, even when it spells one of the writer's own options.
/// The launchers rely on this, since they pass the script's arguments
/// verbatim after `--args` (spec `CLI/recorders/shell.md`, "Options": after
/// the script, everything is the script's arguments). `--help` / `-h` and
/// `--version` / `-V` are therefore honoured only among the options before
/// `--args`, and the first one seen wins; neither needs `--out-dir`.
fn parse_cli_args(argv: &[String]) -> Result<CliCommand, String> {
    let mut output_dir: Option<PathBuf> = None;
    let mut program = String::from("unknown");
    let mut extra_args: Vec<String> = Vec::new();

    let mut tokens = argv.iter();
    while let Some(token) = tokens.next() {
        match token.as_str() {
            "--version" | "-V" => return Ok(CliCommand::Version),
            "--help" | "-h" => return Ok(CliCommand::Help),
            "--out-dir" => {
                let value = tokens.next().ok_or("--out-dir requires a value")?;
                output_dir = Some(PathBuf::from(value));
            }
            "--program" => {
                program = tokens.next().ok_or("--program requires a value")?.clone();
            }
            "--args" => {
                // Everything that remains belongs to the script.
                extra_args.extend(tokens.by_ref().cloned());
            }
            // `--format` was removed in the 2026-05 convention compliance pass.
            // Recorders never branch on output format — CTFS is the sole
            // output.  We reject it loudly
            // rather than ignoring it so a stale launcher / caller surfaces
            // immediately instead of silently writing the wrong format.
            "--format" | "-f" => {
                return Err(
                    "--format is no longer supported (CTFS is the sole output format; \
                     use `ct print` to convert the recorded .ct bundle to JSON)"
                        .to_string(),
                );
            }
            other => {
                return Err(format!("unknown option: {other}"));
            }
        }
    }

    let output_dir = output_dir.ok_or("--out-dir is required")?;

    Ok(CliCommand::Run(CliArgs {
        output_dir,
        program,
        args: extra_args,
    }))
}

fn main() {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let cli = match parse_cli_args(&argv) {
        Ok(CliCommand::Run(c)) => c,
        Ok(CliCommand::Version) => {
            println!("ct-shell-trace-writer {}", env!("CARGO_PKG_VERSION"));
            return;
        }
        Ok(CliCommand::Help) => {
            print_usage();
            return;
        }
        Err(e) => {
            eprintln!("ct-shell-trace-writer: error: {e}");
            print_usage();
            process::exit(1);
        }
    };

    // Ensure the output directory exists
    if let Err(e) = fs::create_dir_all(&cli.output_dir) {
        eprintln!(
            "ct-shell-trace-writer: error: failed to create output directory '{}': {}",
            cli.output_dir.display(),
            e
        );
        process::exit(1);
    }

    let mut bridge = TraceBridge::new(&cli.output_dir, &cli.program, &cli.args);

    let stdin = io::stdin();
    let reader = stdin.lock();
    let mut got_exit = false;

    for (line_number, line_result) in reader.lines().enumerate() {
        let line = match line_result {
            Ok(l) => l,
            Err(e) => {
                eprintln!(
                    "ct-shell-trace-writer: error reading stdin at line {}: {}",
                    line_number + 1,
                    e
                );
                break;
            }
        };

        // Skip empty lines
        if line.trim().is_empty() {
            continue;
        }

        let event = match wire_protocol::parse_line(&line) {
            Ok(e) => e,
            Err(e) => {
                eprintln!(
                    "ct-shell-trace-writer: warning: line {}: parse error: {}",
                    line_number + 1,
                    e
                );
                continue;
            }
        };

        let is_exit = matches!(event, wire_protocol::WireEvent::Exit { .. });
        let is_start = matches!(event, wire_protocol::WireEvent::Start { .. });

        if let Err(e) = bridge.handle_event(event) {
            // A failed START means the trace container could not be created
            // (for instance `<out-dir>/<script>.ct` is a directory). Nothing
            // that follows can be recorded, so the run has failed: exit 1
            // rather than warn and go on to exit 0 without a trace
            // (`Recorder-CLI-Conventions.md` §6 "Exit Codes"; the
            // silent-incompleteness pattern of `CLI/ct/record.md`). Feeding
            // the remaining events to a writer that never started would only
            // produce discard warnings.
            if is_start {
                eprintln!(
                    "ct-shell-trace-writer: error: line {}: {}",
                    line_number + 1,
                    e
                );
                process::exit(1);
            }
            eprintln!(
                "ct-shell-trace-writer: warning: line {}: event handling error: {}",
                line_number + 1,
                e
            );
            continue;
        }

        if is_exit {
            got_exit = true;
            break;
        }
    }

    if !got_exit {
        eprintln!("ct-shell-trace-writer: warning: EOF reached without EXIT event");
    }

    // `finish` fails both when the trace could not be finalized and when no
    // trace was written at all (no START event arrived). Either way the run
    // wrote no usable trace, and exit 0 would claim it had: only the writer
    // knows, since a caller testing for `<script>.ct` cannot tell a fresh
    // container from one a previous run left in the same directory.
    if let Err(e) = bridge.finish() {
        eprintln!("ct-shell-trace-writer: error: {e}");
        process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn argv(tokens: &[&str]) -> Vec<String> {
        tokens.iter().map(|t| t.to_string()).collect()
    }

    fn run(output_dir: &str, program: &str, args: &[&str]) -> CliCommand {
        CliCommand::Run(CliArgs {
            output_dir: PathBuf::from(output_dir),
            program: program.to_string(),
            args: argv(args),
        })
    }

    #[test]
    fn help_and_version_flags_after_args_are_script_arguments() {
        for flag in ["-h", "--help", "-V", "--version"] {
            assert_eq!(
                parse_cli_args(&argv(&["--out-dir", "o", "--program", "p", "--args", flag])),
                Ok(run("o", "p", &[flag])),
                "`--args {flag}`"
            );
        }
    }

    #[test]
    fn every_token_after_args_is_kept_verbatim() {
        assert_eq!(
            parse_cli_args(&argv(&[
                "--out-dir",
                "o",
                "--args",
                "--out-dir",
                "x",
                "--format",
                "json",
                "--args",
                "",
                "-V",
                "unknown"
            ])),
            Ok(run(
                "o",
                "unknown",
                &[
                    "--out-dir",
                    "x",
                    "--format",
                    "json",
                    "--args",
                    "",
                    "-V",
                    "unknown"
                ]
            ))
        );
    }

    #[test]
    fn args_with_nothing_after_it_records_no_arguments() {
        assert_eq!(
            parse_cli_args(&argv(&["--out-dir", "o", "--args"])),
            Ok(run("o", "unknown", &[]))
        );
    }

    #[test]
    fn help_and_version_before_args_are_answered() {
        for (flag, expected) in [
            ("-h", CliCommand::Help),
            ("--help", CliCommand::Help),
            ("-V", CliCommand::Version),
            ("--version", CliCommand::Version),
        ] {
            assert_eq!(
                parse_cli_args(&argv(&[flag])),
                Ok(expected),
                "`{flag}` alone"
            );
        }
        assert_eq!(
            parse_cli_args(&argv(&["--out-dir", "o", "-V", "--args", "-h"])),
            Ok(CliCommand::Version)
        );
        assert_eq!(
            parse_cli_args(&argv(&["--program", "p", "--help", "--args", "x"])),
            Ok(CliCommand::Help)
        );
    }

    #[test]
    fn first_of_help_and_version_wins() {
        assert_eq!(
            parse_cli_args(&argv(&["--help", "--version"])),
            Ok(CliCommand::Help)
        );
        assert_eq!(
            parse_cli_args(&argv(&["-V", "-h"])),
            Ok(CliCommand::Version)
        );
    }

    #[test]
    fn options_parse_without_args() {
        assert_eq!(
            parse_cli_args(&argv(&["--program", "p", "--out-dir", "o"])),
            Ok(run("o", "p", &[]))
        );
    }

    #[test]
    fn errors_are_reported() {
        assert_eq!(
            parse_cli_args(&argv(&[])),
            Err("--out-dir is required".to_string())
        );
        assert_eq!(
            parse_cli_args(&argv(&["--args", "-h"])),
            Err("--out-dir is required".to_string())
        );
        assert_eq!(
            parse_cli_args(&argv(&["--out-dir"])),
            Err("--out-dir requires a value".to_string())
        );
        assert_eq!(
            parse_cli_args(&argv(&["--out-dir", "o", "--program"])),
            Err("--program requires a value".to_string())
        );
        assert_eq!(
            parse_cli_args(&argv(&["--out-dir", "o", "--bogus"])),
            Err("unknown option: --bogus".to_string())
        );
        for flag in ["--format", "-f"] {
            let err = parse_cli_args(&argv(&[flag, "json", "--out-dir", "o"]))
                .expect_err("--format must be rejected");
            assert!(err.contains("--format is no longer supported"), "{err}");
        }
    }

    /// An option that takes a value consumes the next token whatever it is,
    /// as before: `--program --help` names a program called `--help`.
    #[test]
    fn option_values_are_not_reinterpreted() {
        assert_eq!(
            parse_cli_args(&argv(&["--out-dir", "o", "--program", "--help"])),
            Ok(run("o", "--help", &[]))
        );
    }
}
