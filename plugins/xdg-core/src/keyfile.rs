//! Parser for the key-file grammar shared by freedesktop desktop formats.
//!
//! Both Desktop Entry files (`*.desktop`) and the MIME association files
//! (`mimeapps.list`, `mimeinfo.cache`) use the same INI-like syntax.
//!
//! ```text
//! [Group Name]
//! Key=value
//! Key[locale]=localized value
//! # comment
//! ```
//!
//! The parser keeps source line numbers and reports recoverable problems
//! through [`Parsed`]. It does not preserve comments, blank lines, or exact
//! spacing. Formatting-sensitive updates should edit the original text instead.

use std::{
   env,
   fs,
   io,
   path::Path,
};

use crate::diagnostic::{
   Diagnostic,
   Parsed,
};

/// One `Key=value` line, with its optional `[locale]` tag and 1-based source
/// line number preserved.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyEntry {
   pub key:    String,
   pub locale: Option<String>,
   pub value:  String,
   pub line:   usize,
}

/// A `[Group Name]` and the entries beneath it, in source order.
#[derive(Debug, Clone, Default)]
pub struct Group {
   pub name:    String,
   pub line:    usize,
   pub entries: Vec<KeyEntry>,
}

impl Group {
   /// The unlocalized value for `key` (first occurrence wins).
   #[must_use]
   pub fn get(&self, key: &str) -> Option<&str> {
      self
         .entries
         .iter()
         .find(|e| e.key == key && e.locale.is_none())
         .map(|e| e.value.as_str())
   }

   /// Every value recorded for `key`, regardless of locale, in source order.
   pub fn get_all<'a>(&'a self, key: &'a str) -> impl Iterator<Item = &'a KeyEntry> + 'a {
      self.entries.iter().filter(move |e| e.key == key)
   }

   /// Resolve a localizable key against `locale`, following the spec match
   /// order (`lang_COUNTRY@MODIFIER` → `lang_COUNTRY` → `lang@MODIFIER` →
   /// `lang`), then the unlocalized value.
   #[must_use]
   pub fn localized(&self, key: &str, locale: &Locale) -> Option<&str> {
      for cand in locale.candidates() {
         if let Some(e) = self
            .entries
            .iter()
            .find(|e| e.key == key && e.locale.as_deref() == Some(cand.as_str()))
         {
            return Some(&e.value);
         }
      }
      self.get(key)
   }

   /// [`Group::localized`] with the standard escapes decoded.
   pub fn localized_string(&self, key: &str, locale: &Locale) -> Option<String> {
      self.localized(key, locale).map(unescape_value)
   }

   /// Parse `key` as a case-insensitive Desktop Entry boolean. Invalid values
   /// are returned to the caller so they can be reported.
   pub fn boolean(&self, key: &str) -> Result<Option<bool>, &str> {
      match self.get(key) {
         None => Ok(None),
         Some(v) if v.eq_ignore_ascii_case("true") => Ok(Some(true)),
         Some(v) if v.eq_ignore_ascii_case("false") => Ok(Some(false)),
         Some(v) => Err(v),
      }
   }

   /// A list value such as `MimeType` or `Categories`.
   pub fn list(&self, key: &str) -> Vec<String> {
      self.get(key).map(split_list).unwrap_or_default()
   }
}

/// A parsed key-file with groups in source order.
#[derive(Debug, Clone, Default)]
pub struct KeyFile {
   pub groups: Vec<Group>,
}

impl KeyFile {
   #[must_use]
   pub fn group(&self, name: &str) -> Option<&Group> {
      self.groups.iter().find(|g| g.name == name)
   }
}

