// Shared helpers for the recorder tests in `bash_recording_test.rs` and
// `zsh_recording_test.rs`: the exit-code claims, and reading the variables
// recorded at a step back out of a `.ct` container.
//
// The exit-code claims are identical for both shells (spec
// `Recording-Backends/Shell-Recorder.md`, "Bash Traps" / "Zsh Traps": the
// `EXIT` trap records "Program exit with exit code"), so the assertions live
// here once and each shell's test file calls them with its own recorder,
// launcher and fixture directory.
//
// No mocks: every helper runs the real shell on the real recorder script and
// the real `ct-shell-trace-writer` binary, and reads the real `.ct` container
// back through the Nim reader.
#![allow(dead_code)] // each test crate uses a different subset

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use codetracer_trace_types::ValueRecord;
use codetracer_trace_writer_nim::{decode_cbor_value_record, NimTraceReaderHandle};
use ct_shell_trace_writer::wire_protocol::{parse_line, WireEvent};
use tempfile::TempDir;

/// The warning the writer prints when the event stream ends without the
/// `EXIT` event that closes the `<script>` frame.
pub const MISSING_EXIT_WARNING: &str = "EOF reached without EXIT event";

/// One shell's recorder layout: which interpreter runs it, where its
/// recorder and launcher scripts live, and where its fixtures are.
pub struct Shell {
    pub interpreter: &'static str,
    pub recorder: &'static str,
    pub launcher: &'static str,
    pub fixture_dir: &'static str,
    pub fixture_ext: &'static str,
}

pub const BASH: Shell = Shell {
    interpreter: "bash",
    recorder: "bash-recorder/recorder.sh",
    launcher: "bash-recorder/launcher.sh",
    fixture_dir: "tests/fixtures/bash",
    fixture_ext: "sh",
};

pub const ZSH: Shell = Shell {
    interpreter: "zsh",
    recorder: "zsh-recorder/recorder.zsh",
    launcher: "zsh-recorder/launcher.zsh",
    fixture_dir: "tests/fixtures/zsh",
    fixture_ext: "zsh",
};

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap() // crates/
        .parent()
        .unwrap() // repo root
        .to_path_buf()
}

impl Shell {
    pub fn fixture(&self, stem: &str) -> PathBuf {
        repo_root()
            .join(self.fixture_dir)
            .join(format!("{stem}.{}", self.fixture_ext))
    }
}

/// The result of running a recorder directly, with FD 3 sent to a file.
pub struct RecorderRun {
    /// Holds the event file alive for the caller.
    pub dir: TempDir,
    pub events_file: PathBuf,
    pub events: Vec<String>,
    pub status: Option<i32>,
    pub stderr: String,
}

/// Run `shell`'s recorder on `script` with FD 3 redirected to a file, the
/// way the launcher runs it, and return the event lines and exit status.
pub fn run_recorder(shell: &Shell, script: &Path) -> RecorderRun {
    let dir = TempDir::new().expect("failed to create temp dir");
    let events_file = dir.path().join("events.txt");
    // `sh -c` opens FD 3 on the event file and then execs the shell, so the
    // recorder sees the same descriptor layout the launcher gives it. The
    // recorder is run by its repository-relative path, from the repository
    // root: the launchers run it by an absolute path, so this covers the
    // other spelling the recorder must recognise as its own file.
    let output = Command::new("sh")
        .current_dir(repo_root())
        .args([
            "-c",
            r#"exec "$0" "$1" "$2" 3>"$3""#,
            shell.interpreter,
            shell.recorder,
            script.to_str().unwrap(),
            events_file.to_str().unwrap(),
        ])
        .output()
        .expect("failed to run the recorder");
    let events = std::fs::read_to_string(&events_file)
        .expect("failed to read the event file")
        .lines()
        .map(str::to_string)
        .collect();
    RecorderRun {
        dir,
        events_file,
        events,
        status: output.status.code(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    }
}

/// Assert the recorder's event stream for `script` ends with exactly one
/// `EXIT code=<code>` event and that the recorder exits with `code`.
pub fn assert_recorder_exit(shell: &Shell, stem: &str, code: i32) -> RecorderRun {
    let run = run_recorder(shell, &shell.fixture(stem));
    let exits: Vec<&String> = run
        .events
        .iter()
        .filter(|l| l.starts_with("EXIT "))
        .collect();
    assert_eq!(
        exits.len(),
        1,
        "{} {stem}: expected exactly one EXIT event, got {:?}; last events: {:?}",
        shell.interpreter,
        exits,
        run.events.iter().rev().take(3).collect::<Vec<_>>()
    );
    assert_eq!(
        run.events.last().map(String::as_str),
        Some(format!("EXIT code={code}").as_str()),
        "{} {stem}: the last event must be the EXIT event",
        shell.interpreter
    );
    // Writing the EXIT event must not record the recorder's own code: no
    // step in, and no call of, the recorder's functions.
    let recorder_file = Path::new(shell.recorder)
        .file_name()
        .unwrap()
        .to_str()
        .unwrap();
    let leaked: Vec<&String> = run
        .events
        .iter()
        .filter(|l| l.contains(recorder_file) || l.contains("name=_ct_"))
        .collect();
    assert!(
        leaked.is_empty(),
        "{} {stem}: events from the recorder itself: {leaked:?}",
        shell.interpreter
    );
    assert_eq!(
        run.status,
        Some(code),
        "{} {stem}: recorder exit status; stderr={}",
        shell.interpreter,
        run.stderr
    );
    run
}

/// Assert the last `STEP` of a run is at `line`: the line of the script's
/// `exit`. Running the exit handler must not add a step of its own (bash
/// runs the DEBUG trap for a trap action's commands, reporting the script's
/// file and a line number counted within the action string).
pub fn assert_last_step_line(shell: &Shell, stem: &str, run: &RecorderRun, line: u32) {
    let last_step = run
        .events
        .iter()
        .rev()
        .find(|l| l.starts_with("STEP "))
        .expect("no STEP event");
    assert!(
        last_step.ends_with(&format!(" line={line}")),
        "{} {stem}: the last step should be the exit at line {line}, got {last_step}",
        shell.interpreter
    );
}

/// Feed a recorded event file to the `ct-shell-trace-writer` built for this
/// test run and return the output directory and the writer's stderr.
pub fn write_trace(events_file: &Path, program: &Path) -> (TempDir, String) {
    let out = TempDir::new().expect("failed to create temp dir");
    let input = std::fs::File::open(events_file).expect("failed to open the event file");
    let output: Output = Command::new(env!("CARGO_BIN_EXE_ct-shell-trace-writer"))
        .args([
            "--out-dir",
            out.path().to_str().unwrap(),
            "--program",
            program.to_str().unwrap(),
        ])
        .stdin(input)
        .output()
        .expect("failed to run ct-shell-trace-writer");
    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
    assert!(output.status.success(), "writer failed: {stderr}");
    (out, stderr)
}

/// Run the launcher on `script` and return its output directory and output.
pub fn run_launcher(shell: &Shell, script: &Path) -> (TempDir, Output) {
    run_launcher_with_env(shell, script, &[])
}

/// Run the launcher on `script` with `env` added to the inherited
/// environment, and return its output directory and output.
pub fn run_launcher_with_env(
    shell: &Shell,
    script: &Path,
    env: &[(&str, &str)],
) -> (TempDir, Output) {
    let out = TempDir::new().expect("failed to create temp dir");
    let output = Command::new(shell.interpreter)
        .args([
            repo_root().join(shell.launcher).to_str().unwrap(),
            "--out-dir",
            out.path().to_str().unwrap(),
            script.to_str().unwrap(),
        ])
        .envs(env.iter().copied())
        .output()
        .expect("failed to run the launcher");
    (out, output)
}

/// The single `.ct` container in a launcher's output directory, opened
/// through the Nim reader.
fn open_trace(out_dir: &Path) -> NimTraceReaderHandle {
    let ct = std::fs::read_dir(out_dir)
        .expect("failed to read the output dir")
        .filter_map(|e| e.ok().map(|e| e.path()))
        .find(|p| p.extension().is_some_and(|ext| ext == "ct"))
        .expect("no .ct file in the output dir");
    NimTraceReaderHandle::open(ct.to_str().unwrap()).expect("failed to open .ct")
}

/// The variables recorded at the last step of the trace, as (name, decoded
/// value), in the order the trace holds them. The recorders emit the full
/// variable state after every step, so the last step carries every variable
/// the script created that is still set at its end.
pub fn last_step_vars(out_dir: &Path) -> Vec<(String, ValueRecord)> {
    let reader = open_trace(out_dir);
    let steps = reader.step_count();
    assert!(steps > 0, "the trace has no steps");
    let last = steps - 1;
    (0..reader.step_value_count(last))
        .map(|idx| {
            let (varname_id, _type_id, cbor) = reader.step_value(last, idx).expect("step_value");
            let name = reader.varname(varname_id).expect("varname");
            (name, decode_cbor_value_record(&cbor))
        })
        .collect()
}

/// The value of the variable `name` among `vars`, if it was recorded.
pub fn var<'a>(vars: &'a [(String, ValueRecord)], name: &str) -> Option<&'a ValueRecord> {
    vars.iter().find(|(n, _)| n == name).map(|(_, v)| v)
}

