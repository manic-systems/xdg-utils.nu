//! XDG Base Directory resolution.
//!
//! [`XdgDirs`] stores resolved directories independently of where their values
//! came from. Use [`XdgDirs::from_env`] for process variables and
//! [`XdgDirs::from_values`] for values supplied by another runtime.
//!
//! See <https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html>.

use std::path::{
   Path,
   PathBuf,
};

use crate::diagnostic::{
   Diagnostic,
   Parsed,
};

/// Raw, unresolved environment values for the XDG base directories. Any field
/// left [`None`] falls back to the spec default in [`XdgDirs::from_values`].
#[derive(Debug, Clone, Default)]
pub struct XdgEnv {
   pub home:            Option<PathBuf>,
   pub data_home:       Option<PathBuf>,
   pub config_home:     Option<PathBuf>,
   pub state_home:      Option<PathBuf>,
   pub cache_home:      Option<PathBuf>,
   pub runtime_dir:     Option<PathBuf>,
   pub data_dirs:       Option<Vec<PathBuf>>,
   pub config_dirs:     Option<Vec<PathBuf>>,
   pub current_desktop: Vec<String>,
   pub menu_prefix:     Vec<String>,
   pub exec_path:       Option<Vec<PathBuf>>,
}

/// Resolved XDG base directories.
#[derive(Debug, Clone)]
pub struct XdgDirs {
   data_home:           PathBuf,
   config_home:         PathBuf,
   state_home:          PathBuf,
   cache_home:          PathBuf,
   /// `$XDG_RUNTIME_DIR` has no default and remains empty when unset.
   runtime_dir:         Option<PathBuf>,
   data_dirs_extra:     Vec<PathBuf>,
   config_dirs_extra:   Vec<PathBuf>,
   /// Lowercased entries of `$XDG_CURRENT_DESKTOP`, in order.
   pub current_desktop: Vec<String>,
   /// Entries of `$XDG_MENU_PREFIX` (e.g. `gnome-`), for the legacy
   /// `<prefix>defaults.list` / `<prefix>mimeinfo.cache` lookups.
   pub menu_prefix:     Vec<String>,
   /// Directories of `$PATH`, for resolving `Exec=` binaries. Empty when the
   /// caller could not provide one.
   exec_path:           Vec<PathBuf>,
}

impl XdgDirs {
   /// Build from raw values with specification defaults, discarding
   /// diagnostics. See [`XdgDirs::from_values_diagnosed`].
   #[must_use]
   pub fn from_values(env: XdgEnv) -> Self {
      Self::from_values_diagnosed(env).value
   }

   /// Build from raw values and apply specification defaults. `home` defaults
   /// to `/`. The `data_dirs` and `config_dirs` fields contain only extra
   /// directories and do not include the home entry.
   ///
   /// Relative single paths fall back to their defaults. Relative entries in
   /// directory lists are dropped. Each case produces a [`Diagnostic`].
   #[must_use]
   pub fn from_values_diagnosed(env: XdgEnv) -> Parsed<Self> {
      let mut diagnostics = Vec::new();
      let home = env.home.unwrap_or_else(|| PathBuf::from("/"));

      let mut single = |value: Option<PathBuf>, var: &str| -> Option<PathBuf> {
         match value {
            Some(p) if !p.is_absolute() => {
               diagnostics.push(Diagnostic::warning(format!(
                  "${var} is not an absolute path ({}); using the default",
                  p.display()
               )));
               None
            },
            other => other,
         }
      };

      let data_home = single(env.data_home, "XDG_DATA_HOME")
         .unwrap_or_else(|| home.join(".local").join("share"));
      let config_home =
         single(env.config_home, "XDG_CONFIG_HOME").unwrap_or_else(|| home.join(".config"));
      let state_home = single(env.state_home, "XDG_STATE_HOME")
         .unwrap_or_else(|| home.join(".local").join("state"));
      let cache_home =
         single(env.cache_home, "XDG_CACHE_HOME").unwrap_or_else(|| home.join(".cache"));
      let runtime_dir = single(env.runtime_dir, "XDG_RUNTIME_DIR");

      let mut list = |value: Option<Vec<PathBuf>>, var: &str, default: Vec<PathBuf>| {
         match value {
            Some(dirs) => {
               dirs
                  .into_iter()
                  .filter(|p| {
                     if p.is_absolute() {
                        true
                     } else {
                        diagnostics.push(Diagnostic::warning(format!(
                           "${var} entry is not absolute ({}); ignored",
                           p.display()
                        )));
                        false
                     }
                  })
                  .collect()
            },
            None => default,
         }
      };

      let data_dirs_extra = list(env.data_dirs, "XDG_DATA_DIRS", vec![
         PathBuf::from("/usr/local/share"),
         PathBuf::from("/usr/share"),
      ]);
      let config_dirs_extra = list(env.config_dirs, "XDG_CONFIG_DIRS", vec![PathBuf::from(
         "/etc/xdg",
      )]);

      Parsed {
         value: Self {
            data_home,
            config_home,
            state_home,
            cache_home,
            runtime_dir,
            data_dirs_extra,
            config_dirs_extra,
            current_desktop: env.current_desktop,
            menu_prefix: env.menu_prefix,
            exec_path: env.exec_path.unwrap_or_default(),
         },
         diagnostics,
      }
   }