/// Parse key-file `source`, dropping malformed lines and reporting them as
/// [`Diagnostic`]s while keeping valid entries.
#[must_use]
pub fn parse(source: &str) -> Parsed<KeyFile> {
   let mut file = KeyFile::default();
   let mut diagnostics = Vec::new();
   let mut current = None::<Group>;

   for (idx, raw) in source.lines().enumerate() {
      let line_no = idx + 1;
      let line = raw.trim_end_matches('\r');
      let trimmed = line.trim_start();
      if trimmed.is_empty() || trimmed.starts_with('#') {
         continue;
      }

      // A group header has the form `[name]`.
      if let Some(after) = trimmed.strip_prefix('[') {
         match after.strip_suffix(']') {
            Some(name) => {
               if let Some(prev) = current.take() {
                  file.groups.push(prev);
               }
               if name.is_empty() {
                  diagnostics.push(Diagnostic::warning("empty group name").at_line(line_no));
               }
               current = Some(Group {
                  name:    name.to_owned(),
                  line:    line_no,
                  entries: Vec::new(),
               });
            },
            None => {
               diagnostics
                  .push(Diagnostic::error("group header missing closing ']'").at_line(line_no));
            },
         }
         continue;
      }

      let Some(group) = current.as_mut() else {
         diagnostics
            .push(Diagnostic::error("key=value line before any group header").at_line(line_no));
         continue;
      };

      let Some((lhs, value)) = trimmed.split_once('=') else {
         diagnostics.push(Diagnostic::error("line has no '=' separator").at_line(line_no));
         continue;
      };

      let lhs = lhs.trim_end();
      let (key, locale) = split_key_locale(lhs);
      if key.is_empty() {
         diagnostics.push(Diagnostic::error("empty key name").at_line(line_no));
         continue;
      }

      if group
         .entries
         .iter()
         .any(|e| e.key == key && e.locale.as_deref() == locale.as_deref())
      {
         diagnostics.push(
            Diagnostic::warning(format!("duplicate key '{key}'; first value kept"))
               .at_line(line_no),
         );
         continue;
      }

      group.entries.push(KeyEntry {
         key,
         locale,
         value: value.trim_start().to_owned(),
         line: line_no,
      });
   }

   if let Some(last) = current.take() {
      file.groups.push(last);
   }

   Parsed {
      value: file,
      diagnostics,
   }
}

/// Read and parse a key-file from disk.
pub fn parse_path(path: &Path) -> io::Result<Parsed<KeyFile>> {
   let source = fs::read_to_string(path)?;
   Ok(parse(&source))
}

/// Split a left-hand side into its key and optional `[locale]` suffix. A `[`
/// is only treated as a locale tag when the LHS also ends in `]`.
fn split_key_locale(lhs: &str) -> (String, Option<String>) {
   if lhs.ends_with(']')
      && let Some((key, rest)) = lhs.split_once('[')
      && let Some(locale) = rest.strip_suffix(']')
   {
      return (key.to_owned(), Some(locale.to_owned()));
   }
   (lhs.to_owned(), None)
}

/// Decode the Desktop Entry string escapes (`\s` space, `\n` newline, `\t`
/// tab, `\r` carriage return, `\\` backslash).
///
/// Unknown escapes keep both characters, matching `GLib` behavior and avoiding
/// silent data loss.
#[must_use]
pub fn unescape_value(value: &str) -> String {
   let mut out = String::with_capacity(value.len());
   let mut chars = value.chars();
   while let Some(c) = chars.next() {
      if c != '\\' {
         out.push(c);
         continue;
      }
      match chars.next() {
         Some('s') => out.push(' '),
         Some('n') => out.push('\n'),
         Some('t') => out.push('\t'),
         Some('r') => out.push('\r'),
         Some('\\') | None => out.push('\\'),
         Some(other) => {
            out.push('\\');
            out.push(other);
         },
      }
   }
   out
}

/// Split a list value and drop the empty segment produced by a trailing marker.
#[must_use]
pub fn split_list(value: &str) -> Vec<String> {
   value
      .split(';')
      .filter(|s| !s.is_empty())
      .map(std::borrow::ToOwned::to_owned)
      .collect()
}

/// A POSIX locale from `$LC_MESSAGES` or `$LANG`.
///
/// The encoding in `lang[_COUNTRY][.ENCODING][@MODIFIER]` is ignored for key
/// matching.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Locale {
   pub lang:     String,
   pub country:  Option<String>,
   pub modifier: Option<String>,
}

impl Locale {
   /// Parse a locale string. An empty / `C` / `POSIX` locale yields an empty
   /// lang, meaning "unlocalized values only".
   #[must_use]
   pub fn parse(s: &str) -> Self {
      let s = s.trim();
      if s.is_empty() || s == "C" || s == "POSIX" {
         return Self::default();
      }
      // The modifier comes last in the grammar, so split it first.
      let (rest, modifier) = match s.split_once('@') {
         Some((head, m)) => (head, Some(m.to_owned())),
         None => (s, None),
      };
      // Then strip any `.ENCODING`.
      let rest = rest.split('.').next().unwrap_or(rest);
      let (lang, country) = match rest.split_once('_') {
         Some((l, c)) => (l.to_owned(), Some(c.to_owned())),
         None => (rest.to_owned(), None),
      };
      Self {
         lang,
         country,
         modifier,
      }
   }

   /// Read the effective locale from `$LC_ALL`, `$LC_MESSAGES`, then `$LANG`.
   #[must_use]
   pub fn from_env() -> Self {
      for var in ["LC_ALL", "LC_MESSAGES", "LANG"] {
         if let Ok(val) = env::var(var)
            && !val.is_empty()
         {
            return Self::parse(&val);
         }
      }
      Self::default()
   }