/// The recorded variable names, sorted, for set comparisons and messages.
pub fn var_names(vars: &[(String, ValueRecord)]) -> Vec<String> {
    let mut names: Vec<String> = vars.iter().map(|(n, _)| n.clone()).collect();
    names.sort();
    names
}

/// Assert `value` is `String <expected>`, with the text compared exactly.
pub fn assert_string(value: Option<&ValueRecord>, expected: &str, what: &str) {
    match value {
        Some(ValueRecord::String { text, .. }) if text == expected => {}
        other => panic!("{what}: expected String {expected:?}, got {other:?}"),
    }
}

/// Every call in the trace, in call-key order, as (function name, decoded
/// return value). A frame that finalisation closed because no `RETURN` or
/// `EXIT` event reached it decodes to a non-`Int` value (`Void`).
pub fn call_returns(out_dir: &Path) -> Vec<(String, ValueRecord)> {
    let reader = open_trace(out_dir);
    (0..reader.call_count())
        .map(|key| {
            let (function_id, ..) = reader.call_fields(key).expect("call_fields");
            let name = reader.function(function_id).expect("function name");
            let json: serde_json::Value =
                serde_json::from_str(&reader.call_json(key).expect("call_json"))
                    .expect("call JSON");
            let bytes: Vec<u8> = json["return_value"]
                .as_array()
                .expect("return_value bytes")
                .iter()
                .map(|b| b.as_u64().expect("byte") as u8)
                .collect();
            (name, decode_cbor_value_record(&bytes))
        })
        .collect()
}

/// The decoded return value of the single call to `function` in the trace.
pub fn return_of(calls: &[(String, ValueRecord)], function: &str) -> ValueRecord {
    let matching: Vec<&ValueRecord> = calls
        .iter()
        .filter(|(n, _)| n == function)
        .map(|(_, v)| v)
        .collect();
    assert_eq!(
        matching.len(),
        1,
        "expected one call to {function}, calls: {calls:?}"
    );
    matching[0].clone()
}

/// Assert `value` is `Int <expected>`.
pub fn assert_int(value: &ValueRecord, expected: i64, what: &str) {
    match value {
        ValueRecord::Int { i, .. } if *i == expected => {}
        other => panic!("{what}: expected Int {expected}, got {other:?}"),
    }
}

/// The full set of exit-code claims for one shell. Each assertion maps to
/// one claim of the issue
/// `2026-11-15-shell-recorders-emit-no-exit-event-when-the-script-calls-exit`.
pub fn check_exit_codes(shell: &Shell) {
    // A script that runs off its end still gets its EXIT event (regression
    // guard for the pre-existing path).
    assert_recorder_exit(shell, "simple", 0);

    // (a) `exit 0` / `exit 3` / `exit` inside a function: the event stream
    // ends with exactly one `EXIT code=<n>`.
    let zero = assert_recorder_exit(shell, "exit_zero", 0);
    assert_last_step_line(shell, "exit_zero", &zero, 4);
    let three = assert_recorder_exit(shell, "exit_three", 3);
    assert_last_step_line(shell, "exit_three", &three, 4);
    let in_fn = assert_recorder_exit(shell, "exit_in_function", 4);
    assert_last_step_line(shell, "exit_in_function", &in_fn, 5);

    // `exit 300` ends the process with status 44 (the low eight bits). zsh
    // keeps 300 in `$?`, so the recorded code must be reduced the same way
    // to match the status the parent sees.
    assert_recorder_exit(shell, "exit_out_of_range", 44);

    // `exit` in a subshell or a command substitution is not the script's
    // exit, and must not produce an EXIT event of its own.
    assert_recorder_exit(shell, "subshell_exits", 0);

    // (b) Through the launcher, the exit-0 script is recorded without the
    // missing-EXIT warning, and `<script>` returns Int 0.
    let (out0, output0) = run_launcher(shell, &shell.fixture("exit_zero"));
    let stderr0 = String::from_utf8_lossy(&output0.stderr);
    assert!(
        output0.status.success(),
        "launcher failed on exit_zero: {stderr0}"
    );
    assert!(
        !stderr0.contains(MISSING_EXIT_WARNING),
        "launcher stderr on exit_zero: {stderr0}"
    );
    let calls0 = call_returns(out0.path());
    assert_int(&return_of(&calls0, "<script>"), 0, "<script> of exit_zero");

    // (c) Non-zero exits. The recorder's event file is fed to the writer
    // directly, exactly as the launcher would, so these claims hold for the
    // writer on its own; the launcher's handling of a non-zero exit is
    // covered by `check_nonzero_exit_keeps_trace`.
    let (out3, stderr3) = write_trace(&three.events_file, &shell.fixture("exit_three"));
    assert!(
        !stderr3.contains(MISSING_EXIT_WARNING),
        "writer stderr on exit_three: {stderr3}"
    );
    let calls3 = call_returns(out3.path());
    assert_int(&return_of(&calls3, "<script>"), 3, "<script> of exit_three");

    // `exit 4` inside `die`: the `die` frame is closed with the exit status,
    // and `<script>` still returns the exit code rather than being left for
    // finalisation to close without a value.
    let (out4, stderr4) = write_trace(&in_fn.events_file, &shell.fixture("exit_in_function"));
    assert!(
        !stderr4.contains(MISSING_EXIT_WARNING),
        "writer stderr on exit_in_function: {stderr4}"
    );
    let calls4 = call_returns(out4.path());
    assert_int(&return_of(&calls4, "die"), 4, "die of exit_in_function");
    assert_int(
        &return_of(&calls4, "<script>"),
        4,
        "<script> of exit_in_function",
    );
}

