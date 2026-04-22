use std::fs;

use codetracer_trace_writer_nim::TraceEventsFileFormat;

use ct_shell_trace_writer::wire_protocol::parse_line;

use codetracer_trace_types::{EventLogKind, Line, TypeKind, ValueRecord};
use codetracer_trace_writer_nim::non_streaming_trace_writer::NonStreamingTraceWriter;
use codetracer_trace_writer_nim::trace_writer::TraceWriter;

/// Feed a complete event stream through the wire protocol parser and trace
/// writer, then verify that trace files are created and non-empty.
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

    // Set up writer (mimicking TraceBridge logic)
    let mut writer = NonStreamingTraceWriter::new("/tmp/test_script.sh", &[]);

    let events_path = output_dir.join("trace.json");
    let metadata_path = output_dir.join("trace_metadata.json");
    let paths_path = output_dir.join("trace_paths.json");

    // We need to use the JSON format for easy verification
    writer.set_format(TraceEventsFileFormat::Json);
    TraceWriter::begin_writing_trace_events(&mut writer, &events_path).unwrap();
    TraceWriter::begin_writing_trace_metadata(&mut writer, &metadata_path).unwrap();
    TraceWriter::begin_writing_trace_paths(&mut writer, &paths_path).unwrap();

    let mut started = false;
    let mut current_file: Option<String> = None;
    let mut current_line: i64 = 1;

    for line_str in input.lines() {
        let line_str = line_str.trim();
        if line_str.is_empty() {
            continue;
        }

        let event =
            parse_line(line_str).unwrap_or_else(|e| panic!("failed to parse '{line_str}': {e}"));

        match event {
            ct_shell_trace_writer::wire_protocol::WireEvent::Start { program, .. } => {
                let program_path = std::path::PathBuf::from(&program);
                TraceWriter::start(&mut writer, &program_path, Line(1));
                current_file = Some(program);
                current_line = 1;
                started = true;
            }
            ct_shell_trace_writer::wire_protocol::WireEvent::Path { file } => {
                let path = std::path::PathBuf::from(&file);
                TraceWriter::ensure_path_id(&mut writer, &path);
            }
            ct_shell_trace_writer::wire_protocol::WireEvent::Func { name, file, line } => {
                let path = std::path::PathBuf::from(&file);
                TraceWriter::ensure_function_id(&mut writer, &name, &path, Line(line));
            }
            ct_shell_trace_writer::wire_protocol::WireEvent::Step { file, line } => {
                let path = std::path::PathBuf::from(&file);
                current_file = Some(file);
                current_line = line;
                TraceWriter::register_step(&mut writer, &path, Line(line));
            }
            ct_shell_trace_writer::wire_protocol::WireEvent::Call { name } => {
                let file = current_file
                    .clone()
                    .unwrap_or_else(|| "<unknown>".to_string());
                let path = std::path::PathBuf::from(&file);
                let function_id =
                    TraceWriter::ensure_function_id(&mut writer, &name, &path, Line(current_line));
                TraceWriter::register_call(&mut writer, function_id, vec![]);
            }
            ct_shell_trace_writer::wire_protocol::WireEvent::Var {
                name,
                value,
                type_flag,
            } => {
                let (kind, lang_type) = match type_flag.as_str() {
                    "i" => (TypeKind::Int, "Int"),
                    "s" => (TypeKind::String, "String"),
                    "a" => (TypeKind::Seq, "Array"),
                    "A" => (TypeKind::Struct, "AssocArray"),
                    "F" => (TypeKind::Float, "Float"),
                    _ => (TypeKind::String, "String"),
                };
                let type_id = TraceWriter::ensure_type_id(&mut writer, kind, lang_type);
                let value_record = match type_flag.as_str() {
                    "i" => {
                        let i = value.parse::<i64>().unwrap_or(0);
                        ValueRecord::Int { i, type_id }
                    }
                    "F" => {
                        let f = value.parse::<f64>().unwrap_or(0.0);
                        ValueRecord::Float { f, type_id }
                    }
                    _ => ValueRecord::String {
                        text: value,
                        type_id,
                    },
                };
                TraceWriter::register_variable_with_full_value(&mut writer, &name, value_record);
            }
            ct_shell_trace_writer::wire_protocol::WireEvent::Write { content } => {
                TraceWriter::register_special_event(&mut writer, EventLogKind::Write, "", &content);
            }
            ct_shell_trace_writer::wire_protocol::WireEvent::Error { cmd, status } => {
                let msg = format!("command '{cmd}' exited with status {status}");
                TraceWriter::register_special_event(&mut writer, EventLogKind::Error, &cmd, &msg);
            }
            ct_shell_trace_writer::wire_protocol::WireEvent::Return { status } => {
                let type_id = TraceWriter::ensure_type_id(&mut writer, TypeKind::Int, "Int");
                let return_value = ValueRecord::Int { i: status, type_id };
                TraceWriter::register_return(&mut writer, return_value);
            }
            ct_shell_trace_writer::wire_protocol::WireEvent::Exit { code } => {
                let type_id = TraceWriter::ensure_type_id(&mut writer, TypeKind::Int, "Int");
                let return_value = ValueRecord::Int { i: code, type_id };
                TraceWriter::register_return(&mut writer, return_value);
            }
        }
    }

    assert!(started, "START event should have been processed");

    // Finalize
    TraceWriter::finish_writing_trace_events(&mut writer).unwrap();
    TraceWriter::finish_writing_trace_metadata(&mut writer).unwrap();
    TraceWriter::finish_writing_trace_paths(&mut writer).unwrap();

    // Verify files exist and are non-empty
    assert!(
        events_path.exists(),
        "trace.json should exist at {}",
        events_path.display()
    );
    assert!(
        metadata_path.exists(),
        "trace_metadata.json should exist at {}",
        metadata_path.display()
    );
    assert!(
        paths_path.exists(),
        "trace_paths.json should exist at {}",
        paths_path.display()
    );

    let events_size = fs::metadata(&events_path).unwrap().len();
    let metadata_size = fs::metadata(&metadata_path).unwrap().len();
    let paths_size = fs::metadata(&paths_path).unwrap().len();

    assert!(events_size > 0, "trace.json should be non-empty");
    assert!(metadata_size > 0, "trace_metadata.json should be non-empty");
    assert!(paths_size > 0, "trace_paths.json should be non-empty");

    // Verify metadata content is valid JSON with expected fields
    let metadata_content = fs::read_to_string(&metadata_path).unwrap();
    let metadata: serde_json::Value =
        serde_json::from_str(&metadata_content).expect("trace_metadata.json should be valid JSON");
    assert_eq!(metadata["program"].as_str().unwrap(), "/tmp/test_script.sh");

    // Verify paths content is valid JSON
    let paths_content = fs::read_to_string(&paths_path).unwrap();
    let paths: serde_json::Value =
        serde_json::from_str(&paths_content).expect("trace_paths.json should be valid JSON");
    assert!(paths.is_array(), "trace_paths.json should be an array");
    assert!(
        !paths.as_array().unwrap().is_empty(),
        "trace_paths.json should have at least one path"
    );
}
