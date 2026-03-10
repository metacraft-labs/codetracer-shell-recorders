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

// ============================================================================
// M4: Variable Capture & Type Inference Tests
// ============================================================================

/// Helper: parse trace.json and return all unique VariableName strings.
fn extract_variable_names(output_dir: &TempDir) -> Vec<String> {
    let trace_content = read_trace_json(output_dir);
    let trace_events: Vec<serde_json::Value> =
        serde_json::from_str(&trace_content).expect("trace.json should be valid JSON array");

    trace_events
        .iter()
        .filter_map(|e| {
            e.get("VariableName")
                .and_then(|v| v.as_str())
                .map(String::from)
        })
        .collect::<std::collections::HashSet<_>>()
        .into_iter()
        .collect()
}

/// Helper: find all Value events for a given variable name.
/// Returns Vec of (variable_id, value_record) for each Value event following
/// a VariableName event that matches the given name.
fn find_variable_values(output_dir: &TempDir, var_name: &str) -> Vec<serde_json::Value> {
    let trace_content = read_trace_json(output_dir);
    let trace_events: Vec<serde_json::Value> =
        serde_json::from_str(&trace_content).expect("trace.json should be valid JSON array");

    // First, find the variable_id for this name by looking at VariableName events.
    // The variable_id is implicit: each VariableName event assigns the next sequential id.
    let mut var_id: Option<usize> = None;
    let mut next_var_id: usize = 0;

    for event in &trace_events {
        if let Some(name) = event.get("VariableName").and_then(|v| v.as_str()) {
            if name == var_name && var_id.is_none() {
                var_id = Some(next_var_id);
            }
            next_var_id += 1;
        }
    }

    let var_id = match var_id {
        Some(id) => id,
        None => return vec![],
    };

    // Now collect all Value events with this variable_id
    trace_events
        .iter()
        .filter_map(|e| {
            e.get("Value").and_then(|v| {
                let vid = v.get("variable_id")?.as_u64()?;
                if vid == var_id as u64 {
                    Some(v.get("value")?.clone())
                } else {
                    None
                }
            })
        })
        .collect()
}

#[test]
fn test_bash_scalar_variable_capture() {
    let (output_dir, stdout, _stderr) = record_fixture("variables.sh");

    // Verify script produced expected output
    assert!(
        stdout.contains("hello world 52"),
        "Expected 'hello world 52' in stdout, got: {}",
        stdout
    );

    // Verify user variables are present in trace
    let var_names = extract_variable_names(&output_dir);

    assert!(
        var_names.contains(&"x".to_string()),
        "Should capture variable 'x', found: {:?}",
        var_names
    );
    assert!(
        var_names.contains(&"y".to_string()),
        "Should capture variable 'y', found: {:?}",
        var_names
    );
    assert!(
        var_names.contains(&"z".to_string()),
        "Should capture variable 'z', found: {:?}",
        var_names
    );
    assert!(
        var_names.contains(&"count".to_string()),
        "Should capture variable 'count', found: {:?}",
        var_names
    );

    // Verify "x" has String kind (plain variable, no declare -i)
    let x_values = find_variable_values(&output_dir, "x");
    assert!(!x_values.is_empty(), "Should have Value events for 'x'");
    let x_kind = x_values[0].get("kind").and_then(|k| k.as_str());
    assert_eq!(
        x_kind,
        Some("String"),
        "Variable 'x' should be String kind, got: {:?}",
        x_kind
    );

    // Verify "count" has Int kind (from declare -i)
    let count_values = find_variable_values(&output_dir, "count");
    assert!(
        !count_values.is_empty(),
        "Should have Value events for 'count'"
    );
    let count_kind = count_values[0].get("kind").and_then(|k| k.as_str());
    assert_eq!(
        count_kind,
        Some("Int"),
        "Variable 'count' should be Int kind (declare -i), got: {:?}",
        count_kind
    );

    // Verify "count" has value 42
    let count_i = count_values[0].get("i").and_then(|v| v.as_i64());
    assert_eq!(
        count_i,
        Some(42),
        "Variable 'count' should have value 42, got: {:?}",
        count_i
    );

    // Verify "y" has String kind and contains "hello world"
    let y_values = find_variable_values(&output_dir, "y");
    assert!(!y_values.is_empty(), "Should have Value events for 'y'");
    let y_kind = y_values[0].get("kind").and_then(|k| k.as_str());
    assert_eq!(
        y_kind,
        Some("String"),
        "Variable 'y' should be String kind, got: {:?}",
        y_kind
    );
    let y_text = y_values[0].get("text").and_then(|v| v.as_str());
    assert_eq!(
        y_text,
        Some("hello world"),
        "Variable 'y' should have value 'hello world', got: {:?}",
        y_text
    );
}

