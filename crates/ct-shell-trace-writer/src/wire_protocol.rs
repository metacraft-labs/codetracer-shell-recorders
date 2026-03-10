// Wire protocol parser for shell trace events.
//
// The wire protocol is a line-oriented text format where each line represents
// one event. Format: `TYPE key=value key=value ...`
//
// Values containing spaces must be quoted with double quotes.
// Backslash escapes \" and \\ are supported inside quoted values.

use std::collections::HashMap;
use std::fmt;

/// All event types that can appear in the wire protocol.
#[derive(Debug, Clone, PartialEq)]
pub enum WireEvent {
    Start {
        program: String,
        shell: String,
        shell_version: Option<String>,
    },
    Path {
        file: String,
    },
    Func {
        name: String,
        file: String,
        line: i64,
    },
    Step {
        file: String,
        line: i64,
    },
    Call {
        name: String,
    },
    Var {
        name: String,
        value: String,
        type_flag: String,
    },
    Write {
        content: String,
    },
    Return {
        status: i64,
    },
    Exit {
        code: i64,
    },
    Error {
        cmd: String,
        status: i64,
    },
}

/// Errors that can occur while parsing a wire protocol line.
#[derive(Debug, Clone, PartialEq)]
pub enum ParseError {
    EmptyLine,
    UnknownEventType(String),
    MissingField(String),
    InvalidNumber { field: String, value: String },
    MalformedKeyValue(String),
    UnterminatedQuote,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ParseError::EmptyLine => write!(f, "empty line"),
            ParseError::UnknownEventType(t) => write!(f, "unknown event type: {t}"),
            ParseError::MissingField(field) => write!(f, "missing required field: {field}"),
            ParseError::InvalidNumber { field, value } => {
                write!(f, "invalid number for field '{field}': '{value}'")
            }
            ParseError::MalformedKeyValue(s) => write!(f, "malformed key=value pair: {s}"),
            ParseError::UnterminatedQuote => write!(f, "unterminated quoted value"),
        }
    }
}

impl std::error::Error for ParseError {}

/// Parse a sequence of `key=value` pairs from the remainder of a line.
///
/// Values may be unquoted (no spaces) or double-quoted (spaces allowed).
/// Inside quoted values, `\"` produces a literal `"` and `\\` produces `\`.
pub fn parse_key_values(rest: &str) -> Result<HashMap<String, String>, ParseError> {
    let mut map = HashMap::new();
    let chars: Vec<char> = rest.chars().collect();
    let len = chars.len();
    let mut i = 0;

    while i < len {
        // Skip whitespace
        while i < len && chars[i].is_whitespace() {
            i += 1;
        }
        if i >= len {
            break;
        }

        // Read key (up to '=')
        let key_start = i;
        while i < len && chars[i] != '=' && !chars[i].is_whitespace() {
            i += 1;
        }
        if i >= len || chars[i] != '=' {
            let fragment: String = chars[key_start..].iter().collect();
            return Err(ParseError::MalformedKeyValue(fragment));
        }
        let key: String = chars[key_start..i].iter().collect();
        i += 1; // skip '='

        // Read value
        if i >= len {
            // key= with no value -> empty string
            map.insert(key, String::new());
            continue;
        }

        if chars[i] == '"' {
            // Quoted value
            i += 1; // skip opening quote
            let mut value = String::new();
            loop {
                if i >= len {
                    return Err(ParseError::UnterminatedQuote);
                }
                if chars[i] == '\\' && i + 1 < len {
                    match chars[i + 1] {
                        '"' => {
                            value.push('"');
                            i += 2;
                        }
                        '\\' => {
                            value.push('\\');
                            i += 2;
                        }
                        other => {
                            value.push('\\');
                            value.push(other);
                            i += 2;
                        }
                    }
                } else if chars[i] == '"' {
                    i += 1; // skip closing quote
                    break;
                } else {
                    value.push(chars[i]);
                    i += 1;
                }
            }
            map.insert(key, value);
        } else {
            // Unquoted value (until next whitespace)
            let val_start = i;
            while i < len && !chars[i].is_whitespace() {
                i += 1;
            }
            let value: String = chars[val_start..i].iter().collect();
            map.insert(key, value);
        }
    }

    Ok(map)
}

/// Helper to extract a required field from the key-value map.
fn require_field(kv: &HashMap<String, String>, field: &str) -> Result<String, ParseError> {
    kv.get(field)
        .cloned()
        .ok_or_else(|| ParseError::MissingField(field.to_string()))
}

/// Helper to parse a required integer field.
fn require_int_field(kv: &HashMap<String, String>, field: &str) -> Result<i64, ParseError> {
    let s = require_field(kv, field)?;
    s.parse::<i64>().map_err(|_| ParseError::InvalidNumber {
        field: field.to_string(),
        value: s,
    })
}

