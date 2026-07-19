//! MIME-type detection and `mimeapps.list` association handling.
//!
//! Detection follows shared-mime-info. Associations follow the mime-apps spec
//! <https://specifications.freedesktop.org/mime-apps-spec/mime-apps-spec-latest.html>.
//!
//! [`MimeStore`] loads globs, magic rules, aliases, and subclasses once for
//! repeated queries. The free functions build a temporary store for convenient
//! one-shot lookups.

use std::{
   collections::{
      HashMap,
      HashSet,
   },
   io,
   path::{
      Path,
      PathBuf,
   },
   sync::atomic::{
      AtomicU64,
      Ordering,
   },
   time::{
      SystemTime,
      UNIX_EPOCH,
   },
};

use crate::{
   diagnostic::Diagnostic,
   glob::Glob,
   keyfile,
   magic::MagicDb,
   xdg_dirs::XdgDirs,
};

/// How many bytes of a file to read for magic sniffing when the database
/// reports no bounded extent, and the hard ceiling regardless.
const TEXT_SCAN_BYTES: usize = 4096;
const MAGIC_READ_CAP: usize = 256 * 1024;

/// The shared-mime-info database, parsed once for reuse across queries.
pub struct MimeStore<'a> {
   dirs:            &'a XdgDirs,
   globs:           Vec<Glob>,
   magic:           MagicDb,
   aliases:         HashMap<String, String>,
   subclasses:      HashMap<String, Vec<String>>,
   pub diagnostics: Vec<Diagnostic>,
}

impl<'a> MimeStore<'a> {
   /// Load and merge shared-mime-info data from every data directory. Earlier
   /// directories take priority for aliases and subclasses, while glob and
   /// magic entries are ranked during lookup.
   pub fn load(dirs: &'a XdgDirs) -> Self {
      let mut globs = Vec::new();
      let mut magic = MagicDb::default();
      let mut aliases = HashMap::<String, String>::new();
      let mut subclasses = HashMap::<String, Vec<String>>::new();
      let mut diagnostics = Vec::new();

      for dir in dirs.data_dirs() {
         let mime_dir = dir.join("mime");

         if let Ok(contents) = std::fs::read_to_string(mime_dir.join("globs2")) {
            globs.extend(contents.lines().filter_map(Glob::parse_line));
         }
         if let Ok(bytes) = std::fs::read(mime_dir.join("magic")) {
            let parsed = MagicDb::parse(&bytes);
            magic.merge(parsed.value);
            diagnostics.extend(parsed.diagnostics);
         }
         if let Ok(contents) = std::fs::read_to_string(mime_dir.join("aliases")) {
            for line in contents.lines() {
               if let Some((alias, canonical)) = line.split_once(' ') {
                  aliases
                     .entry(alias.trim().to_owned())
                     .or_insert_with(|| canonical.trim().to_owned());
               }
            }
         }
         if let Ok(contents) = std::fs::read_to_string(mime_dir.join("subclasses")) {
            for line in contents.lines() {
               if let Some((child, parent)) = line.split_once(' ') {
                  subclasses
                     .entry(child.trim().to_owned())
                     .or_default()
                     .push(parent.trim().to_owned());
               }
            }
         }
      }

      MimeStore {
         dirs,
         globs,
         magic,
         aliases,
         subclasses,
         diagnostics,
      }
   }

   /// Resolve a type through the alias table to its canonical name.
   #[must_use]
   pub fn resolve_alias(&self, mime: &str) -> String {
      self
         .aliases
         .get(mime)
         .cloned()
         .unwrap_or_else(|| mime.to_owned())
   }

   /// The direct parent types of `mime`, including the required `text/plain`
   /// parent for every other `text/*` type. The implicit octet-stream root is
   /// omitted so unrelated types do not inherit its handler.
   fn direct_parents(&self, mime: &str) -> Vec<String> {
      let mut out = self.subclasses.get(mime).cloned().unwrap_or_default();
      if mime.starts_with("text/") && mime != "text/plain" && !out.iter().any(|p| p == "text/plain")
      {
         out.push("text/plain".to_owned());
      }
      out
   }