#[test]
fn test_bash_array_variable_capture() {
    let (output_dir, _stdout, _stderr) = record_fixture("variables.sh");

    let var_names = extract_variable_names(&output_dir);
    assert!(
        var_names.contains(&"fruits".to_string()),
        "Should capture variable 'fruits', found: {:?}",
        var_names
    );

    // Verify "fruits" appears as a value in the trace
    let fruits_values = find_variable_values(&output_dir, "fruits");
    assert!(
        !fruits_values.is_empty(),
        "Should have Value events for 'fruits'"
    );

    // The type for fruits should be Seq (Array type, kind=0 in TypeKind enum)
    // The value is stored as a String containing the bash array representation
    let fruits_kind = fruits_values[0].get("kind").and_then(|k| k.as_str());
    assert_eq!(
        fruits_kind,
        Some("String"),
        "Array variable 'fruits' value should be stored as String kind, got: {:?}",
        fruits_kind
    );

    // The text should contain the array elements
    let fruits_text = fruits_values[0]
        .get("text")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    assert!(
        fruits_text.contains("apple"),
        "Array 'fruits' should contain 'apple', got: {}",
        fruits_text
    );
    assert!(
        fruits_text.contains("banana"),
        "Array 'fruits' should contain 'banana', got: {}",
        fruits_text
    );
    assert!(
        fruits_text.contains("cherry"),
        "Array 'fruits' should contain 'cherry', got: {}",
        fruits_text
    );
}

#[test]
fn test_bash_assoc_array_capture() {
    let (output_dir, _stdout, _stderr) = record_fixture("variables.sh");

    let var_names = extract_variable_names(&output_dir);
    assert!(
        var_names.contains(&"colors".to_string()),
        "Should capture variable 'colors', found: {:?}",
        var_names
    );

    // Verify "colors" appears as a value in the trace
    let colors_values = find_variable_values(&output_dir, "colors");
    assert!(
        !colors_values.is_empty(),
        "Should have Value events for 'colors'"
    );

    // Assoc arrays are stored as String kind with the bash representation
    let colors_kind = colors_values[0].get("kind").and_then(|k| k.as_str());
    assert_eq!(
        colors_kind,
        Some("String"),
        "Assoc array 'colors' value should be stored as String kind, got: {:?}",
        colors_kind
    );

    // The text should contain the key-value pairs
    let colors_text = colors_values[0]
        .get("text")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    assert!(
        colors_text.contains("red"),
        "Assoc array 'colors' should contain key 'red', got: {}",
        colors_text
    );
    assert!(
        colors_text.contains("#ff0000"),
        "Assoc array 'colors' should contain value '#ff0000', got: {}",
        colors_text
    );
    assert!(
        colors_text.contains("green"),
        "Assoc array 'colors' should contain key 'green', got: {}",
        colors_text
    );
}

#[test]
fn test_bash_builtin_filtering() {
    let (output_dir, _stdout, _stderr) = record_fixture("simple.sh");

    let var_names = extract_variable_names(&output_dir);

    // User variables from simple.sh should be present
    assert!(
        var_names.contains(&"x".to_string()),
        "Should capture user variable 'x', found: {:?}",
        var_names
    );
    assert!(
        var_names.contains(&"y".to_string()),
        "Should capture user variable 'y', found: {:?}",
        var_names
    );
    assert!(
        var_names.contains(&"z".to_string()),
        "Should capture user variable 'z', found: {:?}",
        var_names
    );

    // Bash builtins and environment variables should NOT be present
    for builtin in &[
        "BASH_VERSION",
        "HOME",
        "PATH",
        "PWD",
        "SHELL",
        "USER",
        "SHLVL",
        "BASH_SOURCE",
        "BASH_LINENO",
        "FUNCNAME",
        "PIPESTATUS",
        "BASH_REMATCH",
    ] {
        assert!(
            !var_names.contains(&builtin.to_string()),
            "Should NOT capture builtin '{}', found: {:?}",
            builtin,
            var_names
        );
    }
}

