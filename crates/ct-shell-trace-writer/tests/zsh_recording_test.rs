// Test that the zsh recorder produces valid trace files.
//
// The Nim CTFS backend always produces a binary `.ct` container file.
// Tests verify the container exists, has valid CTFS magic bytes, and
// expose the expected program / paths via the Nim reader.  Legacy
// `trace_metadata.json` / `trace_paths.json` sidecars were retired with
// the v3 CTFS rollout (follow-up #254 phase 2); the `symbols.json`
// sidecar is still emitted for shell-script consumers.
use std::path::PathBuf;
use std::process::Command;

use codetracer_trace_types::ValueRecord;
use codetracer_trace_writer_nim::NimTraceReaderHandle;
use tempfile::TempDir;

mod common;

/// CTFS magic bytes: 0xC0 0xDE 0x72 0xAC 0xE2
const CTFS_MAGIC: &[u8] = &[0xC0, 0xDE, 0x72, 0xAC, 0xE2];

/// Check if zsh is available on the system. Returns true if it is.
fn zsh_available() -> bool {
    Command::new("zsh")
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Macro to skip tests when zsh is not available.
macro_rules! require_zsh {
    () => {
        if !zsh_available() {
            eprintln!("SKIPPED: zsh not available on this system");
            return;
        }
    };
}

fn launcher_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap() // crates/
        .parent()
        .unwrap() // repo root
        .join("zsh-recorder/launcher.zsh")
}

fn fixture_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("tests/fixtures/zsh")
        .join(name)
}

fn build_trace_writer() -> PathBuf {
    let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .to_path_buf();

    let build_status = Command::new("cargo")
        .args(["build"])
        .current_dir(&repo_root)
        .status()
        .expect("Failed to build");
    assert!(build_status.success(), "cargo build failed");

    repo_root
}

/// Run the zsh recorder on a fixture and return (output_dir, stdout, stderr).
fn record_fixture(fixture: &str) -> (TempDir, String, String) {
    build_trace_writer();

    let output_dir = TempDir::new().expect("Failed to create temp dir");

    let output = Command::new("zsh")
        .args([
            launcher_path().to_str().unwrap(),
            "--out-dir",
            output_dir.path().to_str().unwrap(),
            fixture_path(fixture).to_str().unwrap(),
        ])
        .output()
        .expect("Failed to run launcher");

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();

    assert!(
        output.status.success(),
        "Launcher exited with non-zero status for {}: stderr={}",
        fixture,
        stderr
    );

    (output_dir, stdout, stderr)
}

/// Find a `.ct` file in the output directory and verify it has valid CTFS magic bytes.
/// Returns the path to the `.ct` file.
fn find_ct_file(output_dir: &TempDir) -> PathBuf {
    let entries: Vec<PathBuf> = std::fs::read_dir(output_dir.path())
        .expect("Failed to read output dir")
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().map_or(false, |ext| ext == "ct"))
        .collect();

    assert!(
        !entries.is_empty(),
        "No .ct files found in output dir. Files present: {:?}",
        std::fs::read_dir(output_dir.path())
            .map(|rd| rd
                .filter_map(|e| e.ok().map(|e| e.file_name()))
                .collect::<Vec<_>>())
            .unwrap_or_default()
    );
    assert_eq!(
        entries.len(),
        1,
        "Expected exactly one .ct file, found: {:?}",
        entries
    );

    let ct_path = &entries[0];
    let data = std::fs::read(ct_path).expect("Failed to read .ct file");
    assert!(
        data.len() >= CTFS_MAGIC.len(),
        ".ct file is too small ({} bytes) to contain CTFS magic",
        data.len()
    );
    assert_eq!(
        &data[..CTFS_MAGIC.len()],
        CTFS_MAGIC,
        ".ct file does not start with CTFS magic bytes"
    );

    ct_path.clone()
}

/// Read the registered source paths from the `.ct` container produced
/// by the recorder.  The legacy `trace_paths.json` sidecar was retired
/// with the v3 CTFS rollout — paths are now interned in the container's
/// paths stream.
fn read_trace_paths(output_dir: &TempDir) -> Vec<String> {
    let ct_path = find_ct_file(output_dir);
    let reader = NimTraceReaderHandle::open(ct_path.to_str().expect("ct path must be UTF-8"))
        .expect("Failed to open .ct container");
    (0..reader.path_count())
        .map(|i| reader.path(i).expect("Failed to read path entry"))
        .collect()
}

/// Read the recorded program path from the `.ct` container's metadata.
fn read_trace_program(output_dir: &TempDir) -> String {
    let ct_path = find_ct_file(output_dir);
    let reader = NimTraceReaderHandle::open(ct_path.to_str().expect("ct path must be UTF-8"))
        .expect("Failed to open .ct container");
    reader.program()
}

// ============================================================================
// Zsh Recording Tests
// ============================================================================

#[test]
fn test_zsh_step_events() {
    require_zsh!();
    let (output_dir, stdout, _stderr) = record_fixture("simple.zsh");

    // Verify script produced expected output
    assert!(
        stdout.contains("Result: 30"),
        "Expected 'Result: 30' in stdout, got: {}",
        stdout
    );

    // Verify .ct container exists with valid CTFS magic
    let ct_path = find_ct_file(&output_dir);
    let ct_size = std::fs::metadata(&ct_path).unwrap().len();
    assert!(ct_size > 0, ".ct file is empty");

    // Verify the script path appears in the .ct container's paths stream
    let paths = read_trace_paths(&output_dir);
    assert!(!paths.is_empty(), "paths should not be empty");
    let has_simple = paths.iter().any(|p| p.contains("simple.zsh"));
    assert!(has_simple, "paths should contain simple.zsh: {:?}", paths);

    // Verify the .ct container records the script as the program
    let program = read_trace_program(&output_dir);
    assert!(
        program.contains("simple.zsh"),
        "Program should reference simple.zsh, got: {}",
        program
    );
}