   /// The full ancestor chain of `mime` (breadth-first, de-duplicated,
   /// excluding `mime` itself).
   #[must_use]
   pub fn parents(&self, mime: &str) -> Vec<String> {
      let mut seen = HashSet::<String>::from([mime.to_owned()]);
      let mut queue = std::collections::VecDeque::from([mime.to_owned()]);
      let mut out = Vec::new();
      while let Some(cur) = queue.pop_front() {
         for p in self.direct_parents(&cur) {
            if seen.insert(p.clone()) {
               queue.push_back(p.clone());
               out.push(p);
            }
         }
      }
      out
   }

   /// All glob matches for `filename`, ordered by preference and deduplicated.
   fn glob_candidates(&self, filename: &str) -> Vec<(String, u32)> {
      crate::glob::best_matches(&self.globs, filename)
   }

   /// Detect by filename only (no content read). Alias-resolved.
   #[must_use]
   pub fn detect_by_glob(&self, filename: &str) -> Option<String> {
      self
         .glob_candidates(filename)
         .into_iter()
         .next()
         .map(|(m, _)| self.resolve_alias(&m))
   }

   /// Detect a file MIME type from its name and content, then resolve aliases.
   /// Returns [`None`] instead of guessing a generic type when neither source
   /// identifies the file.
   #[must_use]
   pub fn detect(&self, path: &Path) -> Option<String> {
      let name = path.to_string_lossy();
      let globs = self.glob_candidates(&name);

      // Opening a FIFO or another special file may block forever.
      let data = if path.metadata().is_ok_and(|m| m.is_file()) {
         let cap = self
            .magic
            .max_extent()
            .clamp(TEXT_SCAN_BYTES, MAGIC_READ_CAP);
         read_prefix(path, cap)
      } else {
         None
      };
      let magic = data.as_ref().and_then(|d| self.magic.match_data(d));

      resolve(&globs, magic.as_ref()).map(|m| self.resolve_alias(&m))
   }

   /// Resolve the default `.desktop` for `mimetype`, walking the type's
   /// subclass parents if the exact type has no installed default. Consults
   /// the `mimeapps.list` chain first, then the pre-mimeapps `defaults.list`
   /// upstream xdg-mime still honors.
   #[must_use]
   pub fn query_default(&self, mimetype: &str) -> Option<String> {
      let files = self.mimeapps_files();
      let mut types = vec![mimetype.to_owned()];
      types.extend(self.parents(mimetype));
      for ty in &types {
         // Removed associations also hide candidates from lower-priority files.
         let mut removed = Vec::<String>::new();
         for kf in &files {
            removed.extend(list_values(kf, "Removed Associations", ty));
            for cand in list_values(kf, "Default Applications", ty) {
               if !removed.contains(&cand) && self.desktop_is_usable(&cand) {
                  return Some(cand);
               }
            }
         }
         if let Some(cand) = self.legacy_default(ty, &removed) {
            return Some(cand);
         }
      }
      None
   }

   /// The legacy `applications/<prefix>defaults.list` lookup (prefixes from
   /// `$XDG_MENU_PREFIX`), still shipped by some distros.
   fn legacy_default(&self, mimetype: &str, removed: &[String]) -> Option<String> {
      for dir in self.dirs.data_dirs() {
         for prefix in self.menu_prefixes() {
            let path = dir
               .join("applications")
               .join(format!("{prefix}defaults.list"));
            let Ok(contents) = std::fs::read_to_string(&path) else {
               continue;
            };
            let kf = keyfile::parse(&contents).value;
            for cand in list_values(&kf, "Default Applications", mimetype) {
               if !removed.contains(&cand) && self.desktop_is_usable(&cand) {
                  return Some(cand);
               }
            }
         }
      }
      None
   }

   /// `$XDG_MENU_PREFIX` prefixes to try, ending with the unprefixed name.
   fn menu_prefixes(&self) -> Vec<&str> {
      let mut out = self
         .dirs
         .menu_prefix
         .iter()
         .map(String::as_str)
         .collect::<Vec<&str>>();
      out.push("");
      out
   }

