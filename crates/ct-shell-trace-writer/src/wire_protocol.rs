// Wire protocol parser for shell debugger (bashdb/zshdb) trace events.
//
// This module will be responsible for:
// - Reading newline-delimited JSON messages from stdin
// - Parsing trace events (step, variable snapshot, source mapping, etc.)
// - Converting them into codetracer_trace_types structures
//
// Implementation starts in M1.
