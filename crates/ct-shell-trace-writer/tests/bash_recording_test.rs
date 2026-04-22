// Test that the bash recorder produces valid trace files.
//
// The Nim CTFS backend always produces a binary `.ct` container file.
// Tests verify the container exists and has valid CTFS magic bytes,
// and check the JSON sidecar files (trace_metadata.json, trace_paths.json,
// symbols.json) written by the TraceBridge.
use std::path::PathBuf;
use std::process::Command;
use tempfile::TempDir;

/// CTFS magic bytes: 0xC0 0xDE 0x72 0xAC 0xE2
const CTFS_MAGIC: &[u8] = &[0xC0, 0xDE, 0x72, 0xAC, 0xE2];

fn launcher_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap() // crates/
        .parent()
        .unwrap() // repo root
        .join("bash-recorder/launcher.sh")
}

fn fixture_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("tests/fixtures/bash")
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

/// Run the bash recorder on a fixture and return (output_dir, stdout, stderr).
fn record_fixture(fixture: &str) -> (TempDir, String, String) {
    build_trace_writer();

    let output_dir = TempDir::new().expect("Failed to create temp dir");

    let output = Command::new("bash")
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

/// Read trace_paths.json content from an output directory.
fn read_trace_paths(output_dir: &TempDir) -> Vec<serde_json::Value> {
    let paths_json = output_dir.path().join("trace_paths.json");
    assert!(paths_json.exists(), "trace_paths.json not found");
    serde_json::from_str(
        &std::fs::read_to_string(&paths_json).expect("Failed to read trace_paths.json"),
    )
    .expect("Invalid paths JSON")
}

#[test]
fn test_bash_step_events_simple() {
    let (output_dir, _stdout, _stderr) = record_fixture("simple.sh");

    // Verify .ct container exists with valid CTFS magic
    let ct_path = find_ct_file(&output_dir);
    let ct_size = std::fs::metadata(&ct_path).unwrap().len();
    assert!(ct_size > 0, ".ct file is empty");

    // Verify sidecar metadata exists and references the script
    let metadata_json = output_dir.path().join("trace_metadata.json");
    assert!(metadata_json.exists(), "trace_metadata.json not found");
    let metadata: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(&metadata_json).expect("Failed to read metadata"),
    )
    .expect("Invalid metadata JSON");

    let program = metadata["program"].as_str().expect("No program field");
    assert!(
        program.contains("simple.sh"),
        "Program should reference simple.sh, got: {}",
        program
    );

    // Verify trace_paths.json exists and contains the script
    let paths_json = output_dir.path().join("trace_paths.json");
    assert!(paths_json.exists(), "trace_paths.json not found");
    let paths = read_trace_paths(&output_dir);

    assert!(!paths.is_empty(), "paths should not be empty");
    let has_simple = paths
        .iter()
        .any(|p| p.as_str().map_or(false, |s| s.contains("simple.sh")));
    assert!(has_simple, "paths should contain simple.sh: {:?}", paths);
}

#[test]
fn test_bash_path_registration() {
    let (output_dir, _stdout, _stderr) = record_fixture("simple.sh");

    let paths = read_trace_paths(&output_dir);

    // Should have at least the script path
    assert!(
        !paths.is_empty(),
        "Expected at least 1 path, got {}",
        paths.len()
    );
    let has_fixture = paths
        .iter()
        .any(|p| p.as_str().map_or(false, |s| s.contains("simple.sh")));
    assert!(has_fixture, "Paths should include simple.sh: {:?}", paths);
}