#[test]
fn test_zsh_function_call_return() {
    require_zsh!();
    let (output_dir, stdout, _stderr) = record_fixture("functions.zsh");

    // Verify script produced expected output
    assert!(
        stdout.contains("Hello, World!"),
        "Expected 'Hello, World!' in stdout, got: {}",
        stdout
    );
    assert!(
        stdout.contains("Sum: 7"),
        "Expected 'Sum: 7' in stdout, got: {}",
        stdout
    );

    // Verify .ct container exists and is reasonably sized
    let ct_path = find_ct_file(&output_dir);
    let ct_size = std::fs::metadata(&ct_path).unwrap().len();
    assert!(
        ct_size >= 1024,
        ".ct file should be at least 1KB for a script with functions, got {} bytes",
        ct_size
    );

    // Verify symbols.json contains function names
    let symbols_json = output_dir.path().join("symbols.json");
    assert!(symbols_json.exists(), "symbols.json not found");
    let symbols: Vec<String> = serde_json::from_str(
        &std::fs::read_to_string(&symbols_json).expect("Failed to read symbols.json"),
    )
    .expect("Invalid symbols.json");

    assert!(
        symbols.iter().any(|s| s == "greet"),
        "symbols.json should contain 'greet', found: {:?}",
        symbols
    );
    assert!(
        symbols.iter().any(|s| s == "add"),
        "symbols.json should contain 'add', found: {:?}",
        symbols
    );
}

#[test]
fn test_zsh_variable_capture() {
    require_zsh!();
    let (output_dir, stdout, _stderr) = record_fixture("variables.zsh");

    // Verify script produced expected output
    assert!(
        stdout.contains("hello world 52"),
        "Expected 'hello world 52' in stdout, got: {}",
        stdout
    );

    // Verify .ct container exists and is reasonably sized (contains variable events)
    let ct_path = find_ct_file(&output_dir);
    let ct_size = std::fs::metadata(&ct_path).unwrap().len();
    assert!(
        ct_size >= 1024,
        ".ct file should be at least 1KB for a script with variables, got {} bytes",
        ct_size
    );
}

/// Environment for the exported-variable tests: an inherited `HOME` the test
/// controls, so that "HOME is not recorded" is a claim about a variable that
/// really is in the script's environment, and one more inherited variable
/// whose name no shell defines for itself.
fn inherited_env(home: &TempDir) -> [(&str, &str); 2] {
    [
        ("HOME", home.path().to_str().unwrap()),
        ("CT_INHERITED_MARKER", "inherited"),
    ]
}

/// Assert no variable inherited from the environment of `inherited_env` was
/// reported as a variable of the script.
fn assert_no_inherited_vars(vars: &[(String, ValueRecord)], what: &str) {
    for name in ["HOME", "CT_INHERITED_MARKER"] {
        assert!(
            common::var(vars, name).is_none(),
            "{what}: the inherited {name} must not be recorded as a variable of the script; \
             recorded: {:?}",
            common::var_names(vars)
        );
    }
}

/// Record `script` through `shell`'s launcher, with `inherited_env` added to
/// its environment, and return the variables of its last step.
fn record_last_step_vars(
    shell: &common::Shell,
    script: &std::path::Path,
) -> Vec<(String, ValueRecord)> {
    build_trace_writer();
    let home = TempDir::new().expect("failed to create temp dir");
    let (out, output) = common::run_launcher_with_env(shell, script, &inherited_env(&home));
    assert!(
        output.status.success(),
        "{} launcher failed on {}: {}",
        shell.interpreter,
        script.display(),
        String::from_utf8_lossy(&output.stderr)
    );
    common::last_step_vars(out.path())
}

// Issue `2026-11-15-zsh-recorder-does-not-record-exported-variables`: zsh's
// `typeset -p` prints an exported parameter with the keyword `export`, and
// the recorder accepted only `typeset` lines, so an exported variable of the
// script was never recorded. Spec `Recording-Backends/Shell-Recorder.md`,
// "Variable Capture": exported (`-x`) and other attributes do not affect the
// type mapping.
#[test]
fn test_zsh_exported_variable_capture() {
    require_zsh!();
    let vars = record_last_step_vars(&common::ZSH, &fixture_path("exported_variables.zsh"));

    // `export DEPLOY_ENV=staging` is recorded, with its exact text.
    common::assert_string(
        common::var(&vars, "DEPLOY_ENV"),
        "staging",
        "DEPLOY_ENV at the last step",
    );
    // An inherited environment variable is not a variable of the script.
    assert_no_inherited_vars(&vars, "zsh exported_variables");
    // The non-exported variables are still recorded.
    assert!(
        common::var(&vars, "plain").is_some(),
        "plain missing at the last step: {:?}",
        common::var_names(&vars)
    );
    assert!(
        common::var(&vars, "FIXED").is_some(),
        "FIXED missing at the last step: {:?}",
        common::var_names(&vars)
    );
}

