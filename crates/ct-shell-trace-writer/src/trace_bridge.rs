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
//
// CTFS-only.  The shell trace writer is hard-pinned to CTFS — see
// `codetracer-specs/Recorder-CLI-Conventions.md` §4.  The previous
// `TraceEventsFileFormat` dispatch (which selected between CTFS, the
// Rust-native CBOR+Zstd writer, and JSON) was removed in the 2026-05
// convention compliance pass.  Conversion to JSON for debugging or
// golden snapshots is the job of `ct print` from
// `codetracer-trace-format-nim`.

use std::collections::BTreeSet;
use std::error::Error;
use std::path::{Path, PathBuf};

use codetracer_trace_types::{EventLogKind, FullValueRecord, Line, TypeKind, ValueRecord};
use codetracer_trace_writer_nim::trace_writer::TraceWriter;
use codetracer_trace_writer_nim::TraceEventsFileFormat;

use crate::wire_protocol::WireEvent;

/// Create the CTFS trace writer.
///
/// The shell recorders always produce a `.ct` container with the canonical
/// multi-stream CTFS layout (steps.dat, calls.dat, paths.dat, etc.).  The
/// previous `Binary` and `Json` branches were removed in the 2026-05
/// convention compliance pass — see Recorder-CLI-Conventions §4.
fn create_writer(program: &str, args: &[String]) -> Box<dyn TraceWriter> {
    codetracer_trace_writer_nim::create_trace_writer(program, args, TraceEventsFileFormat::Ctfs)
}

/// Connects wire protocol events to the TraceWriter API.
pub struct TraceBridge {
    writer: Box<dyn TraceWriter + Send>,
    output_dir: PathBuf,
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
    /// Script-level positional parameters captured from CLI `--args`.
    ///
    /// Staged onto the implicit top-level call when `START` arrives so the
    /// frontend's calltrace pane can show `script $1 $2 ...` on the root
    /// frame.  Mirrors the canonical CTFS call-arg staging pattern (Ruby
    /// 1.21, Python 1.27, Move 1.46, Cairo 1.50, etc.).
    script_args: Vec<String>,
    /// Args staged via `ARG` wire events that have not yet been consumed
    /// by a `CALL` event.  Drained on every `CALL` so each call frame's
    /// arg list is exactly the one the recorder emitted before it.
    pending_call_args: Vec<FullValueRecord>,
}

