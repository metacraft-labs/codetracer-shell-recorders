use std::fs;

use codetracer_trace_types::ValueRecord;
use codetracer_trace_writer_nim::{NimTraceReaderHandle, TraceEventsFileFormat};

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

    // Use the default CTFS format — the Nim backend always produces .ct files.
    let format = TraceEventsFileFormat::Ctfs;
    let mut bridge = TraceBridge::new(output_dir, format, "/tmp/test_script.sh", &[]);

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
    let format = TraceEventsFileFormat::Ctfs;
    let mut bridge = TraceBridge::new(
        output_dir,
        format,
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
