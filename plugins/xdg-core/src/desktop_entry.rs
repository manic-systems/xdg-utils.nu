//! Typed and locale-aware Desktop Entry handling.
//!
//! See <https://specifications.freedesktop.org/desktop-entry-spec/desktop-entry-spec-latest.html>.
//!
//! [`crate::keyfile::parse`] reads the shared key-file grammar and keeps source
//! diagnostics. [`DesktopEntry::from_keyfile`] then resolves one [`Locale`],
//! decodes values, and builds a typed entry with its actions.
//!
//! The typed view intentionally omits other locales and extension keys. Use
//! [`KeyFile`] directly when those values are needed.

use std::path::{
   Path,
   PathBuf,
};

// Keep the existing public path after moving Locale into the key-file module.
pub use crate::keyfile::Locale;
use crate::{
   diagnostic::{
      Diagnostic,
      Parsed,
   },
   keyfile::{
      self,
      KeyFile,
      unescape_value,
   },
   xdg_dirs::XdgDirs,
};

/// Parse a Desktop Entry source into the shared key-file model.
#[must_use]
pub fn parse(source: &str) -> Parsed<KeyFile> {
   keyfile::parse(source)
}

/// Read and parse a Desktop Entry file from disk.
pub fn parse_path(path: &Path) -> std::io::Result<Parsed<KeyFile>> {
   keyfile::parse_path(path)
}

/// Resolve a Desktop Entry name (`firefox` or `firefox.desktop`) to its
/// installed path.
///
/// Searches `applications/` and the legacy `applnk/` tree in each data
/// directory, including the `vendor/app.desktop` fallback.
#[must_use]
pub fn find_desktop_file(dirs: &XdgDirs, name: &str) -> Option<PathBuf> {
   let basename = if name.ends_with(".desktop") {
      name.to_owned()
   } else {
      format!("{name}.desktop")
   };
   for dir in dirs.data_dirs() {
      for sub in ["applications", "applnk"] {
         let direct = dir.join(sub).join(&basename);
         if direct.is_file() {
            return Some(direct);
         }
         if let Some((vendor, rest)) = basename.split_once('-') {
            let nested = dir.join(sub).join(vendor).join(rest);
            if nested.is_file() {
               return Some(nested);
            }
         }
      }
   }
   None
}

/// The `Type=` of a Desktop Entry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EntryType {
   Application,
   Link,
   Directory,
   Other(String),
}

impl EntryType {
   #[must_use]
   pub fn parse(s: &str) -> Self {
      match s {
         "Application" => Self::Application,
         "Link" => Self::Link,
         "Directory" => Self::Directory,
         other => Self::Other(other.to_owned()),
      }
   }

   #[must_use]
   pub fn as_str(&self) -> &str {
      match self {
         Self::Application => "Application",
         Self::Link => "Link",
         Self::Directory => "Directory",
         Self::Other(s) => s,
      }
   }
}

/// A `[Desktop Action <id>]` group.
#[derive(Debug, Clone)]
pub struct DesktopAction {
   pub id:   String,
   pub name: Option<String>,
   pub icon: Option<String>,
   pub exec: Option<String>,
}

/// A high-level, locale-resolved view of a Desktop Entry's main group.
#[derive(Debug, Clone)]
pub struct DesktopEntry {
   pub entry_type:       EntryType,
   pub name:             Option<String>,
   pub generic_name:     Option<String>,
   pub comment:          Option<String>,
   pub icon:             Option<String>,
   pub exec:             Option<String>,
   pub try_exec:         Option<String>,
   pub path:             Option<String>,
   pub url:              Option<String>,
   pub terminal:         bool,
   pub no_display:       bool,
   pub hidden:           bool,
   pub startup_notify:   bool,
   pub dbus_activatable: bool,
   pub mime_types:       Vec<String>,
   pub categories:       Vec<String>,
   pub keywords:         Vec<String>,
   pub only_show_in:     Vec<String>,
   pub not_show_in:      Vec<String>,
   pub actions:          Vec<DesktopAction>,
}

impl DesktopEntry {
   /// Build the typed view from a parsed key-file and a locale, discarding
   /// validation diagnostics. Returns [`None`] when the file has no
   /// `[Desktop Entry]` group.
   pub fn from_keyfile(file: &KeyFile, locale: &Locale) -> Option<Self> {
      Self::from_keyfile_diagnosed(file, locale).map(Parsed::into_value)
   }