/// Run the launcher on `script` with the directory of the
/// `ct-shell-trace-writer` that cargo built for this test run first on
/// `PATH`, and return its output directory and output.
///
/// The launchers look for the writer on `PATH` before any `target/`
/// directory, and among those they prefer `target/release` to
/// `target/debug`. A test that only rebuilt the debug profile would
/// otherwise record with whatever release binary is left in the tree
/// (codetracer-pm issue
/// `2026-11-15-shell-recorder-tests-run-a-leftover-release-writer-instead-of-the-one-they-just-built`).
pub fn run_launcher_with_built_writer(shell: &Shell, script: &Path) -> (TempDir, Output) {
    let writer_dir = Path::new(env!("CARGO_BIN_EXE_ct-shell-trace-writer"))
        .parent()
        .expect("the writer binary has a parent directory")
        .to_path_buf();
    let inherited = std::env::var_os("PATH").unwrap_or_default();
    let path =
        std::env::join_paths(std::iter::once(writer_dir).chain(std::env::split_paths(&inherited)))
            .expect("PATH entries must be joinable");
    run_launcher_with_env(
        shell,
        script,
        &[("PATH", path.to_str().expect("UTF-8 PATH"))],
    )
}

/// Record the fixture `stem` through the launcher and assert the complete
/// recording a launcher promises, whatever status the script ends with:
///
/// - the launcher exits with exactly the script's status `status`
///   (spec `Recorder-CLI-Conventions.md` §6 "Exit Codes": "N — Target
///   program exit code (pass-through)");
/// - the output directory holds the `.ct` container, `symbols.json`,
///   `trace_db_metadata.json` and the script's copy under `files/`;
/// - the writer saw the `EXIT` event (no missing-EXIT warning), and the
///   `<script>` frame returns `Int <status>`;
/// - the container names the fixture as its program, and its last step is
///   at `exit_line` of the fixture: the line of the command that ended it.
pub fn assert_launcher_records(shell: &Shell, stem: &str, status: i32, exit_line: u64) {
    let fixture = shell.fixture(stem);
    let file_name = fixture.file_name().unwrap().to_str().unwrap().to_string();
    let (out, output) = run_launcher_with_built_writer(shell, &fixture);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(status),
        "{} launcher must pass the script's exit status through for {file_name}: stderr={stderr}",
        shell.interpreter
    );
    let present: Vec<String> = std::fs::read_dir(out.path())
        .expect("failed to read the output dir")
        .filter_map(|e| e.ok().map(|e| e.file_name().to_string_lossy().into_owned()))
        .collect();
    assert!(
        !present.is_empty(),
        "a script exiting with status {status} must still produce a trace, but the output directory is empty ({file_name}); stderr={stderr}"
    );
    assert!(
        !stderr.contains(MISSING_EXIT_WARNING),
        "{} {file_name}: writer warned of a missing EXIT event: {stderr}",
        shell.interpreter
    );

    let expected_ct = format!("{}.ct", fixture.file_stem().unwrap().to_str().unwrap());
    for name in [
        expected_ct.as_str(),
        "symbols.json",
        "trace_db_metadata.json",
    ] {
        assert!(
            out.path().join(name).is_file(),
            "{} {file_name}: {name} missing from the output dir; present: {present:?}",
            shell.interpreter
        );
    }
    // The writer copies each recorded source to `files/<absolute path
    // without its leading separator>` (`copy_source_files` in
    // `src/trace_bridge.rs`).
    let copied = out
        .path()
        .join("files")
        .join(fixture.strip_prefix("/").unwrap_or(&fixture));
    assert!(
        copied.is_file(),
        "{} {file_name}: the script was not copied to {}; present: {present:?}",
        shell.interpreter,
        copied.display()
    );

    let reader = open_trace(out.path());
    let program = reader.program();
    assert!(
        program.contains(&file_name),
        "{} {file_name}: program should reference the fixture, got {program}",
        shell.interpreter
    );
    let steps = reader.step_count();
    assert!(
        steps > 0,
        "{} {file_name}: the trace has no steps",
        shell.interpreter
    );
    let (path_id, line) = reader.step_location(steps - 1).expect("step_location");
    let step_path = reader.path(path_id).expect("path of the last step");
    assert!(
        step_path.ends_with(&file_name) && line == exit_line,
        "{} {file_name}: the last step should be at line {exit_line} of the fixture, got {step_path}:{line}",
        shell.interpreter
    );
    drop(reader);

    let calls = call_returns(out.path());
    assert_int(
        &return_of(&calls, "<script>"),
        i64::from(status),
        &format!("<script> of {file_name}"),
    );
}

/// Recording a script that ends with a non-zero status must still write the
/// trace, and the launcher must still return the script's status (codetracer-pm
/// issue `2026-11-15-shell-recorders-write-no-trace-when-the-recorded-script-exits-non-zero`;
/// spec `CLI/recorders/shell.md` "Rules": "The recorded script's exit status
/// is preserved", and `Recording-Backends/Shell-Recorder.md` "Invocation
/// Flow" steps 10 and 11, which finalize the trace on any exit).
///
/// The control records `simple`, which ends with status 0 at line 5, through
/// the same assertions, so a failure of the non-zero case cannot come from
/// a launcher or writer that records nothing at all.
pub fn check_nonzero_exit_keeps_trace(shell: &Shell, stem: &str, status: i32, exit_line: u64) {
    assert_ne!(status, 0, "{stem}: this check is for non-zero statuses");
    assert_launcher_records(shell, "simple", 0, 5);
    assert_launcher_records(shell, stem, status, exit_line);
}

// ============================================================================
// Function return recording
// ============================================================================
//
// Codetracer-pm issue
// `2026-11-15-shell-recorders-never-close-a-function-called-in-command-substitution`.
// Spec `Recording-Backends/Shell-Recorder.md`, "Event Mapping": a function
// that returns produces a `Return` carrying its exit status as an `Int`, and
// "Subshells and Child Scripts": `$(...)` and `( ... )` are traced. The
// claims are the same for both shells, so they live here once and each
// shell's test file calls them.

/// One recorded call: function name, call depth, and the integer return
/// value (`None` when the frame was closed without an `Int`, which is what
/// finalisation does to a frame no `RETURN` or `EXIT` event reached).
#[derive(Debug, Clone)]
pub struct RecordedCall {
    pub name: String,
    pub depth: u64,
    pub status: Option<i64>,
}

/// Every call in the trace in `out_dir`, in call-key order.
pub fn recorded_calls(out_dir: &Path) -> Vec<RecordedCall> {
    let reader = open_trace(out_dir);
    (0..reader.call_count())
        .map(|key| {
            let json: serde_json::Value =
                serde_json::from_str(&reader.call_json(key).expect("call_json"))
                    .expect("call JSON");
            let bytes: Vec<u8> = json["return_value"]
                .as_array()
                .map(|a| a.iter().map(|b| b.as_u64().expect("byte") as u8).collect())
                .unwrap_or_default();
            let status = if bytes.is_empty() {
                None
            } else {
                match decode_cbor_value_record(&bytes) {
                    ValueRecord::Int { i, .. } => Some(i),
                    _ => None,
                }
            };
            RecordedCall {
                name: reader
                    .function(json["function_id"].as_u64().expect("function_id"))
                    .expect("function name"),
                depth: json["depth"].as_u64().expect("depth"),
                status,
            }
        })
        .collect()
}

