// Test that the bash recorder produces valid trace files
use std::path::PathBuf;
use std::process::Command;
use tempfile::TempDir;

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
            "--output-dir",
            output_dir.path().to_str().unwrap(),
            "--format",
            "json",
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

/// Read trace.json content from an output directory.
fn read_trace_json(output_dir: &TempDir) -> String {
    let trace_json = output_dir.path().join("trace.json");
    assert!(trace_json.exists(), "trace.json not found");
    std::fs::read_to_string(&trace_json).expect("Failed to read trace.json")
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

    // Verify trace files exist
    let trace_json = output_dir.path().join("trace.json");
    let metadata_json = output_dir.path().join("trace_metadata.json");
    let paths_json = output_dir.path().join("trace_paths.json");

    assert!(trace_json.exists(), "trace.json not found");
    assert!(metadata_json.exists(), "trace_metadata.json not found");
    assert!(paths_json.exists(), "trace_paths.json not found");

    // Read and verify trace.json contains step events
    let trace_content = std::fs::read_to_string(&trace_json).expect("Failed to read trace.json");
    assert!(!trace_content.is_empty(), "trace.json is empty");

    // Read metadata and verify it references the script
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

    // Read paths and verify the script appears
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

    // Record with binary format
    let output = Command::new("bash")
        .args([
            launcher_path().to_str().unwrap(),
            "--output-dir",
            output_dir.path().to_str().unwrap(),
            "--format",
            "binary",
            fixture_path("multiline.sh").to_str().unwrap(),
        ])
        .output()
        .expect("Failed to run launcher");

    assert!(
        output.status.success(),
        "Launcher failed: stderr={}",
        String::from_utf8_lossy(&output.stderr)
    );

    // Verify binary trace exists
    let trace_bin = output_dir.path().join("trace.bin");
    assert!(trace_bin.exists(), "trace.bin not found");
    assert!(
        std::fs::metadata(&trace_bin).unwrap().len() > 0,
        "trace.bin is empty"
    );

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

    // Read trace.json and verify it contains function-related events
    let trace_content = read_trace_json(&output_dir);

    // Verify Function registration events exist for "greet"
    assert!(
        trace_content.contains("\"greet\""),
        "trace.json should contain function name 'greet', content: {}",
        &trace_content[..trace_content.len().min(2000)]
    );

    // Verify Call events exist (serde serialization of CallRecord)
    assert!(
        trace_content.contains("\"Call\""),
        "trace.json should contain Call events, content: {}",
        &trace_content[..trace_content.len().min(2000)]
    );

    // Verify Function registration events exist
    assert!(
        trace_content.contains("\"Function\""),
        "trace.json should contain Function events, content: {}",
        &trace_content[..trace_content.len().min(2000)]
    );

    // Verify Return events exist
    assert!(
        trace_content.contains("\"Return\""),
        "trace.json should contain Return events, content: {}",
        &trace_content[..trace_content.len().min(2000)]
    );

    // Verify Step events still work
    assert!(
        trace_content.contains("\"Step\""),
        "trace.json should contain Step events, content: {}",
        &trace_content[..trace_content.len().min(2000)]
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

    // Read trace.json and verify nesting
    let trace_content = read_trace_json(&output_dir);

    // Verify both function names are registered
    assert!(
        trace_content.contains("\"outer\""),
        "trace.json should contain function name 'outer'"
    );
    assert!(
        trace_content.contains("\"inner\""),
        "trace.json should contain function name 'inner'"
    );

    // Verify Call events for both functions
    assert!(
        trace_content.contains("\"Call\""),
        "trace.json should contain Call events"
    );

    // Verify Return events for both functions
    assert!(
        trace_content.contains("\"Return\""),
        "trace.json should contain Return events"
    );

    // Parse trace.json to verify ordering: outer Call should appear before inner Call
    let trace_events: Vec<serde_json::Value> =
        serde_json::from_str(&trace_content).expect("trace.json should be valid JSON array");

    // Find indices of Function registrations
    let outer_func_idx = trace_events
        .iter()
        .position(|e| {
            e.get("Function")
                .and_then(|f| f.get("name"))
                .and_then(|n| n.as_str())
                .map_or(false, |n| n == "outer")
        })
        .expect("Should find Function event for 'outer'");

    let inner_func_idx = trace_events
        .iter()
        .position(|e| {
            e.get("Function")
                .and_then(|f| f.get("name"))
                .and_then(|n| n.as_str())
                .map_or(false, |n| n == "inner")
        })
        .expect("Should find Function event for 'inner'");

    // outer is called first, so its Function registration should come first
    assert!(
        outer_func_idx < inner_func_idx,
        "outer Function event (idx {}) should appear before inner Function event (idx {})",
        outer_func_idx,
        inner_func_idx
    );

    // Count Return events to verify we get returns for both inner and outer
    let return_count = trace_events
        .iter()
        .filter(|e| e.get("Return").is_some())
        .count();
    assert!(
        return_count >= 2,
        "Should have at least 2 Return events (inner + outer), got {}",
        return_count
    );
}

#[test]
fn test_bash_exit_code() {
    let (output_dir, _stdout, _stderr) = record_fixture("simple.sh");

    let trace_content = read_trace_json(&output_dir);

    // Parse the trace and look for a Return event at the end (EXIT generates a Return)
    let trace_events: Vec<serde_json::Value> =
        serde_json::from_str(&trace_content).expect("trace.json should be valid JSON array");

    // The EXIT event is translated to a Return event by the trace bridge.
    // For a successfully completing script, the return value should be 0.
    let last_return = trace_events
        .iter()
        .rev()
        .find(|e| e.get("Return").is_some())
        .expect("Should have at least one Return event for EXIT");

    let return_record = last_return.get("Return").unwrap();
    let return_value = return_record
        .get("return_value")
        .expect("Return should have return_value");

    // The return value is a ValueRecord with kind="Int" and i=<code>
    assert_eq!(
        return_value.get("kind").and_then(|k| k.as_str()),
        Some("Int"),
        "Exit return value should be of kind Int, got: {:?}",
        return_value
    );
    let exit_code = return_value
        .get("i")
        .and_then(|i| i.as_i64())
        .expect("Exit return value should have 'i' field");

    assert_eq!(exit_code, 0, "Exit code should be 0 for simple.sh");
}
