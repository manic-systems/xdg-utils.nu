//! Bridge between the Nushell engine's `$env` and [`xdg_core::XdgDirs`].
//!
//! Nushell plugins do not inherit the shell's environment via `std::env`, so
//! the directory values must be read from the engine (which reflects the live
//! `$env`) rather than [`XdgDirs::from_env`].

use std::path::PathBuf;

use nu_plugin::EngineInterface;
use nu_protocol::ShellError;
use xdg_core::{
   XdgDirs,
   desktop_entry::Locale,
   xdg_dirs::{
      XdgEnv,
      split_paths,
   },
};

/// Read the effective locale from the engine's `$env`.
#[expect(clippy::result_large_err, reason = "we don't control this")]
pub fn locale_from_engine(engine: &EngineInterface) -> Result<Locale, ShellError> {
   for var in ["LC_ALL", "LC_MESSAGES", "LANG"] {
      if let Some(v) = engine.get_env_var(var)?
         && let Ok(s) = v.coerce_into_string()
         && !s.is_empty()
      {
         return Ok(Locale::parse(&s));
      }
   }
   Ok(Locale::default())
}

/// Resolve [`XdgDirs`] from the engine's environment variables.
#[expect(clippy::result_large_err, reason = "we don't control this")]
pub fn xdg_dirs_from_engine(engine: &EngineInterface) -> Result<XdgDirs, ShellError> {
   let env = |name: &str| -> Result<Option<String>, ShellError> {
      Ok(engine
         .get_env_var(name)?
         .and_then(|v| v.coerce_into_string().ok())
         .filter(|s| !s.is_empty()))
   };

   let current_desktop = env("XDG_CURRENT_DESKTOP")?
      .unwrap_or_default()
      .split(':')
      .filter(|s| !s.is_empty())
      .map(str::to_ascii_lowercase)
      .collect();

   let menu_prefix = env("XDG_MENU_PREFIX")?
      .unwrap_or_default()
      .split(':')
      .filter(|s| !s.is_empty())
      .map(std::borrow::ToOwned::to_owned)
      .collect();

   Ok(XdgDirs::from_values(XdgEnv {
      home: env("HOME")?.map(PathBuf::from),
      data_home: env("XDG_DATA_HOME")?.map(PathBuf::from),
      config_home: env("XDG_CONFIG_HOME")?.map(PathBuf::from),
      state_home: env("XDG_STATE_HOME")?.map(PathBuf::from),
      cache_home: env("XDG_CACHE_HOME")?.map(PathBuf::from),
      runtime_dir: env("XDG_RUNTIME_DIR")?.map(PathBuf::from),
      data_dirs: env("XDG_DATA_DIRS")?.map(|s| split_paths(&s)),
      config_dirs: env("XDG_CONFIG_DIRS")?.map(|s| split_paths(&s)),
      current_desktop,
      menu_prefix,
      exec_path: env("PATH")?.map(|s| split_paths(&s)),
   }))
}

/// The `$XDG_UTILS_DEBUG_LEVEL` convention shared by the xdg-utils scripts,
/// which is 0 when unset or unparsable.
pub fn debug_level(engine: &EngineInterface) -> u32 {
   engine
      .get_env_var("XDG_UTILS_DEBUG_LEVEL")
      .ok()
      .flatten()
      .and_then(|v| v.coerce_into_string().ok())
      .and_then(|s| s.trim().parse().ok())
      .unwrap_or(0)
}