/// The calls of `function` among `calls`, in call-key order.
pub fn calls_of<'a>(calls: &'a [RecordedCall], function: &str) -> Vec<&'a RecordedCall> {
    calls.iter().filter(|c| c.name == function).collect()
}

/// Every step of the trace as (line, depth of the call that owns it).
pub fn step_lines_and_depths(out_dir: &Path) -> Vec<(u64, u64)> {
    let reader = open_trace(out_dir);
    (0..reader.step_count())
        .map(|n| {
            let (_path, line) = reader.step_location(n).expect("step_location");
            let call: serde_json::Value =
                serde_json::from_str(&reader.call_for_step_json(n).expect("call_for_step_json"))
                    .expect("call JSON");
            (line, call["depth"].as_u64().expect("depth"))
        })
        .collect()
}

/// Depth of the call that owns the last recorded step.
pub fn last_step_depth(out_dir: &Path) -> u64 {
    step_lines_and_depths(out_dir)
        .last()
        .expect("the trace has no steps")
        .1
}

/// Record `stem` through the launcher, assert it succeeded and that its
/// output contains `expect_stdout`, and return the output directory.
pub fn record_ok(shell: &Shell, stem: &str, expect_stdout: &str) -> TempDir {
    let (out, output) = run_launcher_with_built_writer(shell, &shell.fixture(stem));
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success(),
        "{} {stem}: launcher failed: stderr={stderr}",
        shell.interpreter
    );
    assert!(
        stdout.contains(expect_stdout),
        "{} {stem}: stdout should contain {expect_stdout:?}, got {stdout:?}",
        shell.interpreter
    );
    assert!(
        !stderr.contains(MISSING_EXIT_WARNING),
        "{} {stem}: writer warned of a missing EXIT event: {stderr}",
        shell.interpreter
    );
    out
}

/// Assert the recorder's raw event stream for `stem` has exactly one
/// `RETURN` for every `CALL`, and that no `RETURN` closes more than was
/// opened at any point (each prefix has at least as many CALLs). Returns
/// the run for further checks.
pub fn assert_stream_balanced(shell: &Shell, stem: &str) -> RecorderRun {
    let run = run_recorder(shell, &shell.fixture(stem));
    let mut open: i64 = 0;
    for (n, line) in run.events.iter().enumerate() {
        if line.starts_with("CALL ") {
            open += 1;
        } else if line.starts_with("RETURN ") {
            open -= 1;
            assert!(
                open >= 0,
                "{} {stem}: event {n} ({line}) returns from no open call; stream:\n{}",
                shell.interpreter,
                run.events.join("\n")
            );
        }
    }
    assert_eq!(
        open,
        0,
        "{} {stem}: every function CALL needs exactly one RETURN; stream:\n{}",
        shell.interpreter,
        run.events.join("\n")
    );
    run
}

/// Assert every call of `function` sits at `depth` and returns `Int` with
/// the statuses `statuses`, in order.
pub fn assert_calls(calls: &[RecordedCall], function: &str, depth: u64, statuses: &[i64]) {
    let found = calls_of(calls, function);
    assert_eq!(
        found.len(),
        statuses.len(),
        "expected {} calls of {function}; calls: {calls:?}",
        statuses.len()
    );
    for (n, (call, status)) in found.iter().zip(statuses).enumerate() {
        assert_eq!(
            call.depth,
            depth,
            "call {} of {function} should be at depth {depth} (a lower frame left open nests it deeper); calls: {calls:?}",
            n + 1
        );
        assert_eq!(
            call.status,
            Some(*status),
            "call {} of {function} should return Int {status}; calls: {calls:?}",
            n + 1
        );
    }
}

/// The issue's own reproduction: `functions.sh` / `functions.zsh` style
/// script calling a function in `$(...)` three times in a loop.
pub fn check_function_in_command_substitution_is_closed(shell: &Shell) {
    assert_stream_balanced(shell, "cmdsubst_loop");
    let out = record_ok(shell, "cmdsubst_loop", "last: 6");
    let calls = recorded_calls(out.path());
    assert_calls(&calls, "double", 2, &[0, 0, 0]);
    assert_eq!(
        last_step_depth(out.path()),
        1,
        "the top-level `echo \"last: $r\"` must be recorded at script depth 1, not inside a leaked double frame"
    );
    assert_int(
        &return_of(&call_returns(out.path()), "<script>"),
        0,
        "<script> should return the script's exit code",
    );
}

/// A function used as a condition records its own status, not the status
/// of the finished `if` statement.
pub fn check_function_used_as_condition_records_its_status(shell: &Shell) {
    assert_stream_balanced(shell, "condition_status");
    let out = record_ok(shell, "condition_status", "ok");
    let calls = recorded_calls(out.path());
    // `check no` returns 1 and is read only by `if`; `check yes` returns 0.
    assert_calls(&calls, "check", 2, &[1, 0]);
}

/// Control: the same functions called directly, status read by the next
/// command. This shape was recorded correctly before the fix too.
pub fn check_directly_called_function_return_is_recorded(shell: &Shell) {
    assert_stream_balanced(shell, "direct_calls");
    let out = record_ok(shell, "direct_calls", "last: 7");
    let calls = recorded_calls(out.path());
    assert_calls(&calls, "double", 2, &[0, 0, 0]);
    assert_calls(&calls, "seven", 2, &[7]);
    assert_eq!(last_step_depth(out.path()), 1);
}

/// `return $rc` and `return "$((x + 1))"`: the status is the value of the
/// argument, whether the call is in `$(...)` or used as a condition, and
/// statuses above 23 (CBOR's one-byte integers) are read correctly.
pub fn check_explicit_return_values(shell: &Shell) {
    assert_stream_balanced(shell, "return_values");
    let out = record_ok(shell, "return_values", "done");
    let calls = recorded_calls(out.path());
    assert_calls(&calls, "rc_of", 2, &[42, 3]);
    assert_calls(&calls, "plus_one", 2, &[200, 7]);
    assert_eq!(last_step_depth(out.path()), 1);
}

/// `outer() { local x=9; inner "$1"; }` with `inner` doing `return $x` on
/// its own local `x`: `outer` returns `inner`'s status, not the value of
/// its own `x`, directly, in `$(...)` and as a condition.
pub fn check_nested_returns(shell: &Shell) {
    assert_stream_balanced(shell, "nested_returns");
    let out = record_ok(shell, "nested_returns", "end");
    let calls = recorded_calls(out.path());
    assert_calls(&calls, "inner", 3, &[5, 6, 7, 8]);
    assert_calls(&calls, "outer", 2, &[5, 6, 7]);
    assert_calls(&calls, "outer1", 2, &[8]);
    assert_eq!(last_step_depth(out.path()), 1);
}

/// Recursion through `$(...)`: every level is closed, so each call sits one
/// level below its caller.
pub fn check_recursion_in_command_substitution(shell: &Shell) {
    assert_stream_balanced(shell, "recursion_cmdsubst");
    let out = record_ok(shell, "recursion_cmdsubst", "fact: 24");
    let calls = recorded_calls(out.path());
    let facts = calls_of(&calls, "fact");
    let depths: Vec<u64> = facts.iter().map(|c| c.depth).collect();
    assert_eq!(depths, vec![2, 3, 4, 5], "calls: {calls:?}");
    for c in &facts {
        assert_eq!(c.status, Some(0), "calls: {calls:?}");
    }
    assert_eq!(last_step_depth(out.path()), 1);
}

