use std::fs;
use std::io::{self, BufRead};
use std::path::PathBuf;
use std::process;

use codetracer_trace_writer::TraceEventsFileFormat;

use ct_shell_trace_writer::trace_bridge::TraceBridge;
use ct_shell_trace_writer::wire_protocol;

fn print_usage() {
    eprintln!(
        "Usage: ct-shell-trace-writer --out-dir <path> [--format binary|json] \
         [--program <name>] [--args <arg1> <arg2> ...]"
    );
    eprintln!();
    eprintln!("Reads wire protocol events from stdin and writes a CodeTracer trace.");
    eprintln!();
    eprintln!("Options:");
    eprintln!("  --out-dir <path>   Directory where trace files are written (required)");
    eprintln!("  --format <fmt>        Output format: binary (default) or json");
    eprintln!("  --program <name>      Override program name (normally from START event)");
    eprintln!("  --args <arg> ...      Program arguments for metadata");
    eprintln!("  --version             Print version and exit");
    eprintln!("  --help                Print this help and exit");
}

struct CliArgs {
    output_dir: PathBuf,
    format: TraceEventsFileFormat,
    program: String,
    args: Vec<String>,
}

fn parse_cli_args() -> Result<CliArgs, String> {
    let args: Vec<String> = std::env::args().collect();

    if args.iter().any(|a| a == "--version") {
        println!("{}", env!("CARGO_PKG_VERSION"));
        process::exit(0);
    }

    if args.iter().any(|a| a == "--help" || a == "-h") {
        print_usage();
        process::exit(0);
    }

    let mut output_dir: Option<PathBuf> = None;
    let mut format = TraceEventsFileFormat::Binary;
    let mut program = String::from("unknown");
    let mut extra_args: Vec<String> = Vec::new();

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--out-dir" => {
                i += 1;
                if i >= args.len() {
                    return Err("--out-dir requires a value".to_string());
                }
                output_dir = Some(PathBuf::from(&args[i]));
            }
            "--format" => {
                i += 1;
                if i >= args.len() {
                    return Err("--format requires a value".to_string());
                }
                format = match args[i].as_str() {
                    "binary" => TraceEventsFileFormat::Binary,
                    "json" => TraceEventsFileFormat::Json,
                    other => return Err(format!("unknown format: {other}")),
                };
            }
            "--program" => {
                i += 1;
                if i >= args.len() {
                    return Err("--program requires a value".to_string());
                }
                program = args[i].clone();
            }
            "--args" => {
                i += 1;
                // Consume all remaining args
                while i < args.len() {
                    extra_args.push(args[i].clone());
                    i += 1;
                }
                break;
            }
            other => {
                return Err(format!("unknown option: {other}"));
            }
        }
        i += 1;
    }

    let output_dir = output_dir.ok_or("--out-dir is required")?;

    Ok(CliArgs {
        output_dir,
        format,
        program,
        args: extra_args,
    })
}

fn main() {
    let cli = match parse_cli_args() {
        Ok(c) => c,
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

    let mut bridge = TraceBridge::new(&cli.output_dir, cli.format, &cli.program, &cli.args);

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

        if let Err(e) = bridge.handle_event(event) {
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

    if let Err(e) = bridge.finish() {
        eprintln!("ct-shell-trace-writer: error: failed to finalize trace: {e}");
        process::exit(1);
    }
}