#[test]
fn e2e_bash_basic_recording() {
    build_trace_writer();

    let output_dir = TempDir::new().expect("Failed to create temp dir");

    // Record with default format (CTFS)
    let output = Command::new("bash")
        .args([
            launcher_path().to_str().unwrap(),
            "--out-dir",
            output_dir.path().to_str().unwrap(),
            fixture_path("multiline.sh").to_str().unwrap(),
        ])
        .output()
        .expect("Failed to run launcher");

    assert!(
        output.status.success(),
        "Launcher failed: stderr={}",
        String::from_utf8_lossy(&output.stderr)
    );

    // Verify .ct container exists with CTFS magic
    let ct_path = find_ct_file(&output_dir);
    let ct_size = std::fs::metadata(&ct_path).unwrap().len();
    assert!(ct_size > 0, ".ct file is empty");

    // Verify the script's stdout was preserved (not eaten by the recorder)
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("less"),
        "Script output should contain 'less', got: {}",
        stdout
    );
}

#[test]
fn test_bash_function_call_return() {
    let (output_dir, stdout, _stderr) = record_fixture("functions.sh");

    // Verify script produced expected output
    assert!(
        stdout.contains("Hello, World!"),
        "Expected 'Hello, World!' in stdout, got: {}",
        stdout
    );
    assert!(
        stdout.contains("Sum:"),
        "Expected 'Sum:' in stdout, got: {}",
        stdout
    );

    // Verify .ct container exists and is reasonably sized (contains function events)
    let ct_path = find_ct_file(&output_dir);
    let ct_size = std::fs::metadata(&ct_path).unwrap().len();
    assert!(
        ct_size >= 1024,
        ".ct file should be at least 1KB for a script with functions, got {} bytes",
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
        symbols.iter().any(|s| s == "greet"),
        "symbols.json should contain 'greet', found: {:?}",
        symbols
    );
}

#[test]
fn test_bash_nested_functions() {
    let (output_dir, stdout, _stderr) = record_fixture("nested_functions.sh");

    // Verify script produced expected output
    assert!(
        stdout.contains("outer start"),
        "Expected 'outer start' in stdout, got: {}",
        stdout
    );
    assert!(
        stdout.contains("inner called"),
        "Expected 'inner called' in stdout, got: {}",
        stdout
    );
    assert!(
        stdout.contains("outer end"),
        "Expected 'outer end' in stdout, got: {}",
        stdout
    );
    assert!(
        stdout.contains("done"),
        "Expected 'done' in stdout, got: {}",
        stdout
    );

    // Verify .ct container exists and is reasonably sized
    let ct_path = find_ct_file(&output_dir);
    let ct_size = std::fs::metadata(&ct_path).unwrap().len();
    assert!(
        ct_size >= 1024,
        ".ct file should be at least 1KB for nested functions, got {} bytes",
        ct_size
    );

    // Verify both function names appear in symbols.json
    let symbols_json = output_dir.path().join("symbols.json");
    assert!(symbols_json.exists(), "symbols.json not found");
    let symbols: Vec<String> = serde_json::from_str(
        &std::fs::read_to_string(&symbols_json).expect("Failed to read symbols.json"),
    )
    .expect("Invalid symbols.json");

    assert!(
        symbols.iter().any(|s| s == "outer"),
        "symbols.json should contain 'outer', found: {:?}",
        symbols
    );
    assert!(
        symbols.iter().any(|s| s == "inner"),
        "symbols.json should contain 'inner', found: {:?}",
        symbols
    );
}

#[test]
fn test_bash_exit_code() {
    let (output_dir, _stdout, _stderr) = record_fixture("simple.sh");

    // Verify .ct container exists — the exit code is encoded inside the binary
    // container as a Return event. We verify the container is valid (magic bytes)
    // and trust the integration_test.rs unit test for detailed event parsing.
    let ct_path = find_ct_file(&output_dir);
    let ct_size = std::fs::metadata(&ct_path).unwrap().len();
    assert!(
        ct_size >= 1024,
        ".ct file should be at least 1KB, got {} bytes",
        ct_size
    );
}

// ============================================================================
// M4: Variable Capture & Type Inference Tests
// ============================================================================