/// `exit` inside a function in `$(...)` ends only the subshell: the frames
/// the subshell opened are closed with the exit status, the parent goes on
/// at script depth, and the script's own exit is unaffected. The same for a
/// subshell that `set -e` ends inside a function.
pub fn check_exit_in_command_substitution(shell: &Shell) {
    let run = assert_stream_balanced(shell, "exit_in_cmdsubst");
    let exits: Vec<&String> = run
        .events
        .iter()
        .filter(|l| l.starts_with("EXIT "))
        .collect();
    assert_eq!(
        exits,
        vec!["EXIT code=0"],
        "stream:\n{}",
        run.events.join("\n")
    );
    let out = record_ok(shell, "exit_in_cmdsubst", "after: bailing bailing");
    let calls = recorded_calls(out.path());
    let bails = calls_of(&calls, "bail");
    assert_eq!(bails.len(), 2, "calls: {calls:?}");
    assert_eq!(
        (bails[0].depth, bails[0].status),
        (2, Some(3)),
        "calls: {calls:?}"
    );
    assert_eq!(
        (bails[1].depth, bails[1].status),
        (3, Some(3)),
        "calls: {calls:?}"
    );
    assert_calls(&calls, "wrap", 2, &[3]);
    assert_calls(&calls, "fails", 2, &[1]);
    // `quick() { builtin exit 5; }`: the `exit` is the first command the
    // function runs, so it is seen together with the CALL.
    assert_calls(&calls, "quick", 2, &[5]);
    assert_eq!(last_step_depth(out.path()), 1);
    assert_int(
        &return_of(&call_returns(out.path()), "<script>"),
        0,
        "<script> of exit_in_cmdsubst",
    );
}

/// `exit` inside a function in the recorder's own shell writes no `RETURN`
/// for that function: the `EXIT` event closes it, with the exit status
/// (spec "Script Exit"). Both after another command of the function and as
/// its first command.
pub fn check_main_shell_exit_in_function_writes_no_return(shell: &Shell) {
    for stem in ["exit_in_function", "exit_first_in_function"] {
        assert_main_shell_exit_writes_no_return(shell, stem);
    }
}

fn assert_main_shell_exit_writes_no_return(shell: &Shell, stem: &str) {
    let run = run_recorder(shell, &shell.fixture(stem));
    assert!(
        run.events.iter().any(|l| l == "CALL name=die"),
        "stream:\n{}",
        run.events.join("\n")
    );
    let returns: Vec<&String> = run
        .events
        .iter()
        .filter(|l| l.starts_with("RETURN "))
        .collect();
    assert!(
        returns.is_empty(),
        "{} {stem}: `exit` in the main shell must leave `die` to the EXIT event; stream:\n{}",
        shell.interpreter,
        run.events.join("\n")
    );
    assert_eq!(
        run.events.last().map(String::as_str),
        Some("EXIT code=4"),
        "{} {stem}",
        shell.interpreter
    );
}

/// Sourced files: a sourced file with commands that ends with `return 5`,
/// and a file holding only a function definition, sourced from inside a
/// function. Every opened frame is closed exactly once, the enclosing
/// function at its real end: its last step is still inside it.
pub fn check_sourced_file_returns(shell: &Shell, main_end_line: u64) {
    assert_stream_balanced(shell, "source_returns");
    let out = record_ok(shell, "source_returns", "top end");
    let calls = recorded_calls(out.path());
    assert!(
        calls
            .iter()
            .all(|c| c.status.is_some() || c.name == "<toplevel>"),
        "every frame must be closed with an Int; calls: {calls:?}"
    );
    // The sourced file's own frame: bash names it `source`, zsh by its path.
    let lib = format!("source_returns_lib.{}", shell.fixture_ext);
    let lib_frames: Vec<&RecordedCall> = calls
        .iter()
        .filter(|c| c.depth == 2 && (c.name == "source" || c.name.ends_with(&lib)))
        .collect();
    assert_eq!(lib_frames.len(), 1, "calls: {calls:?}");
    assert_eq!(
        lib_frames[0].status,
        Some(5),
        "the sourced file ends with `return 5`; calls: {calls:?}"
    );
    assert_calls(&calls, "helper", 3, &[0]);
    assert_calls(&calls, "main", 2, &[0]);
    assert_calls(&calls, "libf", 3, &[0]);
    let steps = step_lines_and_depths(out.path());
    // The fixtures are the script plus two libraries, so a line number alone
    // is ambiguous; the `echo "main end"` line is one only the script has.
    let main_end: Vec<&(u64, u64)> = steps.iter().filter(|(l, _)| *l == main_end_line).collect();
    assert!(
        !main_end.is_empty() && main_end.iter().all(|(_, d)| *d == 2),
        "`echo \"main end\"` (line {main_end_line}) must be recorded inside main (depth 2); steps: {steps:?}"
    );
    assert_eq!(last_step_depth(out.path()), 1, "steps: {steps:?}");
}

/// `g && h`: both functions of an AND list are recorded and closed (zsh
/// runs one `DEBUG` trap for the whole list, so no trap follows `g`).
pub fn check_and_list_calls(shell: &Shell) {
    assert_stream_balanced(shell, "and_list");
    let out = record_ok(shell, "and_list", "end");
    let calls = recorded_calls(out.path());
    assert_calls(&calls, "g", 2, &[0]);
    assert_calls(&calls, "h", 2, &[0]);
    assert_eq!(last_step_depth(out.path()), 1);
}

// ============================================================================
// Traps set by the recorded script
// ============================================================================
//
// Codetracer-pm issue
// `2026-11-15-shell-recorders-lose-events-when-the-script-sets-its-own-err-or-debug-trap`.
// Spec `Recording-Backends/Shell-Recorder.md`, "Limitations", "Signal
// Handler Conflicts": "If the script sets its own `DEBUG`, `RETURN`/`EXIT`,
// or `ERR`/`ZERR` traps ..., the recorder must chain them carefully to
// preserve script behavior while still capturing events."
//
// Two claims per fixture: the recorder keeps capturing (the events the
// recorder's own traps produce are all there), and the script behaves as it
// does without the recorder (its standard output is the same). The
// behaviour without the recorder is measured, not written down: each
// fixture is also run natively, in the environment the recorder gives a
// script (see `native_stdout`), and the two outputs are compared.

/// The text the recorders print to standard error, and record as an
/// `Error` event, when a trap of theirs was replaced behind their back.
pub const REPLACED_TRAP_WARNING: &str = "replaced the recorder's";