// The type of an exported parameter comes from its type flag, as for any
// other parameter (spec `Recording-Backends/Shell-Recorder.md`, "Variable
// Capture": exported (`-x`) attributes do not affect the type mapping). Each
// exported parameter must carry the same trace type as a non-exported one of
// the same zsh type: `export -i`, `export -F`, an exported array, and
// `typeset -gx` inside a function (printed `export`, like a plain string).
#[test]
fn test_zsh_exported_variable_types() {
    require_zsh!();
    let vars = record_last_step_vars(&common::ZSH, &fixture_path("exported_typed.zsh"));
    let get = |name: &str| {
        common::var(&vars, name).unwrap_or_else(|| {
            panic!(
                "{name} not recorded at the last step: {:?}",
                common::var_names(&vars)
            )
        })
    };

    common::assert_int(get("COUNT"), 3, "COUNT (export -i)");
    match get("RATIO") {
        ValueRecord::Float { f, .. } if *f == 1.5 => {}
        other => panic!("RATIO (export -F): expected Float 1.5, got {other:?}"),
    }
    // Arrays are recorded as their `typeset -p` text (trace_bridge.rs
    // `value_record_for_flag`), under the Array type.
    common::assert_string(Some(get("LIST")), "( 1 2 )", "LIST (typeset -ax)");
    common::assert_string(
        Some(get("FROM_FN")),
        "fn",
        "FROM_FN (typeset -gx in a function)",
    );

    for (exported, plain) in [
        ("COUNT", "plain_count"),
        ("RATIO", "plain_ratio"),
        ("LIST", "plain_list"),
        ("FROM_FN", "plain_str"),
    ] {
        assert_eq!(
            type_id_of(get(exported)),
            type_id_of(get(plain)),
            "{exported} must have the trace type of the non-exported {plain}: {:?} vs {:?}",
            get(exported),
            get(plain)
        );
    }
    assert_no_inherited_vars(&vars, "zsh exported_typed");
}

/// The trace type of a scalar value record.
fn type_id_of(value: &ValueRecord) -> u64 {
    match value {
        ValueRecord::Int { type_id, .. }
        | ValueRecord::Float { type_id, .. }
        | ValueRecord::String { type_id, .. } => type_id.0 as u64,
        other => panic!("unexpected value record {other:?}"),
    }
}

#[test]
fn test_zsh_error_handling() {
    require_zsh!();
    let (output_dir, stdout, _stderr) = record_fixture("errors.zsh");

    // The script should finish and print "done"
    assert!(
        stdout.contains("done"),
        "Expected 'done' in stdout (script should complete despite errors), got: {}",
        stdout
    );

    // Verify .ct container exists and has valid CTFS magic
    let ct_path = find_ct_file(&output_dir);
    let ct_size = std::fs::metadata(&ct_path).unwrap().len();
    assert!(
        ct_size >= 1024,
        ".ct file should be at least 1KB for error-handling script, got {} bytes",
        ct_size
    );
}

#[test]
fn test_zsh_output_capture() {
    require_zsh!();
    let (output_dir, stdout, _stderr) = record_fixture("output.zsh");

    // Verify script produced expected output
    assert!(
        stdout.contains("Hello from zsh"),
        "Expected 'Hello from zsh' in stdout, got: {}",
        stdout
    );
    assert!(
        stdout.contains("Echo test"),
        "Expected 'Echo test' in stdout, got: {}",
        stdout
    );
    assert!(
        stdout.contains("Formatted: 42"),
        "Expected 'Formatted: 42' in stdout, got: {}",
        stdout
    );

    // Verify .ct container exists and has valid CTFS magic
    let ct_path = find_ct_file(&output_dir);
    let ct_size = std::fs::metadata(&ct_path).unwrap().len();
    assert!(
        ct_size >= 1024,
        ".ct file should be at least 1KB for output-producing script, got {} bytes",
        ct_size
    );
}

#[test]
fn test_zsh_exit_code() {
    require_zsh!();
    build_trace_writer();
    // The script's exit code reaches the event stream and the trace however
    // the script ends: off its last line, with `exit 0`, `exit 3`, or `exit`
    // inside a function. See `common::check_exit_codes` for the claims.
    common::check_exit_codes(&common::ZSH);
}

// The launcher writes the trace and passes the status through when the
// script ends non-zero. See `common::check_nonzero_exit_keeps_trace`.

#[test]
fn test_zsh_trace_written_when_script_calls_exit_nonzero() {
    require_zsh!();
    common::check_nonzero_exit_keeps_trace(&common::ZSH, "exit_three", 3, 4);
}

#[test]
fn test_zsh_trace_written_when_last_command_fails() {
    require_zsh!();
    common::check_nonzero_exit_keeps_trace(&common::ZSH, "exit_status_last_command", 1, 5);
}

#[test]
fn test_zsh_trace_written_when_errexit_stops_the_script() {
    require_zsh!();
    common::check_nonzero_exit_keeps_trace(&common::ZSH, "exit_status_errexit", 1, 7);
}

#[test]
fn e2e_zsh_metadata() {
    require_zsh!();
    let (output_dir, _stdout, _stderr) = record_fixture("simple.zsh");

    // Read trace_db_metadata.json
    let db_metadata_json = output_dir.path().join("trace_db_metadata.json");
    assert!(
        db_metadata_json.exists(),
        "trace_db_metadata.json not found"
    );
    let db_meta: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(&db_metadata_json).expect("Failed to read trace_db_metadata.json"),
    )
    .expect("Invalid trace_db_metadata.json");

    // Verify: language="zsh"
    assert_eq!(
        db_meta["language"].as_str(),
        Some("zsh"),
        "language should be 'zsh', got: {:?}",
        db_meta["language"]
    );

    // Verify: program contains "simple.zsh"
    let program = db_meta["program"]
        .as_str()
        .expect("program field should be a string");
    assert!(
        program.contains("simple.zsh"),
        "program should contain 'simple.zsh', got: {}",
        program
    );

    // Verify: zsh_version is non-empty
    let zsh_version = db_meta["zsh_version"]
        .as_str()
        .expect("zsh_version field should be a string");
    assert!(!zsh_version.is_empty(), "zsh_version should be non-empty");
    // Should look like a version number (e.g., 5.9)
    assert!(
        zsh_version.contains('.'),
        "zsh_version should contain a dot (version number), got: {}",
        zsh_version
    );

    // Verify: recorder field
    let recorder = db_meta["recorder"]
        .as_str()
        .expect("recorder field should be a string");
    assert_eq!(
        recorder, "codetracer-zsh-recorder",
        "recorder should be 'codetracer-zsh-recorder', got: {}",
        recorder
    );

    // Verify: workdir is non-empty
    let workdir = db_meta["workdir"]
        .as_str()
        .expect("workdir field should be a string");
    assert!(!workdir.is_empty(), "workdir should be non-empty");

    // Verify: args is an array
    assert!(
        db_meta["args"].is_array(),
        "args should be an array, got: {:?}",
        db_meta["args"]
    );
}