   /// Every installed handler ordered by defaults, added associations, and the
   /// MIME cache, excluding removed and duplicate entries.
   #[must_use]
   pub fn list_handlers(&self, mimetype: &str) -> Vec<String> {
      let mut out = Vec::<String>::new();
      let mut removed = Vec::<String>::new();

      let push = |cand: String, removed: &[String], out: &mut Vec<String>| {
         if !removed.contains(&cand) && !out.contains(&cand) && self.desktop_is_usable(&cand) {
            out.push(cand);
         }
      };

      for kf in self.mimeapps_files() {
         removed.extend(list_values(&kf, "Removed Associations", mimetype));
         for cand in list_values(&kf, "Default Applications", mimetype) {
            push(cand, &removed, &mut out);
         }
         for cand in list_values(&kf, "Added Associations", mimetype) {
            push(cand, &removed, &mut out);
         }
      }
      for dir in self.dirs.data_dirs() {
         for prefix in self.menu_prefixes() {
            let cache = dir
               .join("applications")
               .join(format!("{prefix}mimeinfo.cache"));
            if let Ok(contents) = std::fs::read_to_string(&cache) {
               let kf = keyfile::parse(&contents).value;
               for cand in list_values(&kf, "MIME Cache", mimetype) {
                  push(cand, &removed, &mut out);
               }
            }
         }
      }
      out
   }

   /// Parse every `mimeapps.list` in the chain once, in priority order.
   fn mimeapps_files(&self) -> Vec<keyfile::KeyFile> {
      mimeapps_search_paths(self.dirs)
         .iter()
         .filter_map(|p| std::fs::read_to_string(p).ok())
         .map(|c| keyfile::parse(&c).value)
         .collect()
   }

   /// A handler is usable when its desktop file resolves and its `Exec=` binary
   /// exists. This prevents stale entries from hiding later candidates.
   fn desktop_is_usable(&self, name: &str) -> bool {
      match crate::desktop_entry::find_desktop_file(self.dirs, name) {
         Some(path) => self.exec_binary_exists(&path),
         None => false,
      }
   }

   fn exec_binary_exists(&self, desktop: &Path) -> bool {
      let Ok(parsed) = keyfile::parse_path(desktop) else {
         return false;
      };
      let Some(exec) = parsed
         .value
         .group("Desktop Entry")
         .and_then(|g| g.get("Exec"))
         .map(keyfile::unescape_value)
      else {
         return false;
      };
      let Ok(tokens) = crate::exec::tokenize(&exec) else {
         return false;
      };
      let binary = tokens
         .first()
         .map(|t| {
            t.fragments
               .iter()
               .filter_map(|f| {
                  match f {
                     crate::exec::Fragment::Literal(s) => Some(s.as_str()),
                     crate::exec::Fragment::Field(_) => None,
                  }
               })
               .collect::<String>()
         })
         .unwrap_or_default();
      if binary.is_empty() {
         return false;
      }
      let p = Path::new(&binary);
      if p.is_absolute() {
         return is_executable(p);
      }
      let path_dirs = self.dirs.exec_path();
      if path_dirs.is_empty() {
         // Keep handlers when no PATH is available to verify them.
         return true;
      }
      path_dirs.iter().any(|d| is_executable(&d.join(&binary)))
   }
}

fn is_executable(path: &Path) -> bool {
   #[cfg(unix)]
   {
      use std::os::unix::fs::PermissionsExt as _;
      path
         .metadata()
         .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
   }
   #[cfg(not(unix))]
   path.is_file()
}

/// List value for `key` in `[section]` of a parsed MIME association file.
fn list_values(kf: &keyfile::KeyFile, section: &str, key: &str) -> Vec<String> {
   kf.group(section).map(|g| g.list(key)).unwrap_or_default()
}