/// Run the fixture `stem` without the recorder, in the shell environment
/// the recorder gives the script, and return its standard output.
///
/// The bash recorder sources the script with `functrace`, `errtrace` and
/// `extdebug` on (`recorder.sh`), and those options change when Bash runs a
/// `DEBUG`, `RETURN` or `ERR` trap (they are inherited by functions and
/// subshells). The baseline sets the same options and sources the script
/// the same way, so that the comparison isolates the trap chaining. Zsh
/// options are left as they are: the zsh recorder only sets
/// `DEBUG_BEFORE_CMD`, which is on by default.
/// See: https://www.gnu.org/software/bash/manual/html_node/The-Shopt-Builtin.html (extdebug)
pub fn native_stdout(shell: &Shell, stem: &str) -> String {
    let fixture = shell.fixture(stem);
    let prelude = match shell.interpreter {
        "bash" => "set -o functrace -o errtrace; shopt -s extdebug; ",
        _ => "",
    };
    let output = Command::new(shell.interpreter)
        .current_dir(repo_root())
        .args([
            "-c",
            &format!(r#"{prelude}source "$1""#),
            shell.interpreter,
            fixture.to_str().unwrap(),
        ])
        .output()
        .expect("failed to run the fixture natively");
    String::from_utf8_lossy(&output.stdout).into_owned()
}

/// The text of every `Error` IO event of the trace in `out_dir`, in order.
/// The reader gives an event as `{"kind": "Error", "data": [bytes...]}`,
/// the text as its UTF-8 bytes.
pub fn recorded_error_texts(out_dir: &Path) -> Vec<String> {
    let reader = open_trace(out_dir);
    (0..reader.event_count())
        .filter_map(|n| {
            let json: serde_json::Value =
                serde_json::from_str(&reader.event_json(n).expect("event_json"))
                    .expect("event JSON");
            (json["kind"] == "Error").then(|| {
                let bytes: Vec<u8> = json["data"]
                    .as_array()
                    .map(|a| a.iter().map(|b| b.as_u64().expect("byte") as u8).collect())
                    .unwrap_or_default();
                String::from_utf8_lossy(&bytes).into_owned()
            })
        })
        .collect()
}

/// The `ERROR` lines of a recorder run's raw event stream.
pub fn wire_errors(run: &RecorderRun) -> Vec<&String> {
    run.events
        .iter()
        .filter(|l| l.starts_with("ERROR "))
        .collect()
}

/// For each `ERROR` line of a recorder run's raw event stream, the line of
/// the `STEP` before it: the command that failed.
pub fn error_step_lines(run: &RecorderRun) -> Vec<u64> {
    let mut last_step = 0;
    let mut lines = Vec::new();
    for event in &run.events {
        if event.starts_with("STEP ") {
            last_step = event
                .rsplit_once(" line=")
                .and_then(|(_, line)| line.parse().ok())
                .expect("STEP line");
        } else if event.starts_with("ERROR ") {
            lines.push(last_step);
        }
    }
    lines
}

/// Record `stem` through the launcher, assert that the script printed
/// exactly what it prints without the recorder (`native_stdout`) and that
/// the writer saw a complete stream, and return the output directory.
pub fn record_like_native(shell: &Shell, stem: &str) -> TempDir {
    let native = native_stdout(shell, stem);
    let (out, output) = run_launcher_with_built_writer(shell, &shell.fixture(stem));
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success(),
        "{} {stem}: launcher failed: stderr={stderr}",
        shell.interpreter
    );
    assert_eq!(
        stdout, native,
        "{} {stem}: the recorded script must print what it prints without the recorder; stderr={stderr}",
        shell.interpreter
    );
    for unexpected in [MISSING_EXIT_WARNING, REPLACED_TRAP_WARNING] {
        assert!(
            !stderr.contains(unexpected),
            "{} {stem}: unexpected warning {unexpected:?}: {stderr}",
            shell.interpreter
        );
    }
    out
}

/// The issue's first reproduction: two failing commands with the script's
/// own `ERR` / `ZERR` trap set between them. Both failures are recorded,
/// once each, in the raw stream and in the trace, and the script's handler
/// still runs (`handled`).
pub fn check_script_err_trap_keeps_capturing(shell: &Shell) {
    let run = assert_stream_balanced(shell, "trap_err");
    let errors = wire_errors(&run);
    assert_eq!(
        errors.len(),
        2,
        "{}: one ERROR per failing `false`; stream:\n{}",
        shell.interpreter,
        run.events.join("\n")
    );
    // The script's own handler still runs. `record_like_native` compares
    // with the native run; this names the issue's assertion directly.
    assert!(
        native_stdout(shell, "trap_err").contains("handled"),
        "{}: the fixture's own handler must print `handled` natively",
        shell.interpreter
    );
    let out = record_like_native(shell, "trap_err");
    let texts = recorded_error_texts(out.path());
    assert_eq!(
        texts.len(),
        2,
        "{}: the trace must hold two Error events; got {texts:?}",
        shell.interpreter
    );
}

/// The issue's second reproduction: a script that sets a `DEBUG` trap at
/// line 3 still has a step for each of lines 4, 5 and 6, in the raw stream
/// and in the trace.
pub fn check_script_debug_trap_keeps_capturing(shell: &Shell) {
    let run = assert_stream_balanced(shell, "trap_debug");
    for line in [4, 5, 6] {
        assert!(
            run.events
                .iter()
                .any(|l| l.starts_with("STEP ") && l.ends_with(&format!(" line={line}"))),
            "{}: no STEP for line {line}; stream:\n{}",
            shell.interpreter,
            run.events.join("\n")
        );
    }
    let out = record_like_native(shell, "trap_debug");
    let lines: Vec<u64> = step_lines_and_depths(out.path())
        .into_iter()
        .map(|(line, _)| line)
        .collect();
    for line in [4, 5, 6] {
        assert!(
            lines.contains(&line),
            "{}: the trace has no step at line {line}; steps: {lines:?}",
            shell.interpreter
        );
    }
}

/// The script's own `DEBUG` action keeps running, before each command, with
/// the command's text and the status before it, exactly as without the
/// recorder; the recorder records the commands it runs before.
pub fn check_script_debug_action_runs(shell: &Shell) {
    let out = record_like_native(shell, "trap_debug_handler");
    let lines: Vec<u64> = step_lines_and_depths(out.path())
        .into_iter()
        .map(|(line, _)| line)
        .collect();
    for line in [6, 7, 8, 9] {
        assert!(
            lines.contains(&line),
            "{}: the trace has no step at line {line}; steps: {lines:?}",
            shell.interpreter
        );
    }
}

/// `trap -` and `trap ''` on the error trap reset and ignore the script's
/// action only: the recorder still records all three failures, and the
/// script's handler runs for the first only.
pub fn check_script_trap_reset_and_ignore(shell: &Shell) {
    let run = assert_stream_balanced(shell, "trap_reset");
    assert_eq!(
        wire_errors(&run).len(),
        3,
        "{}: one ERROR per failing `false`; stream:\n{}",
        shell.interpreter,
        run.events.join("\n")
    );
    let out = record_like_native(shell, "trap_reset");
    assert_eq!(recorded_error_texts(out.path()).len(), 3);
}

/// Listing traps (`trap`, `trap -p` in Bash) shows the script its own
/// actions, never the recorder's, so a script that saves and restores a
/// trap (`saved=$(trap -p ERR)`, `eval "$saved"`) behaves as without it.
pub fn check_script_trap_listing(shell: &Shell) {
    assert_stream_balanced(shell, "trap_listing");
    record_like_native(shell, "trap_listing");
}

