// Path expectations shared by the bash and zsh recording tests.
//
// A recording names each source file in the form a native reader can open,
// and copies it below `files/` where the readers look it up.  The helpers
// compute both from a fixture's path independently of the recorder and the
// writer, so a test compares the recording against what a reader needs
// rather than against what the recorder happens to produce.
#![allow(dead_code)]

use std::path::{Component, Path, PathBuf};

/// The form a recording names `path` in on this host.
///
/// On Linux and macOS it is the path itself: the launchers keep the logical
/// path the shell resolved, symlinks included.
///
/// On Windows the shell is an MSYS2 or Cygwin one, and the launchers convert
/// its paths with `cygpath -m -l`: drive letter, forward slashes, long names
/// (`C:/Users/runner/x.sh`).  `canonicalize` yields the long names; it also
/// prefixes the verbatim marker `\\?\`, which is dropped.
/// <https://cygwin.com/cygwin-ug-net/cygpath.html>
pub fn recorded_form(path: &Path) -> String {
    if cfg!(windows) {
        let canonical = std::fs::canonicalize(path)
            .unwrap_or_else(|e| panic!("cannot canonicalize {}: {e}", path.display()));
        let canonical = canonical.to_str().expect("fixture path must be UTF-8");
        canonical
            .strip_prefix(r"\\?\")
            .unwrap_or(canonical)
            .replace('\\', "/")
    } else {
        path.to_str()
            .expect("fixture path must be UTF-8")
            .to_string()
    }
}

/// Where a recording in `output_dir` must hold its copy of the source file
/// at `path`: below `files/`, at the recorded path with its root and, on
/// Windows, its drive dropped (`C:/a/b.sh` -> `files/a/b.sh`), which is how
/// the trace readers look the copy up.
pub fn files_copy_path(output_dir: &Path, path: &Path) -> PathBuf {
    let recorded = recorded_form(path);
    let mut copy = output_dir.join("files");
    for component in Path::new(&recorded).components() {
        match component {
            Component::Prefix(_) | Component::RootDir => {}
            other => copy.push(other.as_os_str()),
        }
    }
    copy
}