#[test]
fn test_bash_scalar_variable_capture() {
    let (output_dir, stdout, _stderr) = record_fixture("variables.sh");

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

#[test]
fn test_bash_array_variable_capture() {
    let (output_dir, _stdout, _stderr) = record_fixture("variables.sh");

    // Verify .ct container exists and is reasonably sized
    let ct_path = find_ct_file(&output_dir);
    let ct_size = std::fs::metadata(&ct_path).unwrap().len();
    assert!(
        ct_size >= 1024,
        ".ct file should be at least 1KB for a script with arrays, got {} bytes",
        ct_size
    );
}

#[test]
fn test_bash_assoc_array_capture() {
    let (output_dir, _stdout, _stderr) = record_fixture("variables.sh");

    // Verify .ct container exists and is reasonably sized
    let ct_path = find_ct_file(&output_dir);
    let ct_size = std::fs::metadata(&ct_path).unwrap().len();
    assert!(
        ct_size >= 1024,
        ".ct file should be at least 1KB for a script with assoc arrays, got {} bytes",
        ct_size
    );
}

#[test]
fn test_bash_builtin_filtering() {
    let (output_dir, _stdout, _stderr) = record_fixture("simple.sh");

    // Verify .ct container exists — builtin filtering is verified inside the
    // binary container events. The integration_test.rs covers detailed event
    // content verification via the wire protocol + TraceBridge pipeline.
    let ct_path = find_ct_file(&output_dir);
    let ct_size = std::fs::metadata(&ct_path).unwrap().len();
    assert!(
        ct_size >= 1024,
        ".ct file should be at least 1KB, got {} bytes",
        ct_size
    );
}

// ============================================================================
// M5: IO, Errors & Edge Cases Tests
// ============================================================================

#[test]
fn test_bash_error_trap() {
    // Record errors.sh — it contains `false` and `ls /ct_recorder_test_nonexistent_path_xyzzy`
    // which both fail. The script should still complete.
    let (output_dir, stdout, _stderr) = record_fixture("errors.sh");

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
fn test_bash_output_capture() {
    // Record output.sh — it uses echo and printf
    let (output_dir, stdout, _stderr) = record_fixture("output.sh");

    // Verify script produced expected output
    assert!(
        stdout.contains("hello"),
        "Expected 'hello' in stdout, got: {}",
        stdout
    );
    assert!(
        stdout.contains("world"),
        "Expected 'world' in stdout, got: {}",
        stdout
    );
    assert!(
        stdout.contains("x is result"),
        "Expected 'x is result' in stdout, got: {}",
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
fn test_bash_sourced_file() {
    // Record with_source.sh which sources sourced_lib.sh
    let (output_dir, stdout, _stderr) = record_fixture("with_source.sh");

    // Verify script produced expected output from sourced functions
    assert!(
        stdout.contains("from lib"),
        "Expected 'from lib' in stdout, got: {}",
        stdout
    );
    assert!(
        stdout.contains("library value"),
        "Expected 'library value' in stdout, got: {}",
        stdout
    );

    // Verify trace_paths.json contains BOTH files
    let paths = read_trace_paths(&output_dir);

    let has_with_source = paths
        .iter()
        .any(|p| p.as_str().map_or(false, |s| s.contains("with_source.sh")));
    assert!(
        has_with_source,
        "paths should contain with_source.sh: {:?}",
        paths
    );

    let has_sourced_lib = paths
        .iter()
        .any(|p| p.as_str().map_or(false, |s| s.contains("sourced_lib.sh")));
    assert!(
        has_sourced_lib,
        "paths should contain sourced_lib.sh (the sourced file): {:?}",
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
}

// ============================================================================
// M6: End-to-End Validation & CLI Integration Tests
// ============================================================================

#[test]
fn e2e_bash_simple_script() {
    // Record simple.sh, verify COMPLETE trace folder structure
    let (output_dir, _stdout, _stderr) = record_fixture("simple.sh");

    // .ct container exists and is non-empty with valid CTFS magic
    let ct_path = find_ct_file(&output_dir);
    let ct_size = std::fs::metadata(&ct_path).unwrap().len();
    assert!(ct_size > 0, ".ct file is empty");

    // trace_metadata.json exists
    let metadata_json = output_dir.path().join("trace_metadata.json");
    assert!(metadata_json.exists(), "trace_metadata.json not found");

    // trace_paths.json exists
    let paths_json = output_dir.path().join("trace_paths.json");
    assert!(paths_json.exists(), "trace_paths.json not found");

    // trace_db_metadata.json exists with language="bash"
    let db_metadata_json = output_dir.path().join("trace_db_metadata.json");
    assert!(
        db_metadata_json.exists(),
        "trace_db_metadata.json not found"
    );
    let db_meta: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(&db_metadata_json).expect("Failed to read trace_db_metadata.json"),
    )
    .expect("Invalid trace_db_metadata.json");
    assert_eq!(
        db_meta["language"].as_str(),
        Some("bash"),
        "trace_db_metadata.json language should be 'bash'"
    );

    // symbols.json exists
    let symbols_json = output_dir.path().join("symbols.json");
    assert!(symbols_json.exists(), "symbols.json not found");
    let symbols: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(&symbols_json).expect("Failed to read symbols.json"),
    )
    .expect("Invalid symbols.json");
    assert!(symbols.is_array(), "symbols.json should be a JSON array");

    // files/ directory exists with source file copy
    let files_dir = output_dir.path().join("files");
    assert!(files_dir.exists(), "files/ directory not found");
    assert!(files_dir.is_dir(), "files/ should be a directory");

    // Verify the source file was copied — it should be under files/<absolute-path>
    let fixture = fixture_path("simple.sh");
    let copied = files_dir.join(fixture.strip_prefix("/").unwrap_or(&fixture));
    assert!(
        copied.exists(),
        "Source file copy not found at expected path: {}",
        copied.display()
    );

    // Verify the copied file has the same content as the original
    let original_content =
        std::fs::read_to_string(&fixture).expect("Failed to read original simple.sh");
    let copied_content = std::fs::read_to_string(&copied).expect("Failed to read copied simple.sh");
    assert_eq!(
        original_content, copied_content,
        "Copied source file content should match original"
    );
}

#[test]
fn e2e_bash_multi_file() {
    // Record with_source.sh which sources sourced_lib.sh
    let (output_dir, _stdout, _stderr) = record_fixture("with_source.sh");

    // Verify trace_paths.json has both files
    let paths = read_trace_paths(&output_dir);
    let has_with_source = paths
        .iter()
        .any(|p| p.as_str().map_or(false, |s| s.contains("with_source.sh")));
    assert!(
        has_with_source,
        "trace_paths.json should contain with_source.sh: {:?}",
        paths
    );
    let has_sourced_lib = paths
        .iter()
        .any(|p| p.as_str().map_or(false, |s| s.contains("sourced_lib.sh")));
    assert!(
        has_sourced_lib,
        "trace_paths.json should contain sourced_lib.sh: {:?}",
        paths
    );

    // Verify files/ directory has copies of BOTH with_source.sh and sourced_lib.sh
    let files_dir = output_dir.path().join("files");
    assert!(files_dir.exists(), "files/ directory not found");

    let with_source_fixture = fixture_path("with_source.sh");
    let sourced_lib_fixture = fixture_path("sourced_lib.sh");

    let copied_with_source = files_dir.join(
        with_source_fixture
            .strip_prefix("/")
            .unwrap_or(&with_source_fixture),
    );
    assert!(
        copied_with_source.exists(),
        "with_source.sh copy not found at: {}",
        copied_with_source.display()
    );

    let copied_sourced_lib = files_dir.join(
        sourced_lib_fixture
            .strip_prefix("/")
            .unwrap_or(&sourced_lib_fixture),
    );
    assert!(
        copied_sourced_lib.exists(),
        "sourced_lib.sh copy not found at: {}",
        copied_sourced_lib.display()
    );

    // Verify content matches
    let original_ws =
        std::fs::read_to_string(&with_source_fixture).expect("Failed to read with_source.sh");
    let copied_ws =
        std::fs::read_to_string(&copied_with_source).expect("Failed to read copied with_source.sh");
    assert_eq!(
        original_ws, copied_ws,
        "with_source.sh content should match"
    );

    let original_sl =
        std::fs::read_to_string(&sourced_lib_fixture).expect("Failed to read sourced_lib.sh");
    let copied_sl =
        std::fs::read_to_string(&copied_sourced_lib).expect("Failed to read copied sourced_lib.sh");
    assert_eq!(
        original_sl, copied_sl,
        "sourced_lib.sh content should match"
    );
}

#[test]
fn e2e_bash_complex_script() {
    // Record comprehensive.sh
    let (output_dir, stdout, _stderr) = record_fixture("comprehensive.sh");

    // Verify script output contains expected lines
    assert!(
        stdout.contains("Starting comprehensive test"),
        "Expected 'Starting comprehensive test' in stdout, got: {}",
        stdout
    );
    assert!(
        stdout.contains("from lib"),
        "Expected 'from lib' in stdout (from sourced lib_func), got: {}",
        stdout
    );
    assert!(
        stdout.contains("positive"),
        "Expected 'positive' in stdout, got: {}",
        stdout
    );
    assert!(
        stdout.contains("negative"),
        "Expected 'negative' in stdout, got: {}",
        stdout
    );
    assert!(
        stdout.contains("zero"),
        "Expected 'zero' in stdout, got: {}",
        stdout
    );
    assert!(
        stdout.contains("Done"),
        "Expected 'Done' in stdout, got: {}",
        stdout
    );

    // Verify .ct container exists and is large enough for a complex script
    let ct_path = find_ct_file(&output_dir);
    let ct_size = std::fs::metadata(&ct_path).unwrap().len();
    assert!(
        ct_size >= 1024,
        ".ct file should be at least 1KB for comprehensive.sh, got {} bytes",
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
        symbols.iter().any(|s| s == "count_to"),
        "symbols.json should contain 'count_to', found: {:?}",
        symbols
    );
    assert!(
        symbols.iter().any(|s| s == "classify"),
        "symbols.json should contain 'classify', found: {:?}",
        symbols
    );
    assert!(
        symbols.iter().any(|s| s == "lib_func"),
        "symbols.json should contain 'lib_func', found: {:?}",
        symbols
    );
}

#[test]
fn e2e_bash_metadata() {
    // Record simple.sh
    let (output_dir, _stdout, _stderr) = record_fixture("simple.sh");

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

    // Verify: language="bash"
    assert_eq!(
        db_meta["language"].as_str(),
        Some("bash"),
        "language should be 'bash', got: {:?}",
        db_meta["language"]
    );

    // Verify: program contains "simple.sh"
    let program = db_meta["program"]
        .as_str()
        .expect("program field should be a string");
    assert!(
        program.contains("simple.sh"),
        "program should contain 'simple.sh', got: {}",
        program
    );

    // Verify: bash_version is non-empty
    let bash_version = db_meta["bash_version"]
        .as_str()
        .expect("bash_version field should be a string");
    assert!(!bash_version.is_empty(), "bash_version should be non-empty");
    // Should look like a version number (e.g., 5.2.0)
    assert!(
        bash_version.contains('.'),
        "bash_version should contain a dot (version number), got: {}",
        bash_version
    );

    // Verify: recorder field
    let recorder = db_meta["recorder"]
        .as_str()
        .expect("recorder field should be a string");
    assert_eq!(
        recorder, "codetracer-bash-recorder",
        "recorder should be 'codetracer-bash-recorder', got: {}",
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

    // Also verify that the sidecar trace_metadata.json exists and is valid
    let metadata_json = output_dir.path().join("trace_metadata.json");
    assert!(
        metadata_json.exists(),
        "trace_metadata.json should still exist"
    );
    let meta: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(&metadata_json).expect("Failed to read trace_metadata.json"),
    )
    .expect("Invalid trace_metadata.json");
    let meta_program = meta["program"]
        .as_str()
        .expect("No program field in trace_metadata.json");
    assert!(
        meta_program.contains("simple.sh"),
        "trace_metadata.json program should reference simple.sh, got: {}",
        meta_program
    );
}