   /// Resolve from the process environment.
   pub fn from_env() -> Self {
      let var =
         |name: &str| -> Option<String> { std::env::var(name).ok().filter(|s| !s.is_empty()) };
      Self::from_values(XdgEnv {
         home:            var("HOME").map(PathBuf::from),
         data_home:       var("XDG_DATA_HOME").map(PathBuf::from),
         config_home:     var("XDG_CONFIG_HOME").map(PathBuf::from),
         state_home:      var("XDG_STATE_HOME").map(PathBuf::from),
         cache_home:      var("XDG_CACHE_HOME").map(PathBuf::from),
         runtime_dir:     var("XDG_RUNTIME_DIR").map(PathBuf::from),
         data_dirs:       var("XDG_DATA_DIRS").map(|s| split_paths(&s)),
         config_dirs:     var("XDG_CONFIG_DIRS").map(|s| split_paths(&s)),
         current_desktop: var("XDG_CURRENT_DESKTOP")
            .unwrap_or_default()
            .split(':')
            .filter(|s| !s.is_empty())
            .map(str::to_ascii_lowercase)
            .collect(),
         menu_prefix:     var("XDG_MENU_PREFIX")
            .unwrap_or_default()
            .split(':')
            .filter(|s| !s.is_empty())
            .map(std::borrow::ToOwned::to_owned)
            .collect(),
         exec_path:       var("PATH").map(|s| split_paths(&s)),
      })
   }

   #[must_use]
   pub const fn data_home(&self) -> &PathBuf {
      &self.data_home
   }

   #[must_use]
   pub const fn config_home(&self) -> &PathBuf {
      &self.config_home
   }

   #[must_use]
   pub const fn state_home(&self) -> &PathBuf {
      &self.state_home
   }

   #[must_use]
   pub const fn cache_home(&self) -> &PathBuf {
      &self.cache_home
   }

   #[must_use]
   pub const fn runtime_dir(&self) -> Option<&PathBuf> {
      self.runtime_dir.as_ref()
   }

   /// All XDG data dirs in lookup order.
   #[must_use]
   pub fn data_dirs(&self) -> Vec<&Path> {
      let mut out = vec![self.data_home.as_path()];
      out.extend(self.data_dirs_extra.iter().map(std::path::PathBuf::as_path));
      out
   }

   #[must_use]
   pub fn exec_path(&self) -> &[PathBuf] {
      &self.exec_path
   }

   /// All XDG config dirs in lookup order.
   #[must_use]
   pub fn config_dirs(&self) -> Vec<&Path> {
      let mut out = vec![self.config_home.as_path()];
      out.extend(
         self
            .config_dirs_extra
            .iter()
            .map(std::path::PathBuf::as_path),
      );
      out
   }
}

/// Split a PATH-style list and drop empty entries.
pub fn split_paths(raw: &str) -> Vec<PathBuf> {
   raw.split(':')
      .filter(|s| !s.is_empty())
      .map(PathBuf::from)
      .collect()
}

#[cfg(test)]
mod tests {
   use super::*;

   #[test]
   fn applies_home_defaults() {
      let dirs = XdgDirs::from_values(XdgEnv {
         home: Some(PathBuf::from("/home/u")),
         ..Default::default()
      });
      assert_eq!(dirs.data_home(), &PathBuf::from("/home/u/.local/share"));
      assert_eq!(dirs.config_home(), &PathBuf::from("/home/u/.config"));
      assert_eq!(dirs.data_dirs_extra, vec![
         PathBuf::from("/usr/local/share"),
         PathBuf::from("/usr/share"),
      ]);
   }

   #[test]
   fn drops_relative_dirs_entries_with_diagnostics() {
      let parsed = XdgDirs::from_values_diagnosed(XdgEnv {
         home: Some(PathBuf::from("/home/u")),
         data_dirs: Some(vec![
            PathBuf::from("/usr/share"),
            PathBuf::from("relative/dir"),
         ]),
         ..Default::default()
      });
      assert_eq!(parsed.value.data_dirs_extra, vec![PathBuf::from(
         "/usr/share"
      )]);
      assert!(
         parsed
            .diagnostics
            .iter()
            .any(|d| d.message.contains("XDG_DATA_DIRS") && d.message.contains("relative/dir"))
      );
   }

   #[test]
   fn relative_home_falls_back_to_default() {
      let parsed = XdgDirs::from_values_diagnosed(XdgEnv {
         home: Some(PathBuf::from("/home/u")),
         config_home: Some(PathBuf::from("relative")),
         ..Default::default()
      });
      assert_eq!(
         parsed.value.config_home(),
         &PathBuf::from("/home/u/.config")
      );
      assert!(
         parsed
            .diagnostics
            .iter()
            .any(|d| d.message.contains("XDG_CONFIG_HOME"))
      );
   }

   #[test]
   fn split_paths_drops_empty() {
      assert_eq!(split_paths("/a::/b:"), vec![
         PathBuf::from("/a"),
         PathBuf::from("/b")
      ]);
   }
}