#[test]
fn e2e_zsh_symbols() {
    require_zsh!();
    let (output_dir, _stdout, _stderr) = record_fixture("functions.zsh");

    // Verify symbols.json exists and contains function names
    let symbols_json = output_dir.path().join("symbols.json");
    assert!(symbols_json.exists(), "symbols.json not found");
    let symbols: Vec<String> = serde_json::from_str(
        &std::fs::read_to_string(&symbols_json).expect("Failed to read symbols.json"),
    )
    .expect("Invalid symbols.json");

    assert!(
        symbols.iter().any(|s| s == "greet"),
        "symbols.json should contain 'greet', found: {:?}",
        symbols
    );
    assert!(
        symbols.iter().any(|s| s == "add"),
        "symbols.json should contain 'add', found: {:?}",
        symbols
    );
}

#[test]
fn e2e_zsh_source_files_copy() {
    require_zsh!();
    let (output_dir, _stdout, _stderr) = record_fixture("simple.zsh");

    // Verify files/ directory exists with source file copy
    let files_dir = output_dir.path().join("files");
    assert!(files_dir.exists(), "files/ directory not found");
    assert!(files_dir.is_dir(), "files/ should be a directory");

    // Verify the source file was copied — it should be under files/<absolute-path>
    let fixture = fixture_path("simple.zsh");
    let copied = files_dir.join(fixture.strip_prefix("/").unwrap_or(&fixture));
    assert!(
        copied.exists(),
        "Source file copy not found at expected path: {}",
        copied.display()
    );

    // Verify the copied file has the same content as the original
    let original_content =
        std::fs::read_to_string(&fixture).expect("Failed to read original simple.zsh");
    let copied_content =
        std::fs::read_to_string(&copied).expect("Failed to read copied simple.zsh");
    assert_eq!(
        original_content, copied_content,
        "Copied source file content should match original"
    );
}

#[test]
fn e2e_zsh_builtin_filtering() {
    require_zsh!();
    let (output_dir, _stdout, _stderr) = record_fixture("simple.zsh");

    // Verify .ct container exists — builtin filtering is verified inside the
    // binary container events. Detailed event parsing is covered by
    // integration_test.rs via the wire protocol + TraceBridge pipeline.
    let ct_path = find_ct_file(&output_dir);
    let ct_size = std::fs::metadata(&ct_path).unwrap().len();
    assert!(
        ct_size >= 1024,
        ".ct file should be at least 1KB, got {} bytes",
        ct_size
    );
}

// ============================================================================
// M9: Zsh End-to-End Validation & CLI Integration Tests
// ============================================================================

fn cross_shell_fixture_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("tests/fixtures/cross_shell")
        .join(name)
}

fn bash_launcher_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("bash-recorder/launcher.sh")
}

/// Run the bash recorder on a cross-shell fixture and return (output_dir, stdout, stderr).
fn record_bash_fixture(fixture: &str) -> (TempDir, String, String) {
    build_trace_writer();

    let output_dir = TempDir::new().expect("Failed to create temp dir");

    let output = Command::new("bash")
        .args([
            bash_launcher_path().to_str().unwrap(),
            "--out-dir",
            output_dir.path().to_str().unwrap(),
            cross_shell_fixture_path(fixture).to_str().unwrap(),
        ])
        .output()
        .expect("Failed to run bash launcher");

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();

    assert!(
        output.status.success(),
        "Bash launcher exited with non-zero status for {}: stderr={}",
        fixture,
        stderr
    );

    (output_dir, stdout, stderr)
}

/// Run the zsh recorder on a cross-shell fixture and return (output_dir, stdout, stderr).
fn record_zsh_cross_fixture(fixture: &str) -> (TempDir, String, String) {
    build_trace_writer();

    let output_dir = TempDir::new().expect("Failed to create temp dir");

    let output = Command::new("zsh")
        .args([
            launcher_path().to_str().unwrap(),
            "--out-dir",
            output_dir.path().to_str().unwrap(),
            cross_shell_fixture_path(fixture).to_str().unwrap(),
        ])
        .output()
        .expect("Failed to run zsh launcher");

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();

    assert!(
        output.status.success(),
        "Zsh launcher exited with non-zero status for {}: stderr={}",
        fixture,
        stderr
    );

    (output_dir, stdout, stderr)
}