impl TraceBridge {
    /// Create a new TraceBridge.
    ///
    /// This does NOT call `start()` on the writer yet -- that happens when
    /// the START event is processed, since we need the program path from it.
    pub fn new(output_dir: &Path, program: &str, args: &[String]) -> Self {
        let writer = create_writer(program, args);
        TraceBridge {
            writer,
            output_dir: output_dir.to_path_buf(),
            current_file: None,
            current_line: 1,
            started: false,
            program: program.to_string(),
            registered_paths: Vec::new(),
            registered_functions: BTreeSet::new(),
            script_args: args.to_vec(),
            pending_call_args: Vec::new(),
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
            WireEvent::Arg {
                name,
                value,
                type_flag,
            } => {
                self.handle_arg(&name, &value, &type_flag);
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
        // CTFS-only: the events stream is always written into a `.ct`
        // container.  The Nim writer derives the actual on-disk filename
        // from the program basename, so the path we pass here is mostly
        // used as a placeholder.
        let events_path = self.output_dir.join("trace.ct");
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

        // Stage script-level positional parameters (the program's argv,
        // captured by the launcher as `--args ...`) onto the implicit
        // top-level call so the calltrace pane shows `script $1 $2 ...` on
        // the root frame.  We register an explicit `<toplevel>` call for
        // this purpose, mirroring the Ruby 1.21 native-recorder fix
        // (`<top-level>` opened in `initialize`, closed on
        // `disable_tracing`).  The matching close happens on the final
        // `EXIT` event in `handle_event`.
        //
        // Note: clone here is necessary because `handle_arg` borrows
        // `self` mutably and we cannot iterate `self.script_args` while
        // also calling `&mut self` methods.
        let script_args: Vec<String> = self.script_args.clone();
        for (idx, arg_value) in script_args.iter().enumerate() {
            // Use bash/zsh-style positional-parameter names ($1 .. $N).
            // The wire-protocol type flag is always "s" since shell
            // positional parameters are always strings at the OS level.
            let name = format!("${}", idx + 1);
            self.handle_arg(&name, arg_value, "s");
        }
        // Register the implicit top-level call.  This drains the args we
        // just staged and pairs with the `register_return` emitted from
        // the EXIT handler.
        self.handle_call("<toplevel>");
        Ok(())
    }

    /// Handle a CALL event: look up or auto-register the function, then register the call.
    ///
    /// Any `ARG` events that arrived since the previous `CALL` are drained
    /// from `pending_call_args` and passed to `register_call(fid, args)` so
    /// the call frame in the trace records its positional parameters
    /// (matching the canonical CTFS call-arg staging pattern from Ruby 1.21
    /// onwards).
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
        // Drain any args staged by ARG events received since the previous CALL.
        // Even if the recorder never emits ARG (e.g. an old launcher), this is
        // a no-op: the pending list stays empty and we register an empty arg
        // vector, preserving pre-fix behaviour.
        let args = std::mem::take(&mut self.pending_call_args);
        TraceWriter::register_call(self.writer.as_mut(), function_id, args);
    }

    /// Handle an ARG event: stage one positional parameter for the next
    /// `CALL`.  Type-flag handling mirrors `handle_var` so the same wire-
    /// protocol type vocabulary applies (`i`/`s`/`a`/`A`/`F`).
    fn handle_arg(&mut self, name: &str, value: &str, type_flag: &str) {
        let value_record = self.value_record_for_flag(value, type_flag);
        let full = TraceWriter::arg(self.writer.as_mut(), name, value_record);
        self.pending_call_args.push(full);
    }

    /// Build a `ValueRecord` from a wire-protocol typed value.  Shared
    /// helper so `handle_var` and `handle_arg` agree on the type vocabulary.
    fn value_record_for_flag(&mut self, value: &str, type_flag: &str) -> ValueRecord {
        let (kind, lang_type) = match type_flag {
            "i" => (TypeKind::Int, "Int"),
            "s" => (TypeKind::String, "String"),
            "a" => (TypeKind::Seq, "Array"),
            "A" => (TypeKind::Struct, "AssocArray"),
            "F" => (TypeKind::Float, "Float"),
            _ => (TypeKind::String, "String"),
        };

        let type_id = TraceWriter::ensure_type_id(self.writer.as_mut(), kind, lang_type);

        match type_flag {
            "i" => {
                // Defensive parse: an unparseable integer falls back to 0
                // rather than dropping the arg or panicking.
                let i = value.parse::<i64>().unwrap_or(0);
                ValueRecord::Int { i, type_id }
            }
            "F" => {
                let f = value.parse::<f64>().unwrap_or(0.0);
                ValueRecord::Float { f, type_id }
            }
            // For "s", "a", "A", and default: store as String.  Arrays and
            // assoc arrays are surfaced as their bash/zsh `declare -p` text
            // representation; richer structural decoding is a follow-up.
            _ => ValueRecord::String {
                text: value.to_string(),
                type_id,
            },
        }
    }

    /// Handle a VAR event: map the type flag to TypeKind and create the ValueRecord.
    fn handle_var(&mut self, name: &str, value: &str, type_flag: &str) {
        let value_record = self.value_record_for_flag(value, type_flag);
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
        // trace_metadata.json — minimal metadata about the recording.
        // Must include all fields required by TraceMetadata deserialization
        // (program, args). Workdir has serde(default) and can be omitted.
        let metadata = format!(
            "{{\"program\":{},\"args\":[]}}",
            serde_json_escape(&self.program)
        );
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