/// A trap of the recorder replaced behind its back (`builtin trap`, which
/// the recorder cannot intercept) must not leave a recording that looks
/// complete: the recorder warns on standard error and records an `Error`
/// event saying so. The script itself is unaffected.
pub fn check_replaced_trap_is_reported(shell: &Shell) {
    let (out, output) =
        run_launcher_with_built_writer(shell, &shell.fixture("trap_builtin_replaced"));
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success(),
        "{}: launcher failed: stderr={stderr}",
        shell.interpreter
    );
    assert_eq!(stdout, "end\n", "{}: stdout", shell.interpreter);
    assert!(
        stderr.contains(REPLACED_TRAP_WARNING) && stderr.contains("DEBUG"),
        "{}: the replaced DEBUG trap must be reported on stderr, got: {stderr}",
        shell.interpreter
    );
    let texts = recorded_error_texts(out.path());
    assert!(
        texts
            .iter()
            .any(|t| t.contains(REPLACED_TRAP_WARNING) && t.contains("DEBUG")),
        "{}: the trace must carry an Error event naming the replaced trap; errors: {texts:?}",
        shell.interpreter
    );
}

/// The script's own `EXIT` trap: in the recorder's shell it runs after the
/// recorder's, so a script that sets one and calls `exit` still ends its
/// event stream with the `EXIT` event, and the script's action still runs
/// with the exit status. A subshell runs its own `EXIT` trap, never the
/// parent's (which Bash shows a subshell but does not run there).
pub fn check_script_exit_trap(shell: &Shell) {
    assert_stream_balanced(shell, "trap_exit");
    assert_recorder_exit(shell, "trap_exit", 0);
    // The fixture is meaningful only if its EXIT action runs natively, once,
    // in the script's own shell.
    let native = native_stdout(shell, "trap_exit");
    assert_eq!(
        native.lines().filter(|l| *l == "bye 0").count(),
        1,
        "{}: natively, the script's EXIT action runs once, with status 0: {native:?}",
        shell.interpreter
    );
    record_like_native(shell, "trap_exit");
}

/// codetracer-pm issue
/// `2026-11-15-shell-recorders-print-their-event-stream-to-the-terminal-when-the-script-uses-fd-3`:
/// the script is sourced into the recorder's shell, so a script that
/// redirects or closes descriptor 3 for its own use must not take the
/// recorder's event channel with it (spec
/// `Recording-Backends/Shell-Recorder.md`, "Interactive Preservation": the
/// trace channel is "invisible to the script and the user").
///
/// For the fixture `stem` (five lines; line 2 does something to FD 3, line
/// 4 assigns `x=1`), recorded through the launcher:
///
/// - standard output is exactly the native run's, `progress` and `end`,
///   with no wire-protocol line in it;
/// - the trace has a step for every executable line, 2 to 5;
/// - the last step's variables include `x`;
/// - the writer saw the `EXIT` event (no missing-EXIT warning).
pub fn check_script_fd3_does_not_touch_the_trace_channel(shell: &Shell, stem: &str) {
    assert_eq!(
        native_stdout(shell, stem),
        "progress\nend\n",
        "{} {stem}: the fixture's native output",
        shell.interpreter
    );
    let out = record_like_native(shell, stem);
    let lines: Vec<u64> = step_lines_and_depths(out.path())
        .into_iter()
        .map(|(line, _)| line)
        .collect();
    for line in 2..=5 {
        assert!(
            lines.contains(&line),
            "{} {stem}: the trace has no step at line {line}; steps: {lines:?}",
            shell.interpreter
        );
    }
    let vars = last_step_vars(out.path());
    assert_string(
        var(&vars, "x"),
        "1",
        &format!("{} {stem}: `x` at the last step", shell.interpreter),
    );
}

// ============================================================================
// Paths and function names that need quoting on the wire
// ============================================================================
//
// Codetracer-pm issue
// `2026-11-15-shell-recorders-cannot-record-a-script-whose-path-contains-a-space`.
// The wire protocol ends an unquoted value at the first whitespace and
// carries a value with whitespace, `"` or `\` double-quoted, with `\"` and
// `\\` escapes (module comment of `src/wire_protocol.rs`; spec
// `Recording-Backends/Shell-Recorder.md`, "Wire Protocol (FD 3)"). A path
// or a function name is a value like any other: the recorders must quote
// it, or `START`, `PATH`, `FUNC`, `STEP` and `CALL` fail to parse and no
// trace is written.
//
// Each check writes its scripts into a fresh temporary directory, under a
// directory whose name carries the characters under test, and records them
// through the real launcher and the writer built for this test run.

/// A temporary directory holding scripts written by a test, and the
/// canonical path of its root (the launcher resolves the script's path, so
/// the expectations must use the resolved form: `/tmp` is a symlink on
/// macOS).
pub struct ScriptDir {
    _dir: TempDir,
    pub root: PathBuf,
}

impl ScriptDir {
    pub fn new() -> Self {
        let dir = TempDir::new().expect("failed to create temp dir");
        let root = std::fs::canonicalize(dir.path()).expect("canonical temp dir");
        ScriptDir { _dir: dir, root }
    }

    /// Write `body` to `<root>/<rel>`, creating its directories, and return
    /// the file's path.
    pub fn write(&self, rel: &str, body: &str) -> PathBuf {
        let path = self.root.join(rel);
        std::fs::create_dir_all(path.parent().unwrap()).expect("create script dir");
        std::fs::write(&path, body).expect("write script");
        path
    }
}

/// The path of `p` as the wire protocol and the trace carry it.
fn path_str(p: &Path) -> String {
    p.to_str().expect("UTF-8 path").to_string()
}

/// Parse every line of a recorder run's raw event stream with the writer's
/// own parser, failing on the first line it rejects.
pub fn parse_stream(shell: &Shell, run: &RecorderRun) -> Vec<WireEvent> {
    run.events
        .iter()
        .enumerate()
        .map(|(n, line)| {
            parse_line(line).unwrap_or_else(|e| {
                panic!(
                    "{}: event {} does not parse ({e}): {line}\nstream:\n{}",
                    shell.interpreter,
                    n + 1,
                    run.events.join("\n")
                )
            })
        })
        .collect()
}

/// Assert that every path in the parsed stream (`START program=`, `PATH`,
/// `FUNC` and `STEP` `file=`) is one of `expected`, and that `PATH`
/// registers each of `expected`: a path cut at a special character shows up
/// as a fragment that is none of them.
pub fn assert_stream_paths(shell: &Shell, events: &[WireEvent], expected: &[&Path]) {
    let expected: Vec<String> = expected.iter().map(|p| path_str(p)).collect();
    let mut registered = Vec::new();
    for event in events {
        let path = match event {
            WireEvent::Start { program, .. } => program,
            WireEvent::Path { file } => {
                registered.push(file.clone());
                file
            }
            WireEvent::Func { file, .. } | WireEvent::Step { file, .. } => file,
            _ => continue,
        };
        assert!(
            expected.contains(path),
            "{}: {event:?} carries a path that is not one of {expected:?}",
            shell.interpreter
        );
    }
    for path in &expected {
        assert!(
            registered.contains(path),
            "{}: no PATH event registers {path:?}; registered: {registered:?}",
            shell.interpreter
        );
    }
}

