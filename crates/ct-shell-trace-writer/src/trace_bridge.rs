// Bridge between the wire protocol events and the TraceWriter API.
//
// TraceBridge holds a TraceWriter instance and translates each WireEvent
// into the appropriate sequence of TraceWriter method calls.
//
// The Nim CTFS backend packages all trace data (events, metadata, paths)
// into a single `.ct` container file. Separate JSON sidecar files
// (`trace_metadata.json`, `trace_paths.json`, `symbols.json`) are written
// by the bridge itself in `finish()` so that the launcher scripts and
// downstream tools can consume them without parsing the binary container.

use std::collections::BTreeSet;
use std::error::Error;
use std::path::{Path, PathBuf};

use codetracer_trace_types::{EventLogKind, Line, TypeKind, ValueRecord};
use codetracer_trace_writer_nim::trace_writer::TraceWriter;
use codetracer_trace_writer_nim::{create_trace_writer, TraceEventsFileFormat};

use crate::wire_protocol::WireEvent;

/// Connects wire protocol events to the TraceWriter API.
pub struct TraceBridge {
    writer: Box<dyn TraceWriter + Send>,
    output_dir: PathBuf,
    format: TraceEventsFileFormat,
    /// Track the current file for auto-registering functions from CALL events.
    current_file: Option<String>,
    /// Track the current line for auto-registering functions from CALL events.
    current_line: i64,
    /// Whether `start()` has been called on the writer.
    started: bool,
    /// Program path from the START event, used for metadata sidecar.
    program: String,
    /// All registered source file paths, written as `trace_paths.json` sidecar.
    registered_paths: Vec<String>,
    /// All registered function names (excluding `<toplevel>`), written as
    /// `symbols.json` sidecar for quick symbol search in the UI.
    registered_functions: BTreeSet<String>,
}

impl TraceBridge {
    /// Create a new TraceBridge.
    ///
    /// This does NOT call `start()` on the writer yet -- that happens when
    /// the START event is processed, since we need the program path from it.
    pub fn new(
        output_dir: &Path,
        format: TraceEventsFileFormat,
        program: &str,
        args: &[String],
    ) -> Self {
        let writer = create_trace_writer(program, args, format);
        TraceBridge {
            writer,
            output_dir: output_dir.to_path_buf(),
            format,
            current_file: None,
            current_line: 1,
            started: false,
            program: program.to_string(),
            registered_paths: Vec::new(),
            registered_functions: BTreeSet::new(),
        }
    }

    /// Process a single wire protocol event.
    pub fn handle_event(&mut self, event: WireEvent) -> Result<(), Box<dyn Error>> {
        match event {
            WireEvent::Start {
                program,
                shell: _,
                shell_version: _,
            } => {
                self.handle_start(&program)?;
            }
            WireEvent::Path { file } => {
                let path = PathBuf::from(&file);
                TraceWriter::ensure_path_id(self.writer.as_mut(), &path);
                self.registered_paths.push(file);
            }
            WireEvent::Func { name, file, line } => {
                let path = PathBuf::from(&file);
                TraceWriter::ensure_function_id(self.writer.as_mut(), &name, &path, Line(line));
                if name != "<toplevel>" {
                    self.registered_functions.insert(name);
                }
            }
            WireEvent::Step { file, line } => {
                let path = PathBuf::from(&file);
                self.current_file = Some(file);
                self.current_line = line;
                TraceWriter::register_step(self.writer.as_mut(), &path, Line(line));
            }
            WireEvent::Call { name } => {
                self.handle_call(&name);
            }
            WireEvent::Var {
                name,
                value,
                type_flag,
            } => {
                self.handle_var(&name, &value, &type_flag);
            }
            WireEvent::Write { content } => {
                TraceWriter::register_special_event(
                    self.writer.as_mut(),
                    EventLogKind::Write,
                    "",
                    &content,
                );
            }
            WireEvent::Error { cmd, status } => {
                let message = format!("command '{cmd}' exited with status {status}");
                TraceWriter::register_special_event(
                    self.writer.as_mut(),
                    EventLogKind::Error,
                    &cmd,
                    &message,
                );
            }
            WireEvent::Return { status } => {
                let type_id =
                    TraceWriter::ensure_type_id(self.writer.as_mut(), TypeKind::Int, "Int");
                let return_value = ValueRecord::Int { i: status, type_id };
                TraceWriter::register_return(self.writer.as_mut(), return_value);
            }
            WireEvent::Exit { code } => {
                let type_id =
                    TraceWriter::ensure_type_id(self.writer.as_mut(), TypeKind::Int, "Int");
                let return_value = ValueRecord::Int { i: code, type_id };
                TraceWriter::register_return(self.writer.as_mut(), return_value);
            }
        }
        Ok(())
    }

