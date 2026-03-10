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

#[test]
fn test_bash_step_events_simple() {
    // Build the trace writer first
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

    let output_dir = TempDir::new().expect("Failed to create temp dir");

    let status = Command::new("bash")
        .args([
            launcher_path().to_str().unwrap(),
            "--output-dir",
            output_dir.path().to_str().unwrap(),
            "--format",
            "json",
            fixture_path("simple.sh").to_str().unwrap(),
        ])
        .status()
        .expect("Failed to run launcher");

    assert!(status.success(), "Launcher exited with non-zero status");

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
    let paths: Vec<serde_json::Value> =
        serde_json::from_str(&std::fs::read_to_string(&paths_json).expect("Failed to read paths"))
            .expect("Invalid paths JSON");

    assert!(!paths.is_empty(), "paths should not be empty");
    let has_simple = paths
        .iter()
        .any(|p| p.as_str().map_or(false, |s| s.contains("simple.sh")));
    assert!(has_simple, "paths should contain simple.sh: {:?}", paths);
}

#[test]
fn test_bash_path_registration() {
    let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .to_path_buf();

    Command::new("cargo")
        .args(["build"])
        .current_dir(&repo_root)
        .status()
        .expect("Failed to build");

    let output_dir = TempDir::new().expect("Failed to create temp dir");

    let status = Command::new("bash")
        .args([
            launcher_path().to_str().unwrap(),
            "--output-dir",
            output_dir.path().to_str().unwrap(),
            "--format",
            "json",
            fixture_path("simple.sh").to_str().unwrap(),
        ])
        .status()
        .expect("Failed to run launcher");

    assert!(status.success(), "Launcher failed");

    let paths: Vec<serde_json::Value> = serde_json::from_str(
        &std::fs::read_to_string(output_dir.path().join("trace_paths.json")).unwrap(),
    )
    .unwrap();

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
    let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .to_path_buf();

    Command::new("cargo")
        .args(["build"])
        .current_dir(&repo_root)
        .status()
        .expect("Failed to build");

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