/// Parse one line of the wire protocol into a `WireEvent`.
pub fn parse_line(line: &str) -> Result<WireEvent, ParseError> {
    let line = line.trim();
    if line.is_empty() {
        return Err(ParseError::EmptyLine);
    }

    // Split into event type and the rest
    let (event_type, rest) = match line.find(char::is_whitespace) {
        Some(pos) => (&line[..pos], &line[pos..]),
        None => (line, ""),
    };

    let kv = parse_key_values(rest)?;

    match event_type {
        "START" => {
            let program = require_field(&kv, "program")?;
            let shell = require_field(&kv, "shell")?;
            let shell_version = kv.get("shell_version").cloned();
            Ok(WireEvent::Start {
                program,
                shell,
                shell_version,
            })
        }
        "PATH" => {
            let file = require_field(&kv, "file")?;
            Ok(WireEvent::Path { file })
        }
        "FUNC" => {
            let name = require_field(&kv, "name")?;
            let file = require_field(&kv, "file")?;
            let line = require_int_field(&kv, "line")?;
            Ok(WireEvent::Func { name, file, line })
        }
        "STEP" => {
            let file = require_field(&kv, "file")?;
            let line = require_int_field(&kv, "line")?;
            Ok(WireEvent::Step { file, line })
        }
        "CALL" => {
            let name = require_field(&kv, "name")?;
            Ok(WireEvent::Call { name })
        }
        "VAR" => {
            let name = require_field(&kv, "name")?;
            let value = require_field(&kv, "value")?;
            let type_flag = kv.get("type").cloned().unwrap_or_else(|| "s".to_string());
            Ok(WireEvent::Var {
                name,
                value,
                type_flag,
            })
        }
        "WRITE" => {
            let content = require_field(&kv, "content")?;
            Ok(WireEvent::Write { content })
        }
        "RETURN" => {
            let status = require_int_field(&kv, "status")?;
            Ok(WireEvent::Return { status })
        }
        "EXIT" => {
            let code = require_int_field(&kv, "code")?;
            Ok(WireEvent::Exit { code })
        }
        "ERROR" => {
            let cmd = require_field(&kv, "cmd")?;
            let status = require_int_field(&kv, "status")?;
            Ok(WireEvent::Error { cmd, status })
        }
        other => Err(ParseError::UnknownEventType(other.to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_start_event() {
        let event =
            parse_line("START program=/path/to/script.sh shell=bash shell_version=5.2.0").unwrap();
        assert_eq!(
            event,
            WireEvent::Start {
                program: "/path/to/script.sh".to_string(),
                shell: "bash".to_string(),
                shell_version: Some("5.2.0".to_string()),
            }
        );

        // Without shell_version
        let event2 = parse_line("START program=/my/script.sh shell=zsh").unwrap();
        assert_eq!(
            event2,
            WireEvent::Start {
                program: "/my/script.sh".to_string(),
                shell: "zsh".to_string(),
                shell_version: None,
            }
        );
    }

    #[test]
    fn test_parse_path_event() {
        let event = parse_line("PATH file=/some/dir/source.sh").unwrap();
        assert_eq!(
            event,
            WireEvent::Path {
                file: "/some/dir/source.sh".to_string()
            }
        );
    }

    #[test]
    fn test_parse_func_event() {
        let event = parse_line("FUNC name=my_function file=/path/to/source.sh line=10").unwrap();
        assert_eq!(
            event,
            WireEvent::Func {
                name: "my_function".to_string(),
                file: "/path/to/source.sh".to_string(),
                line: 10,
            }
        );
    }

    #[test]
    fn test_parse_step_event() {
        let event = parse_line("STEP file=/foo/bar.sh line=42").unwrap();
        assert_eq!(
            event,
            WireEvent::Step {
                file: "/foo/bar.sh".to_string(),
                line: 42,
            }
        );
    }

    #[test]
    fn test_parse_call_return_sequence() {
        let call = parse_line("CALL name=do_something").unwrap();
        assert_eq!(
            call,
            WireEvent::Call {
                name: "do_something".to_string()
            }
        );

        let ret = parse_line("RETURN status=0").unwrap();
        assert_eq!(ret, WireEvent::Return { status: 0 });

        let ret_nonzero = parse_line("RETURN status=127").unwrap();
        assert_eq!(ret_nonzero, WireEvent::Return { status: 127 });
    }

    #[test]
    fn test_parse_var_with_types() {
        // Integer type
        let var_int = parse_line("VAR name=count value=42 type=i").unwrap();
        assert_eq!(
            var_int,
            WireEvent::Var {
                name: "count".to_string(),
                value: "42".to_string(),
                type_flag: "i".to_string(),
            }
        );

        // String type (explicit)
        let var_str = parse_line("VAR name=greeting value=hello type=s").unwrap();
        assert_eq!(
            var_str,
            WireEvent::Var {
                name: "greeting".to_string(),
                value: "hello".to_string(),
                type_flag: "s".to_string(),
            }
        );

        // Float type
        let var_float = parse_line("VAR name=pi value=3.14 type=F").unwrap();
        assert_eq!(
            var_float,
            WireEvent::Var {
                name: "pi".to_string(),
                value: "3.14".to_string(),
                type_flag: "F".to_string(),
            }
        );

        // Seq (indexed array)
        let var_seq = parse_line(r#"VAR name=arr value="(1 2 3)" type=a"#).unwrap();
        assert_eq!(
            var_seq,
            WireEvent::Var {
                name: "arr".to_string(),
                value: "(1 2 3)".to_string(),
                type_flag: "a".to_string(),
            }
        );

        // TableKind (associative array)
        let var_assoc = parse_line(r#"VAR name=map value="([a]=1 [b]=2)" type=A"#).unwrap();
        assert_eq!(
            var_assoc,
            WireEvent::Var {
                name: "map".to_string(),
                value: "([a]=1 [b]=2)".to_string(),
                type_flag: "A".to_string(),
            }
        );

        // Default type (no type key -> String)
        let var_default = parse_line("VAR name=x value=stuff").unwrap();
        assert_eq!(
            var_default,
            WireEvent::Var {
                name: "x".to_string(),
                value: "stuff".to_string(),
                type_flag: "s".to_string(),
            }
        );
    }

    #[test]
    fn test_parse_write_event() {
        let event = parse_line(r#"WRITE content="hello world""#).unwrap();
        assert_eq!(
            event,
            WireEvent::Write {
                content: "hello world".to_string()
            }
        );
    }

    #[test]
    fn test_parse_exit_event() {
        let event = parse_line("EXIT code=0").unwrap();
        assert_eq!(event, WireEvent::Exit { code: 0 });

        let event2 = parse_line("EXIT code=1").unwrap();
        assert_eq!(event2, WireEvent::Exit { code: 1 });
    }

    #[test]
    fn test_parse_error_event() {
        let event = parse_line(r#"ERROR cmd="false" status=1"#).unwrap();
        assert_eq!(
            event,
            WireEvent::Error {
                cmd: "false".to_string(),
                status: 1,
            }
        );

        // cmd with spaces
        let event2 = parse_line(r#"ERROR cmd="ls /nonexistent" status=2"#).unwrap();
        assert_eq!(
            event2,
            WireEvent::Error {
                cmd: "ls /nonexistent".to_string(),
                status: 2,
            }
        );
    }

    #[test]
    fn test_parse_quoted_value() {
        // Value with spaces
        let event = parse_line(r#"VAR name=msg value="hello world" type=s"#).unwrap();
        assert_eq!(
            event,
            WireEvent::Var {
                name: "msg".to_string(),
                value: "hello world".to_string(),
                type_flag: "s".to_string(),
            }
        );

        // Value with escaped quotes
        let event2 = parse_line(r#"VAR name=msg value="he said \"hi\"" type=s"#).unwrap();
        assert_eq!(
            event2,
            WireEvent::Var {
                name: "msg".to_string(),
                value: r#"he said "hi""#.to_string(),
                type_flag: "s".to_string(),
            }
        );

        // Value with escaped backslash
        let event3 = parse_line(r#"VAR name=path value="C:\\Users\\test" type=s"#).unwrap();
        assert_eq!(
            event3,
            WireEvent::Var {
                name: "path".to_string(),
                value: r"C:\Users\test".to_string(),
                type_flag: "s".to_string(),
            }
        );
    }

    #[test]
    fn test_parse_invalid_line() {
        // Empty line
        assert_eq!(parse_line("").unwrap_err(), ParseError::EmptyLine);
        assert_eq!(parse_line("   ").unwrap_err(), ParseError::EmptyLine);

        // Unknown event type
        assert!(matches!(
            parse_line("UNKNOWN foo=bar").unwrap_err(),
            ParseError::UnknownEventType(_)
        ));

        // Missing required field
        assert!(matches!(
            parse_line("STEP file=/foo.sh").unwrap_err(),
            ParseError::MissingField(ref f) if f == "line"
        ));

        // Invalid number
        assert!(matches!(
            parse_line("STEP file=/foo.sh line=abc").unwrap_err(),
            ParseError::InvalidNumber { .. }
        ));

        // Malformed key=value (no equals sign)
        assert!(matches!(
            parse_line("STEP badtoken").unwrap_err(),
            ParseError::MalformedKeyValue(_)
        ));

        // Unterminated quote
        assert!(matches!(
            parse_line(r#"WRITE content="unterminated"#).unwrap_err(),
            ParseError::UnterminatedQuote
        ));
    }
}