#[test]
fn test_zsh_sourced_file() {
    require_zsh!();
    let (output_dir, stdout, _stderr) = record_fixture("with_source.zsh");

    // Verify script produced expected output from sourced function and main script
    assert!(
        stdout.contains("lib: hello"),
        "Expected 'lib: hello' in stdout (from lib_func call), got: {}",
        stdout
    );
    assert!(
        stdout.contains("y=15"),
        "Expected 'y=15' in stdout, got: {}",
        stdout
    );
    assert!(
        stdout.contains("LIB_VAR=from_zsh_lib"),
        "Expected 'LIB_VAR=from_zsh_lib' in stdout, got: {}",
        stdout
    );

    // Verify the .ct container's paths stream contains BOTH files
    let paths = read_trace_paths(&output_dir);

    let has_with_source = paths.iter().any(|p| p.contains("with_source.zsh"));
    assert!(
        has_with_source,
        "paths should contain with_source.zsh: {:?}",
        paths
    );

    let has_sourced_lib = paths.iter().any(|p| p.contains("zsh_sourced_lib.zsh"));
    assert!(
        has_sourced_lib,
        "paths should contain zsh_sourced_lib.zsh (the sourced file): {:?}",
        paths
    );

    // Verify .ct container exists
    let ct_path = find_ct_file(&output_dir);
    let ct_size = std::fs::metadata(&ct_path).unwrap().len();
    assert!(
        ct_size >= 1024,
        ".ct file should be at least 1KB for sourced-file script, got {} bytes",
        ct_size
    );

    // Verify symbols.json contains function from sourced file
    let symbols_json = output_dir.path().join("symbols.json");
    assert!(symbols_json.exists(), "symbols.json not found");
    let symbols: Vec<String> = serde_json::from_str(
        &std::fs::read_to_string(&symbols_json).expect("Failed to read symbols.json"),
    )
    .expect("Invalid symbols.json");
    assert!(
        symbols.iter().any(|s| s == "lib_func"),
        "symbols.json should contain 'lib_func', found: {:?}",
        symbols
    );

    // Verify both source files are copied to files/ directory
    let files_dir = output_dir.path().join("files");
    assert!(files_dir.exists(), "files/ directory not found");

    let with_source_fixture = fixture_path("with_source.zsh");
    let copied_with_source = files_dir.join(
        with_source_fixture
            .strip_prefix("/")
            .unwrap_or(&with_source_fixture),
    );
    assert!(
        copied_with_source.exists(),
        "with_source.zsh copy not found at: {}",
        copied_with_source.display()
    );

    let sourced_lib_fixture = fixture_path("zsh_sourced_lib.zsh");
    let copied_sourced_lib = files_dir.join(
        sourced_lib_fixture
            .strip_prefix("/")
            .unwrap_or(&sourced_lib_fixture),
    );
    assert!(
        copied_sourced_lib.exists(),
        "zsh_sourced_lib.zsh copy not found at: {}",
        copied_sourced_lib.display()
    );

    // Verify content matches for both files
    let original_ws =
        std::fs::read_to_string(&with_source_fixture).expect("Failed to read with_source.zsh");
    let copied_ws = std::fs::read_to_string(&copied_with_source)
        .expect("Failed to read copied with_source.zsh");
    assert_eq!(
        original_ws, copied_ws,
        "with_source.zsh content should match"
    );

    let original_sl =
        std::fs::read_to_string(&sourced_lib_fixture).expect("Failed to read zsh_sourced_lib.zsh");
    let copied_sl = std::fs::read_to_string(&copied_sourced_lib)
        .expect("Failed to read copied zsh_sourced_lib.zsh");
    assert_eq!(
        original_sl, copied_sl,
        "zsh_sourced_lib.zsh content should match"
    );
}

#[test]
fn e2e_zsh_complex_script() {
    require_zsh!();
    let (output_dir, stdout, _stderr) = record_fixture("comprehensive.zsh");

    // Verify script produced expected output
    assert!(
        stdout.contains("Processing: alpha (#1)"),
        "Expected 'Processing: alpha (#1)' in stdout, got: {}",
        stdout
    );
    assert!(
        stdout.contains("Processing: beta (#2)"),
        "Expected 'Processing: beta (#2)' in stdout, got: {}",
        stdout
    );
    assert!(
        stdout.contains("Processing: gamma (#3)"),
        "Expected 'Processing: gamma (#3)' in stdout, got: {}",
        stdout
    );
    assert!(
        stdout.contains("lib: done"),
        "Expected 'lib: done' in stdout (from lib_func call), got: {}",
        stdout
    );
    assert!(
        stdout.contains("count=3"),
        "Expected 'count=3' in stdout, got: {}",
        stdout
    );
    assert!(
        stdout.contains("pi="),
        "Expected 'pi=' in stdout, got: {}",
        stdout
    );

    // Verify .ct container exists and is large enough for a complex script
    let ct_path = find_ct_file(&output_dir);
    let ct_size = std::fs::metadata(&ct_path).unwrap().len();
    assert!(
        ct_size >= 1024,
        ".ct file should be at least 1KB for comprehensive.zsh, got {} bytes",
        ct_size
    );

    // Verify symbols.json contains the function names
    let symbols_json = output_dir.path().join("symbols.json");
    assert!(symbols_json.exists(), "symbols.json not found");
    let symbols: Vec<String> = serde_json::from_str(
        &std::fs::read_to_string(&symbols_json).expect("Failed to read symbols.json"),
    )
    .expect("Invalid symbols.json");
    assert!(
        symbols.iter().any(|s| s == "process"),
        "symbols.json should contain 'process', found: {:?}",
        symbols
    );
    assert!(
        symbols.iter().any(|s| s == "lib_func"),
        "symbols.json should contain 'lib_func', found: {:?}",
        symbols
    );

    // Verify the sourced lib file is tracked in the .ct container's paths stream
    let paths = read_trace_paths(&output_dir);
    let has_sourced_lib = paths.iter().any(|p| p.contains("zsh_sourced_lib.zsh"));
    assert!(
        has_sourced_lib,
        "paths should contain zsh_sourced_lib.zsh: {:?}",
        paths
    );
    let has_comprehensive = paths.iter().any(|p| p.contains("comprehensive.zsh"));
    assert!(
        has_comprehensive,
        "paths should contain comprehensive.zsh: {:?}",
        paths
    );

    // Verify source files are copied (both comprehensive.zsh and zsh_sourced_lib.zsh)
    let files_dir = output_dir.path().join("files");
    assert!(files_dir.exists(), "files/ directory not found");

    let comprehensive_fixture = fixture_path("comprehensive.zsh");
    let copied_comprehensive = files_dir.join(
        comprehensive_fixture
            .strip_prefix("/")
            .unwrap_or(&comprehensive_fixture),
    );
    assert!(
        copied_comprehensive.exists(),
        "comprehensive.zsh copy not found at: {}",
        copied_comprehensive.display()
    );

    let sourced_lib_fixture = fixture_path("zsh_sourced_lib.zsh");
    let copied_sourced_lib = files_dir.join(
        sourced_lib_fixture
            .strip_prefix("/")
            .unwrap_or(&sourced_lib_fixture),
    );
    assert!(
        copied_sourced_lib.exists(),
        "zsh_sourced_lib.zsh copy not found at: {}",
        copied_sourced_lib.display()
    );
}