/// Resolve glob candidates with an optional magic result. Magic at priority 80
/// or above wins. Otherwise a unique top-weight glob wins, with magic breaking
/// ties when it names one of the candidates.
fn resolve(globs: &[(String, u32)], magic: Option<&(String, u32)>) -> Option<String> {
   if let Some((mmime, mprio)) = magic
      && *mprio >= 80
   {
      return Some(mmime.clone());
   }
   if let Some((_, top_weight)) = globs.first() {
      let top = globs
         .iter()
         .filter(|(_, w)| w == top_weight)
         .collect::<Vec<&(String, u32)>>();
      if top.len() == 1 {
         return Some(top[0].0.clone());
      }
      if let Some((mmime, _)) = magic
         && top.iter().any(|(m, _)| m == mmime)
      {
         return Some(mmime.clone());
      }
      return Some(top[0].0.clone());
   }
   magic.map(|(m, _)| m.clone())
}

/// All `mimeapps.list` files in spec lookup order (highest priority first).
#[must_use]
pub fn mimeapps_search_paths(dirs: &XdgDirs) -> Vec<PathBuf> {
   let prefixes = &dirs.current_desktop;
   let mut paths = Vec::new();
   let mut push_for_dir = |dir: PathBuf| {
      for prefix in prefixes {
         paths.push(dir.join(format!("{prefix}-mimeapps.list")));
      }
      paths.push(dir.join("mimeapps.list"));
   };
   for dir in dirs.config_dirs() {
      push_for_dir(dir.to_path_buf());
   }
   for dir in dirs.data_dirs() {
      push_for_dir(dir.join("applications"));
   }
   paths
}

fn read_prefix(path: &Path, cap: usize) -> Option<Vec<u8>> {
   use std::io::Read as _;
   let file = std::fs::File::open(path).ok()?;
   let mut buf = Vec::new();
   file.take(cap as u64).read_to_end(&mut buf).ok()?;
   Some(buf)
}

// ---- free-function API (each builds a store, runs one query) ---------------

#[must_use]
pub fn detect(dirs: &XdgDirs, path: &Path) -> Option<String> {
   MimeStore::load(dirs).detect(path)
}

#[must_use]
pub fn detect_by_glob(dirs: &XdgDirs, filename: &str) -> Option<String> {
   MimeStore::load(dirs).detect_by_glob(filename)
}

#[must_use]
pub fn query_default(dirs: &XdgDirs, mimetype: &str) -> Option<String> {
   MimeStore::load(dirs).query_default(mimetype)
}

#[must_use]
pub fn list_handlers(dirs: &XdgDirs, mimetype: &str) -> Vec<String> {
   MimeStore::load(dirs).list_handlers(mimetype)
}

#[must_use]
pub fn resolve_alias(dirs: &XdgDirs, mime: &str) -> String {
   MimeStore::load(dirs).resolve_alias(mime)
}

#[must_use]
pub fn parents(dirs: &XdgDirs, mime: &str) -> Vec<String> {
   MimeStore::load(dirs).parents(mime)
}

/// Set `mimetype`'s default handler to `desktop` in
/// `$XDG_CONFIG_HOME/mimeapps.list`.
///
/// Other sections and formatting are preserved. A uniquely named sibling file
/// keeps the final replacement atomic.
pub fn set_default(dirs: &XdgDirs, mimetype: &str, desktop: &str) -> io::Result<PathBuf> {
   set_default_at(&dirs.config_home().join("mimeapps.list"), mimetype, desktop)
}

/// Set the default handler in a specific `mimeapps.list`.
///
/// Symlinks are preserved by rewriting their target. The temporary file is
/// created beside that target so the final rename stays atomic.
pub fn set_default_at(path: &Path, mimetype: &str, desktop: &str) -> io::Result<PathBuf> {
   let target = if path.is_symlink() {
      std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
   } else {
      path.to_path_buf()
   };
   if let Some(parent) = target.parent() {
      std::fs::create_dir_all(parent)?;
   }
   let original = std::fs::read_to_string(&target).unwrap_or_default();
   let rewritten = rewrite_default(&original, mimetype, desktop);

   let tmp = unique_sibling(&target);
   std::fs::write(&tmp, rewritten)?;
   match std::fs::rename(&tmp, &target) {
      Ok(()) => Ok(target),
      Err(e) => {
         let _ = std::fs::remove_file(&tmp);
         Err(e)
      },
   }
}

