// Bridge between the wire protocol events and the TraceWriter API.
//
// TraceBridge holds a TraceWriter instance and translates each WireEvent
// into the appropriate sequence of TraceWriter method calls.

use std::error::Error;
use std::path::{Path, PathBuf};

use codetracer_trace_types::{EventLogKind, Line, TypeKind, ValueRecord};
use codetracer_trace_writer::trace_writer::TraceWriter;
use codetracer_trace_writer::{create_trace_writer, TraceEventsFileFormat};

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
            }
            WireEvent::Func { name, file, line } => {
                let path = PathBuf::from(&file);
                TraceWriter::ensure_function_id(self.writer.as_mut(), &name, &path, Line(line));
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
        };
        let events_path = self.output_dir.join(events_ext);
        let metadata_path = self.output_dir.join("trace_metadata.json");
        let paths_path = self.output_dir.join("trace_paths.json");

        TraceWriter::begin_writing_trace_events(self.writer.as_mut(), &events_path)?;
        TraceWriter::begin_writing_trace_metadata(self.writer.as_mut(), &metadata_path)?;
        TraceWriter::begin_writing_trace_paths(self.writer.as_mut(), &paths_path)?;

        let program_path = PathBuf::from(program);
        TraceWriter::start(self.writer.as_mut(), &program_path, Line(1));
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
    pub fn finish(&mut self) -> Result<(), Box<dyn Error>> {
        if self.started {
            TraceWriter::finish_writing_trace_events(self.writer.as_mut())?;
            TraceWriter::finish_writing_trace_metadata(self.writer.as_mut())?;
            TraceWriter::finish_writing_trace_paths(self.writer.as_mut())?;
        }
        Ok(())
    }
}