    /// Initialize the trace writer files and call start().
    fn handle_start(&mut self, program: &str) -> Result<(), Box<dyn Error>> {
        let events_ext = match self.format {
            TraceEventsFileFormat::Json => "trace.json",
            TraceEventsFileFormat::Binary | TraceEventsFileFormat::BinaryV0 => "trace.bin",
            TraceEventsFileFormat::Ctfs => "trace.ct",
        };
        let events_path = self.output_dir.join(events_ext);
        let metadata_path = self.output_dir.join("trace_metadata.json");
        let paths_path = self.output_dir.join("trace_paths.json");

        TraceWriter::begin_writing_trace_events(self.writer.as_mut(), &events_path)?;
        TraceWriter::begin_writing_trace_metadata(self.writer.as_mut(), &metadata_path)?;
        TraceWriter::begin_writing_trace_paths(self.writer.as_mut(), &paths_path)?;

        let program_path = PathBuf::from(program);
        TraceWriter::start(self.writer.as_mut(), &program_path, Line(1));
        self.program = program.to_string();
        self.current_file = Some(program.to_string());
        self.current_line = 1;
        self.started = true;
        Ok(())
    }

    /// Handle a CALL event: look up or auto-register the function, then register the call.
    fn handle_call(&mut self, name: &str) {
        // Use current step's file/line as fallback for auto-registration.
        let file = self
            .current_file
            .clone()
            .unwrap_or_else(|| "<unknown>".to_string());
        let path = PathBuf::from(&file);
        let line = Line(self.current_line);

        let function_id = TraceWriter::ensure_function_id(self.writer.as_mut(), name, &path, line);
        if name != "<toplevel>" {
            self.registered_functions.insert(name.to_string());
        }
        // No args for now (will be enhanced in M3)
        TraceWriter::register_call(self.writer.as_mut(), function_id, vec![]);
    }

    /// Handle a VAR event: map the type flag to TypeKind and create the ValueRecord.
    fn handle_var(&mut self, name: &str, value: &str, type_flag: &str) {
        let (kind, lang_type) = match type_flag {
            "i" => (TypeKind::Int, "Int"),
            "s" => (TypeKind::String, "String"),
            "a" => (TypeKind::Seq, "Array"),
            "A" => (TypeKind::Struct, "AssocArray"),
            "F" => (TypeKind::Float, "Float"),
            _ => (TypeKind::String, "String"),
        };

        let type_id = TraceWriter::ensure_type_id(self.writer.as_mut(), kind, lang_type);

        let value_record = match type_flag {
            "i" => {
                let i = value.parse::<i64>().unwrap_or(0);
                ValueRecord::Int { i, type_id }
            }
            "F" => {
                let f = value.parse::<f64>().unwrap_or(0.0);
                ValueRecord::Float { f, type_id }
            }
            // For "s", "a", "A", and default: store as String
            _ => ValueRecord::String {
                text: value.to_string(),
                type_id,
            },
        };

        TraceWriter::register_variable_with_full_value(self.writer.as_mut(), name, value_record);
    }

    /// Finalize trace files. Call this after EXIT or on EOF.
    ///
    /// This finishes all three output streams (events, metadata, paths) and then
    /// closes the writer. For the Nim CTFS backend, `close()` is the step that
    /// actually flushes the `.ct` container file to disk.
    ///
    /// After the writer is closed, sidecar JSON files are written to the output
    /// directory so that launcher scripts and downstream tools can access
    /// metadata, paths, and symbols without parsing the binary `.ct` container:
    ///
    /// - `trace_metadata.json` — program name and basic recording metadata
    /// - `trace_paths.json` — array of registered source file paths
    /// - `symbols.json` — array of registered function names (for symbol search)
    pub fn finish(&mut self) -> Result<(), Box<dyn Error>> {
        if self.started {
            TraceWriter::finish_writing_trace_events(self.writer.as_mut())?;
            TraceWriter::finish_writing_trace_metadata(self.writer.as_mut())?;
            TraceWriter::finish_writing_trace_paths(self.writer.as_mut())?;
            TraceWriter::close(self.writer.as_mut())?;

            self.write_sidecar_files()?;
        }
        Ok(())
    }

    /// Write JSON sidecar files alongside the `.ct` container.
    ///
    /// These files duplicate information that is already inside the binary
    /// container, but in a human-readable form that shell scripts and simple
    /// tools can consume without a CTFS reader.
    fn write_sidecar_files(&self) -> Result<(), Box<dyn Error>> {
        // trace_metadata.json — minimal metadata about the recording
        let metadata = format!("{{\"program\":{}}}", serde_json_escape(&self.program));
        std::fs::write(self.output_dir.join("trace_metadata.json"), metadata)?;

        // trace_paths.json — array of source file paths
        let paths_json: String = format!(
            "[{}]",
            self.registered_paths
                .iter()
                .map(|p| serde_json_escape(p))
                .collect::<Vec<_>>()
                .join(",")
        );
        std::fs::write(self.output_dir.join("trace_paths.json"), paths_json)?;

        // symbols.json — array of function names for quick symbol lookup
        let symbols_json: String = format!(
            "[{}]",
            self.registered_functions
                .iter()
                .map(|n| serde_json_escape(n))
                .collect::<Vec<_>>()
                .join(",")
        );
        std::fs::write(self.output_dir.join("symbols.json"), symbols_json)?;

        Ok(())
    }
}

/// Escape a string for embedding in JSON output.
///
/// Produces a quoted JSON string with backslash, double-quote, and control
/// character escaping per RFC 8259 section 7.
fn serde_json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c.is_control() => {
                out.push_str(&format!("\\u{:04x}", c as u32));
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}