/// A unique temp path beside `target`, so a fixed name can't be hijacked via a
/// pre-planted symlink and two writers can't clobber each other's temp.
fn unique_sibling(target: &Path) -> PathBuf {
   static COUNTER: AtomicU64 = AtomicU64::new(0);
   let nanos = SystemTime::now()
      .duration_since(UNIX_EPOCH)
      .map_or(0, |d| d.as_nanos());
   let n = COUNTER.fetch_add(1, Ordering::Relaxed);
   let pid = std::process::id();
   let name = format!(".mimeapps.list.{pid}.{nanos}.{n}.tmp");
   match target.parent() {
      Some(parent) => parent.join(name),
      None => PathBuf::from(name),
   }
}

/// Ensure `[Default Applications]` contains `mimetype=desktop`, replacing any
/// existing entry. All other content (comments, blank lines, order) is kept.
fn rewrite_default(contents: &str, mimetype: &str, desktop: &str) -> String {
   let new_line = format!("{mimetype}={desktop};");
   let mut out = Vec::<String>::new();
   let mut in_default = false;
   let mut saw_default = false;
   let mut replaced = false;
   // Blank lines at the tail of the section, held back so a freshly inserted
   // key attaches to the key block rather than landing after the separator.
   let mut pending_blanks = Vec::<String>::new();

   for line in contents.lines() {
      let trimmed = line.trim_end_matches('\r');
      if let Some(name) = trimmed.strip_prefix('[').and_then(|s| s.strip_suffix(']')) {
         if in_default && !replaced {
            out.push(new_line.clone());
            replaced = true;
         }
         out.append(&mut pending_blanks);
         in_default = name == "Default Applications";
         saw_default |= in_default;
         out.push(trimmed.to_owned());
         continue;
      }
      if in_default && trimmed.is_empty() {
         pending_blanks.push(trimmed.to_owned());
         continue;
      }
      if in_default
         && let Some((k, _)) = trimmed.split_once('=')
         && k.trim_end() == mimetype
      {
         out.append(&mut pending_blanks);
         if !replaced {
            out.push(new_line.clone());
            replaced = true;
         }
         continue; // drop the old (or duplicate) entry
      }
      out.append(&mut pending_blanks);
      out.push(trimmed.to_owned());
   }

   if in_default && !replaced {
      out.push(new_line.clone());
   }
   out.append(&mut pending_blanks);
   if !saw_default {
      if !out.is_empty() && !out.last().is_some_and(std::string::String::is_empty) {
         out.push(String::new());
      }
      out.push("[Default Applications]".to_owned());
      out.push(new_line);
   }

   let mut result = out.join("\n");
   result.push('\n');
   result
}

#[cfg(test)]
mod tests {
   use super::*;

   #[test]
   fn resolve_policy() {
      // High-priority magic overrides globs.
      assert_eq!(
         resolve(
            &[("text/plain".into(), 50)],
            Some(&("image/png".into(), 80))
         ),
         Some("image/png".into())
      );
      // Unique top-weight glob wins when magic is weak.
      assert_eq!(
         resolve(&[("application/pdf".into(), 50)], None),
         Some("application/pdf".into())
      );
      // Tie broken by magic naming one of them.
      assert_eq!(
         resolve(
            &[("a/x".into(), 50), ("b/y".into(), 50)],
            Some(&("b/y".into(), 50))
         ),
         Some("b/y".into())
      );
      // No glob, weak magic → magic.
      assert_eq!(resolve(&[], Some(&("x/y".into(), 50))), Some("x/y".into()));
      assert_eq!(resolve(&[], None), None);
   }

   #[test]
   fn rewrite_inserts_into_missing_section() {
      let out = rewrite_default("", "text/html", "firefox.desktop");
      assert!(out.contains("[Default Applications]"));
      assert!(out.contains("text/html=firefox.desktop;"));
      assert!(out.ends_with('\n'));
   }

   #[test]
   fn rewrite_replaces_existing_and_keeps_others() {
      let original = "\
[Default Applications]
text/html=old.desktop
image/png=viewer.desktop

[Added Associations]
text/html=other.desktop;
";
      let out = rewrite_default(original, "text/html", "new.desktop");
      assert!(out.contains("text/html=new.desktop;"));
      assert!(!out.contains("text/html=old.desktop"));
      // Untouched entries and the other section survive.
      assert!(out.contains("image/png=viewer.desktop"));
      assert!(out.contains("[Added Associations]"));
      assert!(out.contains("text/html=other.desktop;"));
      // Exactly one Default mapping for text/html.
      assert_eq!(out.matches("text/html=new.desktop;").count(), 1);
   }

