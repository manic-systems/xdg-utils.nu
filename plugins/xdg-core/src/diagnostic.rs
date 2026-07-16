//! Recoverable parse diagnostics.
//!
//! Malformed entries do not prevent the rest of an XDG file from loading.
//! Parsers return the usable value with [`Diagnostic`]s for input they dropped
//! or interpreted cautiously. Callers can surface those details when useful.

use std::fmt;

/// How serious a diagnostic is. Parsing still recovers from an `Error`, which
/// marks input the parser could not honor rather than a failed parse.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Severity {
   /// Input that was dropped or could not be interpreted (e.g. a key=value
   /// line outside any group, a magic rule with a bad length field).
   Error,
   /// Input that was accepted but is suspect (e.g. a duplicate key, an
   /// unknown boolean spelling treated as its default).
   Warning,
}

impl fmt::Display for Severity {
   fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
      match self {
         Self::Error => f.write_str("error"),
         Self::Warning => f.write_str("warning"),
      }
   }
}

/// A problem noticed during parsing. Text formats use a one-based `line`, while
/// binary formats report an offset in the message and leave `line` empty.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Diagnostic {
   pub severity: Severity,
   pub message:  String,
   pub line:     Option<usize>,
}

impl Diagnostic {
   pub fn error(message: impl Into<String>) -> Self {
      Self {
         severity: Severity::Error,
         message:  message.into(),
         line:     None,
      }
   }

   pub fn warning(message: impl Into<String>) -> Self {
      Self {
         severity: Severity::Warning,
         message:  message.into(),
         line:     None,
      }
   }

   /// Attach a 1-based source line.
   #[must_use]
   pub const fn at_line(mut self, line: usize) -> Self {
      self.line = Some(line);
      self
   }
}

impl fmt::Display for Diagnostic {
   fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
      match self.line {
         Some(line) => write!(f, "{}: line {line}: {}", self.severity, self.message),
         None => write!(f, "{}: {}", self.severity, self.message),
      }
   }
}

/// A parsed value paired with whatever the parser flagged along the way.
#[derive(Debug, Clone, Default)]
pub struct Parsed<T> {
   pub value:       T,
   pub diagnostics: Vec<Diagnostic>,
}

impl<T> Parsed<T> {
   /// Wrap a value with no diagnostics.
   pub const fn clean(value: T) -> Self {
      Self {
         value,
         diagnostics: Vec::new(),
      }
   }

   /// Discard diagnostics, keeping only the value.
   pub fn into_value(self) -> T {
      self.value
   }

   /// Whether any diagnostic was recorded.
   pub const fn has_diagnostics(&self) -> bool {
      !self.diagnostics.is_empty()
   }

   /// Map the value, preserving diagnostics.
   pub fn map<U>(self, f: impl FnOnce(T) -> U) -> Parsed<U> {
      Parsed {
         value:       f(self.value),
         diagnostics: self.diagnostics,
      }
   }
}