// ============================================================================
// M5: IO, Errors & Edge Cases Tests
// ============================================================================

/// Helper: find all Event entries in the trace with a given kind.
/// kind=0 is Write (EventLogKind::Write), kind=11 is Error (EventLogKind::Error).
fn find_trace_events_by_kind(output_dir: &TempDir, kind: u64) -> Vec<serde_json::Value> {
    let trace_content = read_trace_json(output_dir);
    let trace_events: Vec<serde_json::Value> =
        serde_json::from_str(&trace_content).expect("trace.json should be valid JSON array");

    trace_events
        .iter()
        .filter_map(|e| {
            e.get("Event").and_then(|ev| {
                let k = ev.get("kind")?.as_u64()?;
                if k == kind {
                    Some(ev.clone())
                } else {
                    None
                }
            })
        })
        .collect()
}

#[test]
fn test_bash_error_trap() {
    // Record errors.sh — it contains `false` and `ls /nonexistent/path`
    // which both fail. The script should still complete.
    let (output_dir, stdout, _stderr) = record_fixture("errors.sh");

    // The script should finish and print "done"
    assert!(
        stdout.contains("done"),
        "Expected 'done' in stdout (script should complete despite errors), got: {}",
        stdout
    );

    // Read trace.json and find Error events (kind=11)
    let error_events = find_trace_events_by_kind(&output_dir, 11);

    // We expect at least 2 Error events: one for `false` and one for `ls /nonexistent/path`
    assert!(
        error_events.len() >= 2,
        "Expected at least 2 Error events for 'false' and 'ls /nonexistent/path', got {}: {:?}",
        error_events.len(),
        error_events
    );

    // Verify one error is for the `false` command
    let has_false_error = error_events.iter().any(|ev| {
        ev.get("content")
            .and_then(|c| c.as_str())
            .map_or(false, |c| c.contains("false"))
    });
    assert!(
        has_false_error,
        "Expected an Error event mentioning 'false', got: {:?}",
        error_events
    );

    // Verify one error is for the `ls` command
    let has_ls_error = error_events.iter().any(|ev| {
        ev.get("content")
            .and_then(|c| c.as_str())
            .map_or(false, |c| c.contains("ls"))
    });
    assert!(
        has_ls_error,
        "Expected an Error event mentioning 'ls', got: {:?}",
        error_events
    );

    // Verify the script still has Step events (it didn't crash)
    let trace_content = read_trace_json(&output_dir);
    let trace_events: Vec<serde_json::Value> =
        serde_json::from_str(&trace_content).expect("trace.json should be valid JSON array");
    let step_count = trace_events
        .iter()
        .filter(|e| e.get("Step").is_some())
        .count();
    assert!(
        step_count >= 5,
        "Expected at least 5 Step events in errors.sh, got {}",
        step_count
    );

    // Verify user variables were captured despite errors
    let var_names = extract_variable_names(&output_dir);
    assert!(
        var_names.contains(&"x".to_string()),
        "Should capture variable 'x' despite errors, found: {:?}",
        var_names
    );
    assert!(
        var_names.contains(&"y".to_string()),
        "Should capture variable 'y' despite errors, found: {:?}",
        var_names
    );
    assert!(
        var_names.contains(&"z".to_string()),
        "Should capture variable 'z' despite errors, found: {:?}",
        var_names
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

    // Read trace.json and find Write events (kind=0)
    let write_events = find_trace_events_by_kind(&output_dir, 0);

    // We expect at least 2 Write events: for echo "hello" and printf "world\n"
    // (echo "x is $x" should also produce one)
    assert!(
        write_events.len() >= 2,
        "Expected at least 2 Write events for echo/printf commands, got {}: {:?}",
        write_events.len(),
        write_events
    );

    // Verify at least one Write event references the echo command
    let has_echo_write = write_events.iter().any(|ev| {
        ev.get("content")
            .and_then(|c| c.as_str())
            .map_or(false, |c| c.contains("echo"))
    });
    assert!(
        has_echo_write,
        "Expected a Write event referencing 'echo', got: {:?}",
        write_events
    );

    // Verify at least one Write event references the printf command
    let has_printf_write = write_events.iter().any(|ev| {
        ev.get("content")
            .and_then(|c| c.as_str())
            .map_or(false, |c| c.contains("printf"))
    });
    assert!(
        has_printf_write,
        "Expected a Write event referencing 'printf', got: {:?}",
        write_events
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

    // Verify the function from sourced_lib.sh appears in trace
    let trace_content = read_trace_json(&output_dir);

    assert!(
        trace_content.contains("\"lib_func\""),
        "trace.json should contain function name 'lib_func' from sourced file, content: {}",
        &trace_content[..trace_content.len().min(2000)]
    );

    // Verify Call and Function events exist
    assert!(
        trace_content.contains("\"Call\""),
        "trace.json should contain Call events for lib_func"
    );
    assert!(
        trace_content.contains("\"Function\""),
        "trace.json should contain Function events for lib_func"
    );

    // Verify LIB_VAR was captured
    let var_names = extract_variable_names(&output_dir);
    assert!(
        var_names.contains(&"LIB_VAR".to_string()),
        "Should capture variable 'LIB_VAR' from sourced file, found: {:?}",
        var_names
    );
}

// ============================================================================
// M6: End-to-End Validation & CLI Integration Tests
// ============================================================================

#[test]
fn e2e_bash_simple_script() {
    // Record simple.sh, verify COMPLETE trace folder structure
    let (output_dir, _stdout, _stderr) = record_fixture("simple.sh");

    // trace.json exists and is non-empty
    let trace_json = output_dir.path().join("trace.json");
    assert!(trace_json.exists(), "trace.json not found");
    let trace_size = std::fs::metadata(&trace_json).unwrap().len();
    assert!(trace_size > 0, "trace.json is empty");

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

    // Read the trace
    let trace_content = read_trace_json(&output_dir);
    let trace_events: Vec<serde_json::Value> =
        serde_json::from_str(&trace_content).expect("trace.json should be valid JSON array");

    // Verify trace has Function events for count_to, classify, lib_func
    let function_names: Vec<String> = trace_events
        .iter()
        .filter_map(|e| {
            e.get("Function")
                .and_then(|f| f.get("name"))
                .and_then(|n| n.as_str())
                .map(String::from)
        })
        .collect();

    assert!(
        function_names.iter().any(|n| n == "count_to"),
        "trace should have Function event for 'count_to', found: {:?}",
        function_names
    );
    assert!(
        function_names.iter().any(|n| n == "classify"),
        "trace should have Function event for 'classify', found: {:?}",
        function_names
    );
    assert!(
        function_names.iter().any(|n| n == "lib_func"),
        "trace should have Function event for 'lib_func', found: {:?}",
        function_names
    );

    // Verify trace has Step events
    let step_count = trace_events
        .iter()
        .filter(|e| e.get("Step").is_some())
        .count();
    assert!(
        step_count >= 10,
        "Expected at least 10 Step events in comprehensive.sh, got {}",
        step_count
    );

    // Verify trace has Call events
    let call_count = trace_events
        .iter()
        .filter(|e| e.get("Call").is_some())
        .count();
    assert!(
        call_count >= 4,
        "Expected at least 4 Call events (lib_func, count_to, classify x3), got {}",
        call_count
    );

    // Verify trace has Return events
    let return_count = trace_events
        .iter()
        .filter(|e| e.get("Return").is_some())
        .count();
    assert!(
        return_count >= 4,
        "Expected at least 4 Return events, got {}",
        return_count
    );

    // Verify trace has variable events (numbers, config, etc.)
    let var_names = extract_variable_names(&output_dir);
    assert!(
        var_names.contains(&"numbers".to_string()),
        "Should capture variable 'numbers', found: {:?}",
        var_names
    );
    assert!(
        var_names.contains(&"config".to_string()),
        "Should capture variable 'config', found: {:?}",
        var_names
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

    // Also verify that the regular trace_metadata.json still exists and is valid
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