   #[test]
   fn rewrite_appends_to_existing_section_before_blank() {
      let original = "\
[Default Applications]
image/png=viewer.desktop

[Other]
k=v
";
      let out = rewrite_default(original, "text/html", "ff.desktop");
      let lines = out.lines().collect::<Vec<&str>>();
      let png = lines.iter().position(|l| l.contains("image/png")).unwrap();
      let html = lines.iter().position(|l| l.contains("text/html")).unwrap();
      let other = lines.iter().position(|l| l.contains("[Other]")).unwrap();
      // New key joins the Default block (right after png, before [Other]).
      assert_eq!(html, png + 1);
      assert!(html < other);
   }

   #[test]
   fn unique_sibling_differs_each_call_and_stays_in_dir() {
      let target = Path::new("/tmp/sub/mimeapps.list");
      let a = unique_sibling(target);
      let b = unique_sibling(target);
      assert_ne!(a, b);
      assert_eq!(a.parent(), Some(Path::new("/tmp/sub")));
   }

   /// A throwaway directory under the system temp dir, removed on drop.
   struct TempDir(PathBuf);
   impl TempDir {
      fn new() -> Self {
         let dir = std::env::temp_dir().join(unique_sibling(Path::new("xdgtest")));
         std::fs::create_dir_all(&dir).unwrap();
         Self(dir)
      }
   }
   impl Drop for TempDir {
      fn drop(&mut self) {
         let _ = std::fs::remove_dir_all(&self.0);
      }
   }

   #[test]
   fn detect_does_not_block_on_fifo() {
      use std::{
         process::Command,
         sync::mpsc,
         thread,
         time::Duration,
      };

      let dir = TempDir::new();
      let fifo = dir.0.join("test.fifo");
      if !Command::new("mkfifo")
         .arg(&fifo)
         .status()
         .is_ok_and(|status| status.success())
      {
         return;
      }

      let dirs = XdgDirs::from_values(XdgEnv {
         home: Some(dir.0.clone()),
         data_dirs: Some(Vec::new()),
         config_dirs: Some(Vec::new()),
         ..Default::default()
      });
      let (tx, rx) = mpsc::channel();
      thread::spawn(move || {
         let _ = tx.send(detect(&dirs, &fifo));
      });

      match rx.recv_timeout(Duration::from_secs(5)) {
         Ok(result) => assert_eq!(result, None),
         Err(mpsc::RecvTimeoutError::Timeout | mpsc::RecvTimeoutError::Disconnected) => {
            panic!("mime::detect blocked opening a FIFO")
         },
      }
   }

   #[test]
   fn set_default_at_writes_atomically() {
      let dir = TempDir::new();
      let path = dir.0.join("mimeapps.list");
      set_default_at(&path, "text/html", "ff.desktop").unwrap();
      let body = std::fs::read_to_string(&path).unwrap();
      assert!(body.contains("[Default Applications]"));
      assert!(body.contains("text/html=ff.desktop"));
      // No temp files left behind.
      let leftovers = std::fs::read_dir(&dir.0)
         .unwrap()
         .filter_map(std::result::Result::ok)
         .filter(|e| e.file_name().to_string_lossy().contains(".tmp"))
         .collect::<Vec<_>>();
      assert!(leftovers.is_empty(), "temp file leaked: {leftovers:?}");
   }

   use crate::xdg_dirs::XdgEnv;

   fn write_file(path: &Path, contents: &str) {
      std::fs::create_dir_all(path.parent().unwrap()).unwrap();
      std::fs::write(path, contents).unwrap();
   }

   /// Install `rel` under `<data>/applications/` with the given Exec line.
   fn install_app(data: &Path, rel: &str, exec: &str) {
      write_file(
         &data.join("applications").join(rel),
         &format!("[Desktop Entry]\nType=Application\nExec={exec}\n"),
      );
   }