#[test]
fn e2e_cross_shell_equivalence() {
    require_zsh!();

    // Record the same logic with both shells
    let (bash_output, bash_stdout, _bash_stderr) = record_bash_fixture("equivalent.sh");
    let (zsh_output, zsh_stdout, _zsh_stderr) = record_zsh_cross_fixture("equivalent.zsh");

    // Both should produce the same stdout output
    assert!(
        bash_stdout.contains("Hello, World!"),
        "Bash stdout should contain 'Hello, World!', got: {}",
        bash_stdout
    );
    assert!(
        zsh_stdout.contains("Hello, World!"),
        "Zsh stdout should contain 'Hello, World!', got: {}",
        zsh_stdout
    );
    assert!(
        bash_stdout.contains("result=30"),
        "Bash stdout should contain 'result=30', got: {}",
        bash_stdout
    );
    assert!(
        zsh_stdout.contains("result=30"),
        "Zsh stdout should contain 'result=30', got: {}",
        zsh_stdout
    );

    // Both should produce valid .ct containers
    let bash_ct = find_ct_file(&bash_output);
    let zsh_ct = find_ct_file(&zsh_output);
    let bash_ct_size = std::fs::metadata(&bash_ct).unwrap().len();
    let zsh_ct_size = std::fs::metadata(&zsh_ct).unwrap().len();
    assert!(
        bash_ct_size >= 1024,
        "Bash .ct should be at least 1KB, got {}",
        bash_ct_size
    );
    assert!(
        zsh_ct_size >= 1024,
        "Zsh .ct should be at least 1KB, got {}",
        zsh_ct_size
    );

    // Both should have symbols.json with "greet"
    let bash_symbols_path = bash_output.path().join("symbols.json");
    assert!(bash_symbols_path.exists(), "Bash symbols.json not found");
    let bash_symbols: Vec<String> = serde_json::from_str(
        &std::fs::read_to_string(&bash_symbols_path).expect("Failed to read bash symbols.json"),
    )
    .expect("Invalid bash symbols.json");
    assert!(
        bash_symbols.iter().any(|s| s == "greet"),
        "Bash symbols.json should contain 'greet', found: {:?}",
        bash_symbols
    );

    let zsh_symbols_path = zsh_output.path().join("symbols.json");
    assert!(zsh_symbols_path.exists(), "Zsh symbols.json not found");
    let zsh_symbols: Vec<String> = serde_json::from_str(
        &std::fs::read_to_string(&zsh_symbols_path).expect("Failed to read zsh symbols.json"),
    )
    .expect("Invalid zsh symbols.json");
    assert!(
        zsh_symbols.iter().any(|s| s == "greet"),
        "Zsh symbols.json should contain 'greet', found: {:?}",
        zsh_symbols
    );

    // Verify both traces have the correct language in their metadata
    let bash_db_meta_path = bash_output.path().join("trace_db_metadata.json");
    assert!(
        bash_db_meta_path.exists(),
        "Bash trace_db_metadata.json not found"
    );
    let bash_db_meta: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(&bash_db_meta_path)
            .expect("Failed to read bash trace_db_metadata.json"),
    )
    .expect("Invalid bash trace_db_metadata.json");
    assert_eq!(
        bash_db_meta["language"].as_str(),
        Some("bash"),
        "Bash trace should have language='bash', got: {:?}",
        bash_db_meta["language"]
    );

    let zsh_db_meta_path = zsh_output.path().join("trace_db_metadata.json");
    assert!(
        zsh_db_meta_path.exists(),
        "Zsh trace_db_metadata.json not found"
    );
    let zsh_db_meta: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(&zsh_db_meta_path)
            .expect("Failed to read zsh trace_db_metadata.json"),
    )
    .expect("Invalid zsh trace_db_metadata.json");
    assert_eq!(
        zsh_db_meta["language"].as_str(),
        Some("zsh"),
        "Zsh trace should have language='zsh', got: {:?}",
        zsh_db_meta["language"]
    );
}

// Issue `2026-11-15-zsh-recorder-does-not-record-exported-variables`, spec
// `CLI/recorders/shell.md` "Rules": both shells produce interchangeable
// traces. The same script records the same variables in both, an exported
// one included, and neither reports an inherited environment variable.
#[test]
fn e2e_cross_shell_exported_variables() {
    require_zsh!();
    let bash_vars = record_last_step_vars(&common::BASH, &cross_shell_fixture_path("exported.sh"));
    let zsh_vars = record_last_step_vars(&common::ZSH, &cross_shell_fixture_path("exported.zsh"));

    assert_eq!(
        common::var_names(&zsh_vars),
        common::var_names(&bash_vars),
        "zsh and bash must record the same variables at the last step"
    );
    common::assert_string(
        common::var(&bash_vars, "DEPLOY_ENV"),
        "staging",
        "bash DEPLOY_ENV at the last step",
    );
    common::assert_string(
        common::var(&zsh_vars, "DEPLOY_ENV"),
        "staging",
        "zsh DEPLOY_ENV at the last step",
    );
    assert_no_inherited_vars(&bash_vars, "bash exported.sh");
    assert_no_inherited_vars(&zsh_vars, "zsh exported.zsh");
}

