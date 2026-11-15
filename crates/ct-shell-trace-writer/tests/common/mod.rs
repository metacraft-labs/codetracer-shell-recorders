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

    // (c) Non-zero exits. The launcher does not yet write a trace for a
    // non-zero exit (a separate defect), so the recorder's event file is fed
    // to the writer directly, exactly as the launcher would.
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
