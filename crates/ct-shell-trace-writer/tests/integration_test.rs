use std::fs;

use codetracer_trace_types::ValueRecord;
use codetracer_trace_writer_nim::NimTraceReaderHandle;

use ct_shell_trace_writer::trace_bridge::TraceBridge;
use ct_shell_trace_writer::wire_protocol::parse_line;

fn bytes_from_json_array(value: &serde_json::Value) -> Vec<u8> {
    value
        .as_array()
        .unwrap_or_else(|| panic!("expected byte array JSON, got {value:#}"))
        .iter()
        .map(|byte| {
            byte.as_u64()
                .unwrap_or_else(|| panic!("expected byte value, got {byte:#}")) as u8
        })
        .collect()
}

fn decode_value_record(value: &serde_json::Value) -> ValueRecord {
    let bytes = bytes_from_json_array(value);
    cbor4ii::serde::from_slice(&bytes)
        .unwrap_or_else(|e| panic!("failed to decode ValueRecord from {bytes:?}: {e}"))
}

fn value_as_string(value: &ValueRecord) -> Option<&str> {
    match value {
        ValueRecord::String { text, .. } => Some(text),
        _ => None,
    }
}

fn value_as_i64(value: &ValueRecord) -> Option<i64> {
    match value {
        ValueRecord::Int { i, .. } => Some(*i),
        _ => None,
    }
}