// ============================================================================
// Function return recording
// ============================================================================
//
// Codetracer-pm issue
// `2026-11-15-shell-recorders-never-close-a-function-called-in-command-substitution`.
// The claims are shared with the other shell; see "Function return
// recording" in `common/mod.rs`.

#[test]
fn test_zsh_every_call_in_event_stream_has_a_return() {
    require_zsh!();
    // `cmdsubst_loop` calls a function in `$(...)`; the raw stream must close it.
    common::assert_stream_balanced(&common::ZSH, "cmdsubst_loop");
}

#[test]
fn test_zsh_function_in_command_substitution_is_closed() {
    require_zsh!();
    common::check_function_in_command_substitution_is_closed(&common::ZSH);
}

#[test]
fn test_zsh_function_used_as_condition_records_its_status() {
    require_zsh!();
    common::check_function_used_as_condition_records_its_status(&common::ZSH);
}

#[test]
fn test_zsh_directly_called_function_return_is_recorded() {
    require_zsh!();
    common::check_directly_called_function_return_is_recorded(&common::ZSH);
}

#[test]
fn test_zsh_explicit_return_values_are_recorded() {
    require_zsh!();
    common::check_explicit_return_values(&common::ZSH);
}

#[test]
fn test_zsh_outer_function_returns_inner_status() {
    require_zsh!();
    common::check_nested_returns(&common::ZSH);
}

#[test]
fn test_zsh_recursion_in_command_substitution_is_closed() {
    require_zsh!();
    common::check_recursion_in_command_substitution(&common::ZSH);
}

#[test]
fn test_zsh_exit_in_command_substitution_closes_subshell_frames() {
    require_zsh!();
    common::check_exit_in_command_substitution(&common::ZSH);
}

#[test]
fn test_zsh_main_shell_exit_in_function_writes_no_return() {
    require_zsh!();
    common::check_main_shell_exit_in_function_writes_no_return(&common::ZSH);
}

#[test]
fn test_zsh_sourced_file_frames_are_closed_once() {
    require_zsh!();
    common::check_sourced_file_returns(&common::ZSH, 8);
}

#[test]
fn test_zsh_and_list_calls_are_closed() {
    require_zsh!();
    common::check_and_list_calls(&common::ZSH);
}

// ============================================================================
// Traps set by the recorded script
// ============================================================================
//
// Codetracer-pm issue
// `2026-11-15-shell-recorders-lose-events-when-the-script-sets-its-own-err-or-debug-trap`.
// The claims shared with the other shell are in "Traps set by the recorded
// script" in `common/mod.rs`.

#[test]
fn test_zsh_script_zerr_trap_keeps_error_capture() {
    require_zsh!();
    common::check_script_err_trap_keeps_capturing(&common::ZSH);
}

#[test]
fn test_zsh_script_debug_trap_keeps_step_capture() {
    require_zsh!();
    common::check_script_debug_trap_keeps_capturing(&common::ZSH);
}

#[test]
fn test_zsh_script_debug_action_still_runs() {
    require_zsh!();
    common::check_script_debug_action_runs(&common::ZSH);
}

#[test]
fn test_zsh_script_trap_reset_and_ignore_keep_capture() {
    require_zsh!();
    common::check_script_trap_reset_and_ignore(&common::ZSH);
}

#[test]
fn test_zsh_script_trap_listing_shows_script_actions() {
    require_zsh!();
    common::check_script_trap_listing(&common::ZSH);
}

#[test]
fn test_zsh_replaced_recorder_trap_is_reported() {
    require_zsh!();
    common::check_replaced_trap_is_reported(&common::ZSH);
}

/// Function-form traps (`TRAPZERR() { ... }`, `TRAPDEBUG() { ... }`) keep
/// working, and `unfunction TRAPZERR` removes the script's trap only: all
/// three failures (lines 8, 16 and 19) and the steps after `TRAPDEBUG` is
/// defined are still recorded, and the script's handler runs for the first
/// two only.
#[test]
fn test_zsh_script_function_form_traps_are_chained() {
    require_zsh!();
    let shell = &common::ZSH;
    let run = common::assert_stream_balanced(shell, "trap_fn_forms");
    assert_eq!(
        common::error_step_lines(&run),
        vec![8, 16, 19],
        "stream:\n{}",
        run.events.join("\n")
    );
    let out = common::record_like_native(shell, "trap_fn_forms");
    assert_eq!(common::recorded_error_texts(out.path()).len(), 3);
    let lines: Vec<u64> = common::step_lines_and_depths(out.path())
        .into_iter()
        .map(|(line, _)| line)
        .collect();
    for line in [12, 13, 14, 15, 16, 17, 18, 19, 20] {
        assert!(lines.contains(&line), "no step at line {line}: {lines:?}");
    }
}

/// An `EXIT` trap set inside a function runs when that function returns,
/// with `$?` its status, and does not replace the recorder's own per-function
/// `EXIT` trap: every frame is closed with the function's status.
#[test]
fn test_zsh_script_function_exit_trap_is_chained() {
    require_zsh!();
    let shell = &common::ZSH;
    common::assert_stream_balanced(shell, "trap_fn_exit");
    let out = common::record_like_native(shell, "trap_fn_exit");
    let calls = common::recorded_calls(out.path());
    common::assert_calls(&calls, "f", 2, &[2]);
    common::assert_calls(&calls, "g", 2, &[3]);
}

