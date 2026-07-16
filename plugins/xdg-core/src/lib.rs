//! Freedesktop XDG primitives with no Nushell dependency.
//!
//! This crate contains the reusable core of `nu_plugin_xdg`. Its parsers keep
//! recoverable [`diagnostic::Diagnostic`]s alongside their results, while typed
//! views handle validation and interpretation.
//!
//! [`keyfile`] reads the grammar shared by desktop entries and MIME association
//! files. [`desktop_entry`] and [`exec`] provide typed desktop entry behavior.
//! [`glob`], [`magic`], and [`mime`] cover MIME detection and handler lookup.
//! [`xdg_dirs`] resolves the XDG base directories.
//!
//! [`xdg_dirs::XdgDirs`] stores resolved paths independently of their source.
//! Use [`xdg_dirs::XdgDirs::from_env`] for process variables or
//! [`xdg_dirs::XdgDirs::from_values`] for values supplied by another runtime.

pub mod desktop_entry;
pub mod diagnostic;
pub mod exec;
pub mod glob;
pub mod keyfile;
pub mod magic;
pub mod mime;
pub mod xdg_dirs;

pub use diagnostic::{
   Diagnostic,
   Parsed,
   Severity,
};
pub use keyfile::{
   KeyFile,
   Locale,
};
pub use xdg_dirs::XdgDirs;