   fn make_binary(dir: &Path) -> PathBuf {
      use std::os::unix::fs::PermissionsExt as _;
      let p = dir.join("app-bin");
      std::fs::write(&p, "#!/bin/sh\n").unwrap();
      std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
      p
   }

   /// An `XdgDirs` whose only config dir is `config` and only data dir is
   /// `data`, isolated from the host system.
   fn test_dirs(config: &Path, data: &Path) -> XdgDirs {
      XdgDirs::from_values(XdgEnv {
         home: Some(PathBuf::from("/nonexistent")),
         config_home: Some(config.to_path_buf()),
         data_home: Some(data.to_path_buf()),
         data_dirs: Some(Vec::new()),
         config_dirs: Some(Vec::new()),
         ..Default::default()
      })
   }

   #[test]
   fn user_removal_blacklists_system_default() {
      let tmp = TempDir::new();
      let (config, data) = (tmp.0.join("config"), tmp.0.join("data"));
      let bin = make_binary(&tmp.0);
      let exec = bin.to_string_lossy().to_string();
      install_app(&data, "chromium.desktop", &exec);
      install_app(&data, "fallback.desktop", &exec);
      write_file(
         &data.join("applications/mimeapps.list"),
         "[Default Applications]\ntext/html=chromium.desktop;fallback.desktop;\n",
      );
      let dirs = test_dirs(&config, &data);

      assert_eq!(
         MimeStore::load(&dirs).query_default("text/html").as_deref(),
         Some("chromium.desktop")
      );

      // A user-level removal must invalidate the system-level default.
      write_file(
         &config.join("mimeapps.list"),
         "[Removed Associations]\ntext/html=chromium.desktop\n",
      );
      assert_eq!(
         MimeStore::load(&dirs).query_default("text/html").as_deref(),
         Some("fallback.desktop")
      );
   }

   #[test]
   fn stale_handler_skipped_and_vendor_prefix_resolved() {
      let tmp = TempDir::new();
      let (config, data) = (tmp.0.join("config"), tmp.0.join("data"));
      let bin = make_binary(&tmp.0);
      // The stale binary is skipped in favor of the vendor-layout entry.
      install_app(&data, "stale.desktop", "/nonexistent/gone-away");
      install_app(&data, "vendor/app.desktop", &bin.to_string_lossy());
      write_file(
         &data.join("applications/mimeapps.list"),
         "[Default Applications]\nx/y=stale.desktop;vendor-app.desktop;\n",
      );
      let dirs = test_dirs(&config, &data);
      assert_eq!(
         MimeStore::load(&dirs).query_default("x/y").as_deref(),
         Some("vendor-app.desktop")
      );
   }

   #[test]
   fn legacy_defaults_list_consulted_after_mimeapps() {
      let tmp = TempDir::new();
      let (config, data) = (tmp.0.join("config"), tmp.0.join("data"));
      let bin = make_binary(&tmp.0);
      install_app(&data, "legacy.desktop", &bin.to_string_lossy());
      write_file(
         &data.join("applications/defaults.list"),
         "[Default Applications]\nx/z=legacy.desktop\n",
      );
      let dirs = test_dirs(&config, &data);
      assert_eq!(
         MimeStore::load(&dirs).query_default("x/z").as_deref(),
         Some("legacy.desktop")
      );
   }

   #[test]
   fn set_default_at_follows_symlink_target() {
      let dir = TempDir::new();
      let real = dir.0.join("real-mimeapps.list");
      std::fs::write(&real, "[Default Applications]\nimage/png=v.desktop\n").unwrap();
      let link = dir.0.join("mimeapps.list");
      std::os::unix::fs::symlink(&real, &link).unwrap();

      set_default_at(&link, "text/html", "ff.desktop").unwrap();

      // The link is preserved (still a symlink) and the real file was updated.
      assert!(link.is_symlink(), "symlink was clobbered");
      let body = std::fs::read_to_string(&real).unwrap();
      assert!(body.contains("text/html=ff.desktop"));
      assert!(body.contains("image/png=v.desktop")); // existing entry kept
   }
}