   /// The localized-key suffixes to try, most specific first.
   #[must_use]
   pub fn candidates(&self) -> Vec<String> {
      if self.lang.is_empty() {
         return Vec::new();
      }
      let mut out = Vec::new();
      if let (Some(c), Some(m)) = (&self.country, &self.modifier) {
         out.push(format!("{}_{c}@{m}", self.lang));
      }
      if let Some(c) = &self.country {
         out.push(format!("{}_{c}", self.lang));
      }
      if let Some(m) = &self.modifier {
         out.push(format!("{}@{m}", self.lang));
      }
      out.push(self.lang.clone());
      out
   }
}

#[cfg(test)]
mod tests {
   use super::*;
   use crate::diagnostic::Severity;

   #[test]
   fn parses_groups_and_locale_tags() {
      let src = "\
# a comment

[Desktop Entry]
Name=Files
Name[de]=Dateien
Name[en_US]=Files
Exec=foo %u
";
      let parsed = parse(src);
      assert!(!parsed.has_diagnostics(), "{:?}", parsed.diagnostics);
      let g = parsed.value.group("Desktop Entry").unwrap();
      assert_eq!(g.get("Name"), Some("Files"));
      assert_eq!(g.localized("Name", &Locale::parse("de")), Some("Dateien"));
      assert_eq!(
         g.localized("Name", &Locale::parse("en_US.UTF-8")),
         Some("Files")
      );
      // line numbers are preserved (1-based)
      assert_eq!(g.line, 3);
      assert_eq!(g.entries[0].line, 4);
   }

   #[test]
   fn diagnoses_malformed_lines() {
      let src = "\
orphan=value
[Group]
[Unterminated
=novalue
Key=ok
Key=dup
";
      let parsed = parse(src);
      let msgs = parsed
         .diagnostics
         .iter()
         .map(|d| (d.severity, d.line, d.message.clone()))
         .collect::<Vec<_>>();
      assert!(
         msgs
            .iter()
            .any(|(s, l, _)| *s == Severity::Error && *l == Some(1))
      );
      assert!(
         msgs
            .iter()
            .any(|(s, l, m)| *s == Severity::Error && *l == Some(3) && m.contains("closing"))
      );
      assert!(
         msgs
            .iter()
            .any(|(s, l, _)| *s == Severity::Error && *l == Some(4))
      );
      assert!(
         msgs
            .iter()
            .any(|(s, _, m)| *s == Severity::Warning && m.contains("duplicate"))
      );
      // The first valid key wins over the duplicate.
      assert_eq!(parsed.value.group("Group").unwrap().get("Key"), Some("ok"));
   }

   #[test]
   fn indented_key_line_parses_without_leading_whitespace() {
      let g = parse("[G]\n  Exec=firefox %u\n").value.groups.remove(0);
      assert_eq!(g.get("Exec"), Some("firefox %u"));
   }

   #[test]
   fn boolean_distinguishes_invalid_from_absent() {
      let g = parse("[G]\nA=true\nB=False\nC=yes\n")
         .value
         .groups
         .remove(0);
      assert_eq!(g.boolean("A"), Ok(Some(true)));
      assert_eq!(g.boolean("B"), Ok(Some(false)));
      assert_eq!(g.boolean("C"), Err("yes"));
      assert_eq!(g.boolean("missing"), Ok(None));
   }

   #[test]
   fn unescape_keeps_unknown_escapes() {
      assert_eq!(unescape_value(r"a\sb\nc"), "a b\nc");
      assert_eq!(unescape_value(r"C:\\path"), r"C:\path");
      // Unknown escapes preserve the backslash.
      assert_eq!(unescape_value(r"a\xb"), r"a\xb");
      assert_eq!(unescape_value(r"trailing\"), r"trailing\");
   }

   #[test]
   fn split_list_drops_trailing_empty() {
      assert_eq!(split_list("a;b;c;"), vec!["a", "b", "c"]);
      assert_eq!(split_list("a;;b"), vec!["a", "b"]);
      assert_eq!(split_list(""), Vec::<String>::new());
   }

   #[test]
   fn locale_candidate_order() {
      let l = Locale::parse("sr_RS.UTF-8@latin");
      assert_eq!(l.lang, "sr");
      assert_eq!(l.country.as_deref(), Some("RS"));
      assert_eq!(l.modifier.as_deref(), Some("latin"));
      assert_eq!(l.candidates(), vec![
         "sr_RS@latin".to_owned(),
         "sr_RS".to_owned(),
         "sr@latin".to_owned(),
         "sr".to_owned(),
      ]);
      assert!(Locale::parse("C").candidates().is_empty());
   }
}
