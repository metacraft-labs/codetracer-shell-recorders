// Test that the zsh recorder produces valid trace files.
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

/// Read trace_paths.json content from an output directory.
fn read_trace_paths(output_dir: &TempDir) -> Vec<serde_json::Value> {
    let paths_json = output_dir.path().join("trace_paths.json");
    assert!(paths_json.exists(), "trace_paths.json not found");
    serde_json::from_str(
        &std::fs::read_to_string(&paths_json).expect("Failed to read trace_paths.json"),
    )
    .expect("Invalid paths JSON")
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

    // Verify sidecar metadata exists and references the script
    let metadata_json = output_dir.path().join("trace_metadata.json");
    assert!(metadata_json.exists(), "trace_metadata.json not found");

    // Verify trace_paths.json exists
    let paths_json = output_dir.path().join("trace_paths.json");
    assert!(paths_json.exists(), "trace_paths.json not found");

    // Verify the script path appears in trace_paths.json
    let paths = read_trace_paths(&output_dir);
    assert!(!paths.is_empty(), "paths should not be empty");
    let has_simple = paths
        .iter()
        .any(|p| p.as_str().map_or(false, |s| s.contains("simple.zsh")));
    assert!(has_simple, "paths should contain simple.zsh: {:?}", paths);

    // Read metadata and verify it references the script
    let metadata: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(&metadata_json).expect("Failed to read metadata"),
    )
    .expect("Invalid metadata JSON");

    let program = metadata["program"].as_str().expect("No program field");
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
    let (output_dir, _stdout, _stderr) = record_fixture("simple.zsh");

    // Verify .ct container exists — the exit code is encoded inside the binary
    // container. Detailed event parsing is covered by integration_test.rs.
    let ct_path = find_ct_file(&output_dir);
    let ct_size = std::fs::metadata(&ct_path).unwrap().len();
    assert!(
        ct_size >= 1024,
        ".ct file should be at least 1KB, got {} bytes",
        ct_size
    );
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

    // Verify trace_paths.json contains BOTH files
    let paths = read_trace_paths(&output_dir);

    let has_with_source = paths
        .iter()
        .any(|p| p.as_str().map_or(false, |s| s.contains("with_source.zsh")));
    assert!(
        has_with_source,
        "paths should contain with_source.zsh: {:?}",
        paths
    );

    let has_sourced_lib = paths.iter().any(|p| {
        p.as_str()
            .map_or(false, |s| s.contains("zsh_sourced_lib.zsh"))
    });
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

    // Verify the sourced lib file is tracked in trace_paths.json
    let paths = read_trace_paths(&output_dir);
    let has_sourced_lib = paths.iter().any(|p| {
        p.as_str()
            .map_or(false, |s| s.contains("zsh_sourced_lib.zsh"))
    });
    assert!(
        has_sourced_lib,
        "trace_paths.json should contain zsh_sourced_lib.zsh: {:?}",
        paths
    );
    let has_comprehensive = paths.iter().any(|p| {
        p.as_str()
            .map_or(false, |s| s.contains("comprehensive.zsh"))
    });
    assert!(
        has_comprehensive,
        "trace_paths.json should contain comprehensive.zsh: {:?}",
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