   /// Build the typed view and report invalid booleans, missing types, and
   /// action identifiers with no matching group.
   pub fn from_keyfile_diagnosed(file: &KeyFile, locale: &Locale) -> Option<Parsed<Self>> {
      let main = file.group("Desktop Entry")?;
      let mut diagnostics = Vec::new();

      let mut boolean = |key: &str| -> bool {
         match main.boolean(key) {
            Ok(v) => v.unwrap_or(false),
            Err(bad) => {
               diagnostics.push(Diagnostic::warning(format!(
                  "{key}={bad:?} is not a boolean; treated as false"
               )));
               false
            },
         }
      };

      let terminal = boolean("Terminal");
      let no_display = boolean("NoDisplay");
      let hidden = boolean("Hidden");
      let startup_notify = boolean("StartupNotify");
      let dbus_activatable = boolean("DBusActivatable");

      let entry_type = match main.get("Type") {
         Some(t) if !t.is_empty() => EntryType::parse(t),
         Some(_) => {
            diagnostics.push(Diagnostic::warning("empty Type= key"));
            EntryType::Other(String::new())
         },
         None => {
            diagnostics.push(Diagnostic::error("missing required Type= key"));
            EntryType::Other(String::new())
         },
      };

      let actions = main
         .list("Actions")
         .into_iter()
         .filter_map(|id| {
            let Some(sect) = file.group(&format!("Desktop Action {id}")) else {
               diagnostics.push(Diagnostic::warning(format!(
                  "Actions lists '{id}' but [Desktop Action {id}] is missing"
               )));
               return None;
            };
            Some(DesktopAction {
               id,
               name: sect.localized_string("Name", locale),
               icon: sect.localized_string("Icon", locale),
               exec: sect.get("Exec").map(unescape_value),
            })
         })
         .collect();

      let entry = Self {
         entry_type,
         name: main.localized_string("Name", locale),
         generic_name: main.localized_string("GenericName", locale),
         comment: main.localized_string("Comment", locale),
         icon: main.localized_string("Icon", locale),
         exec: main.get("Exec").map(unescape_value),
         try_exec: main.get("TryExec").map(std::borrow::ToOwned::to_owned),
         path: main.get("Path").map(unescape_value),
         url: main.get("URL").map(unescape_value),
         terminal,
         no_display,
         hidden,
         startup_notify,
         dbus_activatable,
         mime_types: main.list("MimeType"),
         categories: main.list("Categories"),
         keywords: main.list("Keywords"),
         only_show_in: main.list("OnlyShowIn"),
         not_show_in: main.list("NotShowIn"),
         actions,
      };
      Some(Parsed {
         value: entry,
         diagnostics,
      })
   }

   /// Compatibility alias for [`DesktopEntry::from_keyfile`].
   #[must_use]
   pub fn from_file(file: &KeyFile, locale: &Locale) -> Option<Self> {
      Self::from_keyfile(file, locale)
   }

   /// Whether this entry should be shown for the lowercased desktop names in
   /// `current`. Applies `Hidden`, `NoDisplay`, `OnlyShowIn`, and `NotShowIn`.
   #[must_use]
   pub fn should_show_in(&self, current: &[String]) -> bool {
      if self.hidden || self.no_display {
         return false;
      }
      let matches = |list: &[String]| {
         list
            .iter()
            .any(|env| current.iter().any(|c| c == &env.to_ascii_lowercase()))
      };
      if !self.only_show_in.is_empty() {
         return matches(&self.only_show_in);
      }
      if !self.not_show_in.is_empty() {
         return !matches(&self.not_show_in);
      }
      true
   }

   /// Resolve `TryExec` against the given PATH directories. A missing value is
   /// accepted as required by the specification.
   #[must_use]
   pub fn try_exec_ok(&self, path_dirs: &[PathBuf]) -> bool {
      let Some(prog) = &self.try_exec else {
         return true;
      };
      let p = Path::new(prog);
      if p.is_absolute() {
         return p.is_file();
      }
      path_dirs.iter().any(|d| d.join(prog).is_file())
   }
}

#[cfg(test)]
mod tests {
   use super::*;

   const SAMPLE: &str = "\
[Desktop Entry]
Type=Application
Name=Text Editor
Name[de]=Texteditor
Comment=Edit text
Exec=editor %F
Terminal=false
Categories=Utility;TextEditor;
Actions=new-window;
MimeType=text/plain;

[Desktop Action new-window]
Name=New Window
Exec=editor --new-window
";

   #[test]
   fn typed_view_resolves_locale_and_types() {
      let kf = parse(SAMPLE).value;
      let de = DesktopEntry::from_keyfile(&kf, &Locale::parse("de")).unwrap();
      assert_eq!(de.entry_type, EntryType::Application);
      assert_eq!(de.name.as_deref(), Some("Texteditor"));
      assert_eq!(de.comment.as_deref(), Some("Edit text"));
      assert!(!de.terminal);
      assert_eq!(de.categories, vec!["Utility", "TextEditor"]);
      assert_eq!(de.mime_types, vec!["text/plain"]);
      assert_eq!(de.actions.len(), 1);
      assert_eq!(de.actions[0].id, "new-window");
      assert_eq!(de.actions[0].name.as_deref(), Some("New Window"));
   }

   #[test]
   fn diagnoses_bad_bool_missing_type_and_dangling_action() {
      let src = "\
[Desktop Entry]
Terminal=maybe
Actions=ghost;
";
      let kf = parse(src).value;
      let parsed = DesktopEntry::from_keyfile_diagnosed(&kf, &Locale::default()).unwrap();
      assert!(!parsed.value.terminal); // bad bool defaults to false
      let joined = parsed
         .diagnostics
         .iter()
         .map(|d| d.message.clone())
         .collect::<Vec<_>>()
         .join("\n");
      assert!(joined.contains("Terminal"), "{joined}");
      assert!(joined.contains("missing required Type"), "{joined}");
      assert!(joined.contains("ghost"), "{joined}");
   }

   #[test]
   fn no_main_group_is_none() {
      let kf = parse("[Other]\nKey=val\n").value;
      assert!(DesktopEntry::from_keyfile(&kf, &Locale::default()).is_none());
   }
}
