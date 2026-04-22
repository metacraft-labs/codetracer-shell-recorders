use std::fs;

use codetracer_trace_writer_nim::TraceEventsFileFormat;

use ct_shell_trace_writer::trace_bridge::TraceBridge;
use ct_shell_trace_writer::wire_protocol::parse_line;

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