/// `setopt localtraps` in a function: the `ZERR` trap it sets there is the
/// script's until the function returns, then the outer one is back, and
/// both failures (lines 8 and 11) are recorded.
///
/// The `ERROR` lines are matched to the step before them rather than
/// counted: zsh runs the ZERR trap once more in the caller of a function
/// that returns non-zero when the function has an `EXIT` trap, and the
/// recorder gives every function one, so the raw stream also has an
/// `ERROR` for the call of `f` (which the script's own handler does not
/// see; the standard-output comparison checks that).
#[test]
fn test_zsh_script_local_traps_are_restored() {
    require_zsh!();
    let shell = &common::ZSH;
    let run = common::assert_stream_balanced(shell, "trap_local");
    let mut lines = common::error_step_lines(&run);
    lines.dedup();
    assert_eq!(lines, vec![8, 11], "stream:\n{}", run.events.join("\n"));
    common::record_like_native(shell, "trap_local");
}

#[test]
fn test_zsh_script_exit_trap_is_chained() {
    require_zsh!();
    common::check_script_exit_trap(&common::ZSH);
}

/// `setopt localtraps` in a function when the script has no `DEBUG` or
/// `ZERR` trap outside it: the function's traps are restored away when it
/// returns (the script's handlers do not run for the commands after it),
/// and both failures (lines 10 and 14) are recorded.
#[test]
fn test_zsh_script_local_traps_without_outer_trap_are_restored() {
    require_zsh!();
    let shell = &common::ZSH;
    let run = common::assert_stream_balanced(shell, "trap_local_first");
    let mut lines = common::error_step_lines(&run);
    lines.dedup();
    assert_eq!(lines, vec![10, 14], "stream:\n{}", run.events.join("\n"));
    let native = common::native_stdout(shell, "trap_local_first");
    assert!(
        native.ends_with("h zerr\nend\n"),
        "natively, no handler runs after `h` returns: {native:?}"
    );
    common::record_like_native(shell, "trap_local_first");
}

/// A script that takes descriptor 3 for itself (`exec 3>&1`) neither sees
/// the event stream on its output nor cuts the recording short.
#[test]
fn test_zsh_script_redirecting_fd3_keeps_the_trace_channel() {
    require_zsh!();
    common::check_script_fd3_does_not_touch_the_trace_channel(&common::ZSH, "fd3_redirected");
}

/// A script that closes descriptor 3 (`exec 3>&-`) keeps being recorded.
#[test]
fn test_zsh_script_closing_fd3_keeps_the_trace_channel() {
    require_zsh!();
    common::check_script_fd3_does_not_touch_the_trace_channel(&common::ZSH, "fd3_closed");
}

// ============================================================================
// Paths and function names that need quoting on the wire
// ============================================================================
//
// Codetracer-pm issue
// `2026-11-15-shell-recorders-cannot-record-a-script-whose-path-contains-a-space`.
// The claims are shared with the other shell; see "Paths and function names
// that need quoting on the wire" in `common/mod.rs`.

/// Control: the same recording from a directory with no special character.
#[test]
fn test_zsh_records_script_in_plain_directory() {
    require_zsh!();
    common::check_records_script_in_dir(&common::ZSH, "plain_dir");
}

/// A path with a space must reach the writer quoted, so that the trace is
/// written and carries the exact path.
#[test]
fn test_zsh_records_script_path_containing_a_space() {
    require_zsh!();
    common::check_records_script_in_dir(&common::ZSH, "my scripts");
}

/// A tab ends an unquoted value too.
#[test]
fn test_zsh_records_script_path_containing_a_tab() {
    require_zsh!();
    common::check_records_script_in_dir(&common::ZSH, "tab\tdir");
}

/// `"` and `\` are the characters the quoted form escapes.
#[test]
fn test_zsh_records_script_path_containing_a_quote_and_a_backslash() {
    require_zsh!();
    common::check_records_script_in_dir(&common::ZSH, "we\"ird\\dir");
}

#[test]
fn test_zsh_records_sourced_file_whose_path_contains_a_space() {
    require_zsh!();
    common::check_records_sourced_file_with_space(&common::ZSH);
}

/// A file sourced by `./name` after a `cd` is recorded by its absolute path
/// and copied (codetracer-pm issue
/// `2026-11-15-shell-recorders-record-a-relatively-sourced-file-by-its-relative-path-and-may-not-copy-it`).
#[test]
fn test_zsh_records_file_sourced_by_a_relative_path_after_cd() {
    require_zsh!();
    common::check_records_relatively_sourced_file(&common::ZSH, common::RelativeSource::DotSlash);
}

/// The `.` and `..` components of a relative source path are folded.
#[test]
fn test_zsh_records_file_sourced_by_a_relative_path_with_dot_components() {
    require_zsh!();
    common::check_records_relatively_sourced_file(&common::ZSH, common::RelativeSource::DotDot);
}

/// A file found through a relative `PATH` entry is recorded by its absolute
/// path.
#[test]
fn test_zsh_records_file_sourced_through_a_relative_path_entry() {
    require_zsh!();
    common::check_records_relatively_sourced_file(&common::ZSH, common::RelativeSource::PathSearch);
}

/// A `..` after a symlinked directory names the file the shell opened, not
/// the one folding it lexically would name.
#[test]
fn test_zsh_records_file_sourced_by_a_relative_path_through_a_symlinked_dir() {
    require_zsh!();
    common::check_records_relatively_sourced_file(
        &common::ZSH,
        common::RelativeSource::DotDotThroughSymlink,
    );
}

#[test]
fn test_zsh_records_function_in_script_whose_path_contains_a_space() {
    require_zsh!();
    common::check_records_function_in_dir_with_space(&common::ZSH, "greet", "greet() {", "greet");
}

/// Zsh, unlike Bash, accepts any function name: one with a space, a `"`
/// and a `\` must reach the writer whole in `FUNC` and `CALL`.
#[test]
fn test_zsh_records_function_whose_name_needs_quoting() {
    require_zsh!();
    common::check_records_function_in_dir_with_space(
        &common::ZSH,
        r#"my "odd\ func"#,
        r#"function 'my "odd\ func' {"#,
        r#"'my "odd\ func'"#,
    );
}
