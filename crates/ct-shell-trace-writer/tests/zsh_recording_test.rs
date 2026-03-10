// Test that the zsh recorder produces valid trace files
use std::path::PathBuf;
use std::process::Command;
use tempfile::TempDir;

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
fn find_variable_values(output_dir: &TempDir, var_name: &str) -> Vec<serde_json::Value> {
    let trace_content = read_trace_json(output_dir);
    let trace_events: Vec<serde_json::Value> =
        serde_json::from_str(&trace_content).expect("trace.json should be valid JSON array");

    // Find the variable_id for this name by looking at VariableName events.
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

    // Collect all Value events with this variable_id
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

    // Verify trace files exist
    let trace_json = output_dir.path().join("trace.json");
    let metadata_json = output_dir.path().join("trace_metadata.json");
    let paths_json = output_dir.path().join("trace_paths.json");

    assert!(trace_json.exists(), "trace.json not found");
    assert!(metadata_json.exists(), "trace_metadata.json not found");
    assert!(paths_json.exists(), "trace_paths.json not found");

    // Read and verify trace.json contains step events
    let trace_content = read_trace_json(&output_dir);
    assert!(!trace_content.is_empty(), "trace.json is empty");

    let trace_events: Vec<serde_json::Value> =
        serde_json::from_str(&trace_content).expect("trace.json should be valid JSON array");

    // Verify Step events exist
    let step_count = trace_events
        .iter()
        .filter(|e| e.get("Step").is_some())
        .count();
    assert!(
        step_count >= 4,
        "Expected at least 4 Step events for simple.zsh (4 lines of code), got {}",
        step_count
    );

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

    // Read trace.json and verify function-related events
    let trace_content = read_trace_json(&output_dir);
    let trace_events: Vec<serde_json::Value> =
        serde_json::from_str(&trace_content).expect("trace.json should be valid JSON array");

    // Verify Function registration events exist for "greet" and "add"
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
        function_names.iter().any(|n| n == "greet"),
        "trace should have Function event for 'greet', found: {:?}",
        function_names
    );
    assert!(
        function_names.iter().any(|n| n == "add"),
        "trace should have Function event for 'add', found: {:?}",
        function_names
    );

    // Verify Call events exist
    let call_count = trace_events
        .iter()
        .filter(|e| e.get("Call").is_some())
        .count();
    assert!(
        call_count >= 3,
        "Expected at least 3 Call events (toplevel + greet + add), got {}",
        call_count
    );

    // Verify Return events exist
    let return_count = trace_events
        .iter()
        .filter(|e| e.get("Return").is_some())
        .count();
    assert!(
        return_count >= 2,
        "Expected at least 2 Return events (greet + add returns), got {}",
        return_count
    );

    // Verify Step events exist
    assert!(
        trace_content.contains("\"Step\""),
        "trace.json should contain Step events"
    );

    // Verify the greet function's FUNC event has line=2 (where it's defined)
    let greet_func = trace_events
        .iter()
        .find(|e| {
            e.get("Function")
                .and_then(|f| f.get("name"))
                .and_then(|n| n.as_str())
                .map_or(false, |n| n == "greet")
        })
        .expect("Should find Function event for 'greet'");
    let greet_line = greet_func
        .get("Function")
        .unwrap()
        .get("line")
        .and_then(|l| l.as_u64())
        .expect("greet Function should have line");
    assert_eq!(
        greet_line, 2,
        "greet should be defined at line 2, got: {}",
        greet_line
    );

    // Verify the add function's FUNC event has line=7
    let add_func = trace_events
        .iter()
        .find(|e| {
            e.get("Function")
                .and_then(|f| f.get("name"))
                .and_then(|n| n.as_str())
                .map_or(false, |n| n == "add")
        })
        .expect("Should find Function event for 'add'");
    let add_line = add_func
        .get("Function")
        .unwrap()
        .get("line")
        .and_then(|l| l.as_u64())
        .expect("add Function should have line");
    assert_eq!(
        add_line, 7,
        "add should be defined at line 7, got: {}",
        add_line
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
    assert!(
        var_names.contains(&"fruits".to_string()),
        "Should capture variable 'fruits', found: {:?}",
        var_names
    );
    assert!(
        var_names.contains(&"colors".to_string()),
        "Should capture variable 'colors', found: {:?}",
        var_names
    );
    assert!(
        var_names.contains(&"pi".to_string()),
        "Should capture variable 'pi', found: {:?}",
        var_names
    );

    // Verify "x" has String kind (plain variable)
    let x_values = find_variable_values(&output_dir, "x");
    assert!(!x_values.is_empty(), "Should have Value events for 'x'");
    let x_kind = x_values[0].get("kind").and_then(|k| k.as_str());
    assert_eq!(
        x_kind,
        Some("String"),
        "Variable 'x' should be String kind, got: {:?}",
        x_kind
    );

    // Verify "count" has Int kind (from integer declaration)
    let count_values = find_variable_values(&output_dir, "count");
    assert!(
        !count_values.is_empty(),
        "Should have Value events for 'count'"
    );
    let count_kind = count_values[0].get("kind").and_then(|k| k.as_str());
    assert_eq!(
        count_kind,
        Some("Int"),
        "Variable 'count' should be Int kind (integer), got: {:?}",
        count_kind
    );
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

    // Verify "fruits" is present (array)
    let fruits_values = find_variable_values(&output_dir, "fruits");
    assert!(
        !fruits_values.is_empty(),
        "Should have Value events for 'fruits'"
    );
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

    // Verify "colors" is present (assoc array) and contains keys
    let colors_values = find_variable_values(&output_dir, "colors");
    assert!(
        !colors_values.is_empty(),
        "Should have Value events for 'colors'"
    );
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

    // Verify "pi" is present (float)
    let pi_values = find_variable_values(&output_dir, "pi");
    assert!(!pi_values.is_empty(), "Should have Value events for 'pi'");
    // Float values are stored with kind="Float" and the value in the "f" field
    let pi_kind = pi_values[0].get("kind").and_then(|k| k.as_str());
    assert_eq!(
        pi_kind,
        Some("Float"),
        "Variable 'pi' should be Float kind, got: {:?}",
        pi_kind
    );
    let pi_f = pi_values[0].get("f").and_then(|v| v.as_str()).unwrap_or("");
    assert!(
        pi_f.contains("3.14159"),
        "Float 'pi' should contain '3.14159', got: {}",
        pi_f
    );

    // Verify zsh internal variables are NOT present
    for internal in &[
        "ZSH_VERSION",
        "ZSH_DEBUG_CMD",
        "MATCH",
        "match",
        "MBEGIN",
        "MEND",
        "mbegin",
        "mend",
    ] {
        assert!(
            !var_names.contains(&internal.to_string()),
            "Should NOT capture zsh internal '{}', found: {:?}",
            internal,
            var_names
        );
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

    // Read trace.json and find Error events (kind=11)
    let error_events = find_trace_events_by_kind(&output_dir, 11);

    // We expect at least 2 Error events: one for `false` and one for `ls /nonexistent...`
    assert!(
        error_events.len() >= 2,
        "Expected at least 2 Error events for 'false' and 'ls /nonexistent...', got {}: {:?}",
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
        "Expected at least 5 Step events in errors.zsh, got {}",
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

    // Read trace.json and find Write events (kind=0)
    let write_events = find_trace_events_by_kind(&output_dir, 0);

    // We expect at least 3 Write events: for print, echo, printf
    assert!(
        write_events.len() >= 3,
        "Expected at least 3 Write events for print/echo/printf commands, got {}: {:?}",
        write_events.len(),
        write_events
    );

    // Verify at least one Write event references the print command
    let has_print_write = write_events.iter().any(|ev| {
        ev.get("content")
            .and_then(|c| c.as_str())
            .map_or(false, |c| c.contains("print"))
    });
    assert!(
        has_print_write,
        "Expected a Write event referencing 'print', got: {:?}",
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
fn test_zsh_exit_code() {
    require_zsh!();
    let (output_dir, _stdout, _stderr) = record_fixture("simple.zsh");

    let trace_content = read_trace_json(&output_dir);
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

    assert_eq!(exit_code, 0, "Exit code should be 0 for simple.zsh");
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

    let var_names = extract_variable_names(&output_dir);

    // User variables from simple.zsh should be present
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

    // Zsh builtins and environment variables should NOT be present
    for builtin in &[
        "ZSH_VERSION",
        "HOME",
        "PATH",
        "PWD",
        "SHELL",
        "USER",
        "SHLVL",
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
            "--output-dir",
            output_dir.path().to_str().unwrap(),
            "--format",
            "json",
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
            "--output-dir",
            output_dir.path().to_str().unwrap(),
            "--format",
            "json",
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

/// Helper: parse trace.json and return all trace events as a Vec.
fn parse_trace_events(output_dir: &TempDir) -> Vec<serde_json::Value> {
    let trace_content = read_trace_json(output_dir);
    serde_json::from_str(&trace_content).expect("trace.json should be valid JSON array")
}

/// Helper: count events of a specific kind in the trace.
fn count_events_of_type(events: &[serde_json::Value], event_type: &str) -> usize {
    events
        .iter()
        .filter(|e| e.get(event_type).is_some())
        .count()
}

/// Helper: extract all function names from Function events.
fn extract_function_names(events: &[serde_json::Value]) -> Vec<String> {
    events
        .iter()
        .filter_map(|e| {
            e.get("Function")
                .and_then(|f| f.get("name"))
                .and_then(|n| n.as_str())
                .map(String::from)
        })
        .collect()
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

    // Verify Function event for lib_func exists
    let trace_events = parse_trace_events(&output_dir);
    let function_names = extract_function_names(&trace_events);
    assert!(
        function_names.iter().any(|n| n == "lib_func"),
        "trace should have Function event for 'lib_func', found: {:?}",
        function_names
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

    // Verify variables from both files are captured
    let var_names = extract_variable_names(&output_dir);
    assert!(
        var_names.contains(&"x".to_string()),
        "Should capture variable 'x' from with_source.zsh, found: {:?}",
        var_names
    );
    assert!(
        var_names.contains(&"y".to_string()),
        "Should capture variable 'y' from with_source.zsh, found: {:?}",
        var_names
    );
    assert!(
        var_names.contains(&"LIB_VAR".to_string()),
        "Should capture variable 'LIB_VAR' from zsh_sourced_lib.zsh, found: {:?}",
        var_names
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

    // Read the trace
    let trace_events = parse_trace_events(&output_dir);

    // Verify trace has Step events
    let step_count = count_events_of_type(&trace_events, "Step");
    assert!(
        step_count >= 10,
        "Expected at least 10 Step events in comprehensive.zsh, got {}",
        step_count
    );

    // Verify trace has Call events
    let call_count = count_events_of_type(&trace_events, "Call");
    assert!(
        call_count >= 4,
        "Expected at least 4 Call events (toplevel + process x3 + lib_func), got {}",
        call_count
    );

    // Verify trace has Return events
    let return_count = count_events_of_type(&trace_events, "Return");
    assert!(
        return_count >= 3,
        "Expected at least 3 Return events (process x3 returns), got {}",
        return_count
    );

    // Verify trace has Function events for process and lib_func
    let function_names = extract_function_names(&trace_events);
    assert!(
        function_names.iter().any(|n| n == "process"),
        "trace should have Function event for 'process', found: {:?}",
        function_names
    );
    assert!(
        function_names.iter().any(|n| n == "lib_func"),
        "trace should have Function event for 'lib_func', found: {:?}",
        function_names
    );

    // Verify integer, float, array, assoc array variables are captured
    let var_names = extract_variable_names(&output_dir);
    assert!(
        var_names.contains(&"count".to_string()),
        "Should capture integer variable 'count', found: {:?}",
        var_names
    );
    assert!(
        var_names.contains(&"pi".to_string()),
        "Should capture float variable 'pi', found: {:?}",
        var_names
    );
    assert!(
        var_names.contains(&"items".to_string()),
        "Should capture array variable 'items', found: {:?}",
        var_names
    );
    assert!(
        var_names.contains(&"config".to_string()),
        "Should capture assoc array variable 'config', found: {:?}",
        var_names
    );
    assert!(
        var_names.contains(&"result".to_string()),
        "Should capture variable 'result', found: {:?}",
        var_names
    );

    // Verify integer variable has Int kind
    let count_values = find_variable_values(&output_dir, "count");
    assert!(
        !count_values.is_empty(),
        "Should have Value events for 'count'"
    );
    let count_kind = count_values[0].get("kind").and_then(|k| k.as_str());
    assert_eq!(
        count_kind,
        Some("Int"),
        "Variable 'count' should be Int kind (integer), got: {:?}",
        count_kind
    );

    // Verify float variable has Float kind
    let pi_values = find_variable_values(&output_dir, "pi");
    assert!(!pi_values.is_empty(), "Should have Value events for 'pi'");
    let pi_kind = pi_values[0].get("kind").and_then(|k| k.as_str());
    assert_eq!(
        pi_kind,
        Some("Float"),
        "Variable 'pi' should be Float kind, got: {:?}",
        pi_kind
    );
    let pi_f = pi_values[0].get("f").and_then(|v| v.as_str()).unwrap_or("");
    assert!(
        pi_f.contains("3.14159"),
        "Float 'pi' should contain '3.14159', got: {}",
        pi_f
    );

    // Verify array variable contains expected elements
    let items_values = find_variable_values(&output_dir, "items");
    assert!(
        !items_values.is_empty(),
        "Should have Value events for 'items'"
    );
    let items_text = items_values[0]
        .get("text")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    assert!(
        items_text.contains("alpha"),
        "Array 'items' should contain 'alpha', got: {}",
        items_text
    );
    assert!(
        items_text.contains("beta"),
        "Array 'items' should contain 'beta', got: {}",
        items_text
    );
    assert!(
        items_text.contains("gamma"),
        "Array 'items' should contain 'gamma', got: {}",
        items_text
    );

    // Verify assoc array variable contains expected keys
    let config_values = find_variable_values(&output_dir, "config");
    assert!(
        !config_values.is_empty(),
        "Should have Value events for 'config'"
    );
    let config_text = config_values[0]
        .get("text")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    assert!(
        config_text.contains("host"),
        "Assoc array 'config' should contain key 'host', got: {}",
        config_text
    );
    assert!(
        config_text.contains("localhost"),
        "Assoc array 'config' should contain value 'localhost', got: {}",
        config_text
    );
    assert!(
        config_text.contains("port"),
        "Assoc array 'config' should contain key 'port', got: {}",
        config_text
    );
    assert!(
        config_text.contains("8080"),
        "Assoc array 'config' should contain value '8080', got: {}",
        config_text
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

    // Verify symbols.json contains process and lib_func
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

    // Parse trace events from both
    let bash_events = parse_trace_events(&bash_output);
    let zsh_events = parse_trace_events(&zsh_output);

    // Both should have Step events, and the counts should be within reasonable tolerance
    let bash_steps = count_events_of_type(&bash_events, "Step");
    let zsh_steps = count_events_of_type(&zsh_events, "Step");
    assert!(
        bash_steps >= 5,
        "Bash should have at least 5 Step events, got {}",
        bash_steps
    );
    assert!(
        zsh_steps >= 5,
        "Zsh should have at least 5 Step events, got {}",
        zsh_steps
    );
    // The step counts should be within a reasonable tolerance (recorders may differ slightly)
    let step_diff = (bash_steps as i64 - zsh_steps as i64).unsigned_abs() as usize;
    assert!(
        step_diff <= 5,
        "Step count difference should be <= 5 (bash={}, zsh={}, diff={})",
        bash_steps,
        zsh_steps,
        step_diff
    );

    // Both should have Function events for "greet"
    let bash_func_names = extract_function_names(&bash_events);
    let zsh_func_names = extract_function_names(&zsh_events);
    assert!(
        bash_func_names.iter().any(|n| n == "greet"),
        "Bash trace should have Function event for 'greet', found: {:?}",
        bash_func_names
    );
    assert!(
        zsh_func_names.iter().any(|n| n == "greet"),
        "Zsh trace should have Function event for 'greet', found: {:?}",
        zsh_func_names
    );

    // Both should have Call events for "greet"
    let bash_calls = count_events_of_type(&bash_events, "Call");
    let zsh_calls = count_events_of_type(&zsh_events, "Call");
    assert!(
        bash_calls >= 1,
        "Bash should have at least 1 Call event, got {}",
        bash_calls
    );
    assert!(
        zsh_calls >= 1,
        "Zsh should have at least 1 Call event, got {}",
        zsh_calls
    );

    // Both should have Return events
    let bash_returns = count_events_of_type(&bash_events, "Return");
    let zsh_returns = count_events_of_type(&zsh_events, "Return");
    assert!(
        bash_returns >= 1,
        "Bash should have at least 1 Return event, got {}",
        bash_returns
    );
    assert!(
        zsh_returns >= 1,
        "Zsh should have at least 1 Return event, got {}",
        zsh_returns
    );

    // Both should capture the same set of variables: x, y, z, result
    let bash_var_names = extract_variable_names(&bash_output);
    let zsh_var_names = extract_variable_names(&zsh_output);

    for var in &["x", "y", "z", "result"] {
        assert!(
            bash_var_names.contains(&var.to_string()),
            "Bash trace should capture variable '{}', found: {:?}",
            var,
            bash_var_names
        );
        assert!(
            zsh_var_names.contains(&var.to_string()),
            "Zsh trace should capture variable '{}', found: {:?}",
            var,
            zsh_var_names
        );
    }

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

    // Verify both produce symbols.json with "greet"
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
}