fn assert_call_args(
    reader: &NimTraceReaderHandle,
    calls: &[serde_json::Value],
    expected: &[(&str, ExpectedArgValue<'_>)],
) {
    let found = calls.iter().any(|call| {
        let Some(args) = call["args"].as_array() else {
            return false;
        };
        if args.len() != expected.len() {
            return false;
        }

        args.iter()
            .zip(expected.iter())
            .all(|(arg, (name, value))| {
                let Some(varname_id) = arg["varname_id"].as_u64() else {
                    return false;
                };
                let Ok(actual_name) = reader.varname(varname_id) else {
                    return false;
                };
                if actual_name != *name {
                    return false;
                }

                let actual_value = decode_value_record(&arg["value"]);
                match value {
                    ExpectedArgValue::String(expected) => {
                        value_as_string(&actual_value) == Some(*expected)
                    }
                    ExpectedArgValue::Int(expected) => {
                        value_as_i64(&actual_value) == Some(*expected)
                    }
                }
            })
    });

    assert!(
        found,
        "expected a call with args {expected:?}; calls={calls:#?}"
    );
}

#[derive(Debug)]
enum ExpectedArgValue<'a> {
    String(&'a str),
    Int(i64),
}

/// Feed a complete event stream through the wire protocol parser and trace
/// bridge, then verify that trace files are created and non-empty.
///
/// This test exercises the full pipeline: wire protocol parsing -> TraceBridge
/// -> NimTraceWriter -> trace files on disk.
///
/// The Nim trace writer backend always produces a binary `.ct` container file
/// (CTFS format), regardless of the requested format. The container file is
/// named after the program basename (e.g. `test_script.ct` for a program
/// `/tmp/test_script.sh`). The paths passed to `begin_writing_trace_*` are
/// used internally by the Nim library but the final output is the `.ct` file
/// in the output directory.
#[test]
fn test_full_event_stream_to_trace() {
    let input = r#"START program=/tmp/test_script.sh shell=bash shell_version=5.2.0
PATH file=/tmp/test_script.sh
FUNC name=greet file=/tmp/test_script.sh line=3
STEP file=/tmp/test_script.sh line=1
VAR name=greeting value="hello world" type=s
STEP file=/tmp/test_script.sh line=2
VAR name=count value=42 type=i
WRITE content="hello world"
STEP file=/tmp/test_script.sh line=3
CALL name=greet
STEP file=/tmp/test_script.sh line=4
VAR name=x value=3.14 type=F
ERROR cmd="false" status=1
RETURN status=0
STEP file=/tmp/test_script.sh line=5
EXIT code=0"#;

    let tmp_dir = tempfile::tempdir().expect("failed to create temp dir");
    let output_dir = tmp_dir.path();

    // CTFS-only — the Nim backend always produces .ct files.  The
    // `--format` dispatch was removed from TraceBridge in the 2026-05
    // convention compliance pass (Recorder-CLI-Conventions §4).
    let mut bridge = TraceBridge::new(output_dir, "/tmp/test_script.sh", &[]);

    for line_str in input.lines() {
        let line_str = line_str.trim();
        if line_str.is_empty() {
            continue;
        }

        let event =
            parse_line(line_str).unwrap_or_else(|e| panic!("failed to parse '{line_str}': {e}"));
        bridge
            .handle_event(event)
            .unwrap_or_else(|e| panic!("failed to handle event from '{line_str}': {e}"));
    }

    // Finalize trace files
    bridge.finish().expect("finish() should succeed");

    // The Nim writer produces a .ct container named after the program basename.
    let ct_path = output_dir.join("test_script.ct");

    assert!(
        ct_path.exists(),
        "test_script.ct should exist at {}. Files in output dir: {:?}",
        ct_path.display(),
        fs::read_dir(output_dir)
            .map(|rd| rd
                .filter_map(|e| e.ok().map(|e| e.file_name()))
                .collect::<Vec<_>>())
            .unwrap_or_default()
    );

    let ct_size = fs::metadata(&ct_path).unwrap().len();
    assert!(
        ct_size > 0,
        "test_script.ct should be non-empty, got {} bytes",
        ct_size
    );

    // Sanity check: the file should be reasonably sized (at least a few KB for
    // the events, metadata, and paths streams in the container).
    assert!(
        ct_size >= 1024,
        "test_script.ct should be at least 1KB (contains multiple streams), got {} bytes",
        ct_size
    );
}

/// Verify that ARG events stage call arguments, drain onto the next CALL
/// event, and survive a read-side CTFS round-trip.  This pins both the
/// script-level `<toplevel>` argv path and a shell-function call argv path.
#[test]
fn test_arg_events_stage_call_args() {
    let input = r#"START program=/tmp/argy.sh shell=bash shell_version=5.2.0
PATH file=/tmp/argy.sh
FUNC name=greet file=/tmp/argy.sh line=3
STEP file=/tmp/argy.sh line=3
ARG name=$1 value="hello world" type=s
ARG name=$2 value=42 type=i
CALL name=greet
STEP file=/tmp/argy.sh line=4
RETURN status=0
EXIT code=0"#;

    let tmp_dir = tempfile::tempdir().expect("failed to create temp dir");
    let output_dir = tmp_dir.path();

    // Pass script-level argv through `args` to confirm the implicit
    // top-level call also receives them.
    let mut bridge = TraceBridge::new(
        output_dir,
        "/tmp/argy.sh",
        &["one".to_string(), "two".to_string()],
    );

    for line_str in input.lines() {
        let line_str = line_str.trim();
        if line_str.is_empty() {
            continue;
        }
        let event =
            parse_line(line_str).unwrap_or_else(|e| panic!("failed to parse '{line_str}': {e}"));
        bridge
            .handle_event(event)
            .unwrap_or_else(|e| panic!("failed to handle event from '{line_str}': {e}"));
    }
    bridge.finish().expect("finish() should succeed");

    let ct_path = output_dir.join("argy.ct");
    assert!(
        ct_path.exists(),
        "argy.ct should exist; files: {:?}",
        fs::read_dir(output_dir)
            .map(|rd| rd
                .filter_map(|e| e.ok().map(|e| e.file_name()))
                .collect::<Vec<_>>())
            .unwrap_or_default()
    );

    let reader = NimTraceReaderHandle::open(&ct_path.to_string_lossy())
        .unwrap_or_else(|e| panic!("failed to open Nim CTFS reader for {ct_path:?}: {e}"));
    let calls: Vec<serde_json::Value> = (0..reader.call_count())
        .map(|key| {
            let json = reader.call_json(key).expect("read call JSON");
            serde_json::from_str(&json).unwrap_or_else(|e| panic!("invalid call JSON: {e}: {json}"))
        })
        .collect();

    assert!(
        calls.len() >= 2,
        "expected at least <toplevel> and greet calls, got {calls:#?}"
    );
    assert_call_args(
        &reader,
        &calls,
        &[
            ("$1", ExpectedArgValue::String("one")),
            ("$2", ExpectedArgValue::String("two")),
        ],
    );
    assert_call_args(
        &reader,
        &calls,
        &[
            ("$1", ExpectedArgValue::String("hello world")),
            ("$2", ExpectedArgValue::Int(42)),
        ],
    );
}

// ---------------------------------------------------------------------------
// CLI convention compliance — see Recorder-CLI-Conventions.md §4.
//
// CTFS is the recorder's sole on-disk output; the previous `--format`
// dispatch was removed in 2026-05.  The binary must now reject every
// `--format`/`-f` invocation with a non-zero exit so a stale launcher
// or external caller surfaces immediately rather than silently writing
// the wrong format.
// ---------------------------------------------------------------------------

fn locate_trace_writer_binary() -> std::path::PathBuf {
    let manifest_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    // The binary lives at <repo>/target/{debug,release}/ct-shell-trace-writer.
    // We prefer the debug build because cargo test will have just produced it.
    let workspace_root = manifest_dir
        .parent()
        .expect("crates/ parent")
        .parent()
        .expect("repo root");
    for profile in ["debug", "release"] {
        let candidate = workspace_root
            .join("target")
            .join(profile)
            .join("ct-shell-trace-writer");
        if candidate.exists() {
            return candidate;
        }
    }
    // Fall back to the bin specified by cargo for the integration target.
    let env_bin = env!("CARGO_BIN_EXE_ct-shell-trace-writer");
    std::path::PathBuf::from(env_bin)
}

#[test]
fn test_cli_rejects_format_flag() {
    let bin = locate_trace_writer_binary();
    for flag in ["--format", "-f"] {
        let output = std::process::Command::new(&bin)
            .args([flag, "json", "--out-dir", "/tmp"])
            .output()
            .unwrap_or_else(|e| panic!("failed to execute {bin:?}: {e}"));
        assert!(
            !output.status.success(),
            "ct-shell-trace-writer must reject `{flag} json` (exit non-zero); \
             got status {:?}, stderr={}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        );
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains("--format"),
            "rejection message should mention --format; stderr={stderr}"
        );
    }
}

#[test]
fn test_cli_help_omits_format_and_mentions_ct_print() {
    let bin = locate_trace_writer_binary();
    let output = std::process::Command::new(&bin)
        .arg("--help")
        .output()
        .unwrap_or_else(|e| panic!("failed to execute {bin:?}: {e}"));
    assert!(output.status.success(), "--help should exit zero");
    // ct-shell-trace-writer prints `--help` to stderr (it's intended for
    // the recorder operators, not piped consumers).  Concatenate both
    // streams so we don't depend on which one carries the text.
    let combined = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        !combined.contains("--format"),
        "--help must NOT mention --format; got: {combined}"
    );
    assert!(
        combined.contains("--out-dir"),
        "--help missing --out-dir; got: {combined}"
    );
    assert!(
        combined.contains("--version"),
        "--help missing --version; got: {combined}"
    );
    assert!(
        combined.contains("ct print"),
        "--help missing 'ct print'; got: {combined}"
    );
}

#[test]
fn test_cli_version_prints_canonical_line() {
    let bin = locate_trace_writer_binary();
    let output = std::process::Command::new(&bin)
        .arg("--version")
        .output()
        .unwrap_or_else(|e| panic!("failed to execute {bin:?}: {e}"));
    assert!(output.status.success(), "--version should exit zero");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.starts_with("ct-shell-trace-writer "),
        "--version line should start with the binary name; got: {stdout}"
    );
}