/// Record `main` through the launcher and assert the recording carries
/// every path in `sources` (with `main` first) exactly:
///
/// - the launcher succeeds, the script prints `expect_stdout`, and the
///   writer reports no parse error;
/// - the output directory holds exactly one `.ct`;
/// - the trace's program is `main`, its path table is exactly `sources`
///   with `main` first, and every step is in one of them;
/// - each source is copied to `files/<absolute path>` (`copy_source_files`
///   in `src/trace_bridge.rs`).
///
/// Returns the output directory for further checks.
pub fn assert_records_exact_paths(
    shell: &Shell,
    main: &Path,
    sources: &[&Path],
    expect_stdout: &str,
) -> TempDir {
    assert_eq!(
        sources.first(),
        Some(&main),
        "main must be the first source"
    );
    let main_str = path_str(main);
    let (out, output) = run_launcher_with_built_writer(shell, main);
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success(),
        "{} {main_str:?}: launcher failed: stderr={stderr}",
        shell.interpreter
    );
    assert!(
        !stderr.contains("parse error"),
        "writer reported parse errors for {main_str:?}:\n{stderr}"
    );
    assert!(
        stdout.contains(expect_stdout),
        "{} {main_str:?}: stdout should contain {expect_stdout:?}, got {stdout:?}",
        shell.interpreter
    );

    let cts: Vec<PathBuf> = std::fs::read_dir(out.path())
        .expect("failed to read the output dir")
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|ext| ext == "ct"))
        .collect();
    assert_eq!(
        cts.len(),
        1,
        "{} {main_str:?}: expected exactly one .ct in the output dir, found {cts:?}; stderr={stderr}",
        shell.interpreter
    );

    let reader = open_trace(out.path());
    assert_eq!(reader.program(), main_str, "program differs");
    let paths: Vec<String> = (0..reader.path_count())
        .map(|i| reader.path(i).expect("path entry"))
        .collect();
    let expected: Vec<String> = sources.iter().map(|p| path_str(p)).collect();
    assert_eq!(paths, expected, "the trace's path table differs");
    let steps = reader.step_count();
    assert!(steps > 0, "{} {main_str:?}: no steps", shell.interpreter);
    for n in 0..steps {
        let (path_id, line) = reader.step_location(n).expect("step_location");
        let path = reader.path(path_id).expect("step path");
        assert!(
            expected.contains(&path),
            "step {n} at {path:?}:{line} is in none of {expected:?}"
        );
    }
    drop(reader);

    for source in sources {
        let copy = out
            .path()
            .join("files")
            .join(source.strip_prefix("/").unwrap_or(source));
        assert!(copy.is_file(), "no copy of {source:?} at {copy:?}");
    }
    out
}

/// The shebang line of a script for `shell`.
fn shebang(shell: &Shell) -> String {
    format!("#!/usr/bin/env {}\n", shell.interpreter)
}

/// The issue's reproduction: a three-line script in a directory named
/// `dir_name` is recorded with its exact path, and the raw stream parses
/// line by line and names no other path.
pub fn check_records_script_in_dir(shell: &Shell, dir_name: &str) {
    let dir = ScriptDir::new();
    let script = dir.write(
        &format!("{dir_name}/deploy.{}", shell.fixture_ext),
        &format!("{}x=1\necho \"ran\"\n", shebang(shell)),
    );
    let out = assert_records_exact_paths(shell, &script, &[&script], "ran");
    let run = run_recorder(shell, &script);
    let events = parse_stream(shell, &run);
    assert_stream_paths(shell, &events, &[&script]);
    let lines: Vec<u64> = step_lines_and_depths(out.path())
        .into_iter()
        .map(|(line, _)| line)
        .collect();
    assert!(
        lines.contains(&2) && lines.contains(&3),
        "{}: steps at lines 2 and 3 expected, got {lines:?}",
        shell.interpreter
    );
}

/// A sourced file whose path has a space, from a main script whose path has
/// none: the sourced file is registered whole, its steps and its function's
/// `FUNC` event name it, and its function is recorded.
pub fn check_records_sourced_file_with_space(shell: &Shell) {
    let dir = ScriptDir::new();
    let ext = shell.fixture_ext;
    let lib = dir.write(
        &format!("lib dir/my lib.{ext}"),
        &format!(
            "{}lib_func() {{\n    echo \"from lib\"\n}}\n",
            shebang(shell)
        ),
    );
    let main = dir.write(
        &format!("plain_dir/main.{ext}"),
        &format!(
            "{}source \"{}\"\nlib_func\necho \"done\"\n",
            shebang(shell),
            path_str(&lib)
        ),
    );

    let out = assert_records_exact_paths(shell, &main, &[&main, &lib], "from lib");
    let calls = recorded_calls(out.path());
    assert_eq!(
        calls_of(&calls, "lib_func").len(),
        1,
        "{}: lib_func should be called once; calls: {calls:?}",
        shell.interpreter
    );

    let run = run_recorder(shell, &main);
    let events = parse_stream(shell, &run);
    assert_stream_paths(shell, &events, &[&main, &lib]);
    let lib_str = path_str(&lib);
    assert!(
        events.iter().any(|e| matches!(
            e,
            WireEvent::Func { name, file, .. } if name == "lib_func" && *file == lib_str
        )),
        "{}: no FUNC event for lib_func in {lib_str:?}; stream:\n{}",
        shell.interpreter,
        run.events.join("\n")
    );
    assert!(
        events
            .iter()
            .any(|e| matches!(e, WireEvent::Step { file, .. } if *file == lib_str)),
        "{}: no STEP in the sourced file; stream:\n{}",
        shell.interpreter,
        run.events.join("\n")
    );
}

/// A function defined and called in a script whose path has a space: its
/// `FUNC` event carries the script's exact path, the `CALL` names it, the
/// argument with a space arrives whole, and the trace holds the call.
/// `define` is the definition line, `call` the call, `name` the function's
/// name as the shell reports it.
pub fn check_records_function_in_dir_with_space(
    shell: &Shell,
    name: &str,
    define: &str,
    call: &str,
) {
    let dir = ScriptDir::new();
    let script = dir.write(
        &format!("my scripts/funcs.{}", shell.fixture_ext),
        &format!(
            "{}{define}\n    echo \"hello $1\"\n}}\n{call} \"a b\"\necho \"done\"\n",
            shebang(shell)
        ),
    );
    let script_str = path_str(&script);

    let out = assert_records_exact_paths(shell, &script, &[&script], "hello a b");
    let calls = recorded_calls(out.path());
    assert_calls(&calls, name, 2, &[0]);
    let lines: Vec<u64> = step_lines_and_depths(out.path())
        .into_iter()
        .map(|(line, _)| line)
        .collect();
    assert!(
        lines.contains(&3),
        "{}: the function body (line 3) has no step; steps: {lines:?}",
        shell.interpreter
    );

    let run = run_recorder(shell, &script);
    let events = parse_stream(shell, &run);
    assert_stream_paths(shell, &events, &[&script]);
    let funcs: Vec<&WireEvent> = events
        .iter()
        .filter(|e| matches!(e, WireEvent::Func { name: n, .. } if n == name))
        .collect();
    assert!(
        matches!(funcs.as_slice(), [WireEvent::Func { file, .. }] if *file == script_str),
        "{}: expected one FUNC event for {name:?} in {script_str:?}, got {funcs:?}",
        shell.interpreter
    );
    assert!(
        events
            .iter()
            .any(|e| matches!(e, WireEvent::Call { name: n } if n == name)),
        "{}: no CALL of {name:?}; stream:\n{}",
        shell.interpreter,
        run.events.join("\n")
    );
    assert!(
        events.iter().any(|e| matches!(
            e,
            WireEvent::Arg { name: n, value, .. } if n == "$1" && value == "a b"
        )),
        "{}: no ARG $1=\"a b\"; stream:\n{}",
        shell.interpreter,
        run.events.join("\n")
    );
}
