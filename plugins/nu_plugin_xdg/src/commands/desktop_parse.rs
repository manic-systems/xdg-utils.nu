use std::path::PathBuf;

use nu_plugin::{
   EngineInterface,
   EvaluatedCall,
   SimplePluginCommand,
};
use nu_protocol::{
   Category,
   Example,
   LabeledError,
   Signature,
   Span,
   SyntaxShape,
   Type,
   Value,
   record,
};
use xdg_core::{
   desktop_entry::{
      self,
      DesktopEntry,
   },
   keyfile::KeyFile,
};

pub struct DesktopParse;

impl SimplePluginCommand for DesktopParse {
   type Plugin = crate::NuPluginXdg;

   fn name(&self) -> &'static str {
      "xdg desktop parse"
   }

   fn signature(&self) -> Signature {
      Signature::build(self.name())
         .category(Category::Platform)
         .input_output_type(Type::Nothing, Type::Any)
         .required(
            "path",
            SyntaxShape::Filepath,
            "Path to the .desktop file to parse",
         )
         .switch(
            "raw",
            "Return every section verbatim, including all locale-tagged keys",
            None,
         )
   }

   fn description(&self) -> &'static str {
      "Parse a .desktop file into a typed record"
   }

   fn extra_description(&self) -> &'static str {
      "Reads the [Desktop Entry] group and hands back a record with real types. Name, GenericName, \
       Comment and Icon are resolved against your locale. MimeType, Categories and the other list \
       keys become lists, Terminal and the rest of the flags become booleans, and actions come out \
       as a list of records with id, name, icon and exec. Use --raw to get every section verbatim \
       instead, one string per key, locales kept as suffixes like Name[en_US] and no escape \
       processing."
   }

   fn search_terms(&self) -> Vec<&str> {
      vec!["xdg", "desktop", "entry", "parse"]
   }

   fn examples(&self) -> Vec<Example<'_>> {
      vec![
         Example {
            example:     "xdg desktop parse /usr/share/applications/firefox.desktop",
            description: "Locale-resolved typed record of the main group",
            result:      None,
         },
         Example {
            example:     "xdg desktop parse --raw /usr/share/applications/firefox.desktop",
            description: "Every section, every locale, raw values",
            result:      None,
         },
      ]
   }

   fn run(
      &self,
      _plugin: &Self::Plugin,
      engine: &EngineInterface,
      call: &EvaluatedCall,
      _input: &Value,
   ) -> Result<Value, LabeledError> {
      let path_spanned = call.req::<String>(0)?;
      let path_value = call.positional[0].clone();
      let path = PathBuf::from(&path_spanned);

      let parsed = desktop_entry::parse_path(&path).map_err(|err| {
         LabeledError::new(format!("Failed to read {}: {err}", path.display()))
            .with_label("path comes from here", path_value.span())
      })?;
      // Keep benign desktop-entry diagnostics from spamming stderr on every launch.
      if crate::engine_env::debug_level(engine) >= 1 {
         for diag in &parsed.diagnostics {
            eprintln!("xdg desktop parse: {}: {diag}", path.display());
         }
      }
      let file = parsed.value;

      if call.has_flag("raw")? {
         return Ok(value_for_raw_file(&file, call.head));
      }

      let locale = crate::engine_env::locale_from_engine(engine)?;
      let entry = DesktopEntry::from_file(&file, &locale).ok_or_else(|| {
         LabeledError::new(format!("{} has no [Desktop Entry] section", path.display()))
            .with_label("not a valid Desktop Entry file", path_value.span())
      })?;
      Ok(value_for_entry(&entry, call.head))
   }
}

fn opt_string(v: Option<&str>, span: Span) -> Value {
   match v {
      Some(s) => Value::string(s, span),
      None => Value::nothing(span),
   }
}

fn string_list(items: &[String], span: Span) -> Value {
   Value::list(items.iter().map(|s| Value::string(s, span)).collect(), span)
}

fn value_for_entry(entry: &DesktopEntry, span: Span) -> Value {
   let actions = entry
      .actions
      .iter()
      .map(|a| {
         Value::record(
            record! {
                "id" => Value::string(&a.id, span),
                "name" => opt_string(a.name.as_deref(), span),
                "icon" => opt_string(a.icon.as_deref(), span),
                "exec" => opt_string(a.exec.as_deref(), span),
            },
            span,
         )
      })
      .collect::<Vec<Value>>();

   Value::record(
      record! {
          "type" => Value::string(entry.entry_type.as_str(), span),
          "name" => opt_string(entry.name.as_deref(), span),
          "generic_name" => opt_string(entry.generic_name.as_deref(), span),
          "comment" => opt_string(entry.comment.as_deref(), span),
          "icon" => opt_string(entry.icon.as_deref(), span),
          "exec" => opt_string(entry.exec.as_deref(), span),
          "try_exec" => opt_string(entry.try_exec.as_deref(), span),
          "path" => opt_string(entry.path.as_deref(), span),
          "url" => opt_string(entry.url.as_deref(), span),
          "terminal" => Value::bool(entry.terminal, span),
          "no_display" => Value::bool(entry.no_display, span),
          "hidden" => Value::bool(entry.hidden, span),
          "startup_notify" => Value::bool(entry.startup_notify, span),
          "dbus_activatable" => Value::bool(entry.dbus_activatable, span),
          "mime_types" => string_list(&entry.mime_types, span),
          "categories" => string_list(&entry.categories, span),
          "keywords" => string_list(&entry.keywords, span),
          "only_show_in" => string_list(&entry.only_show_in, span),
          "not_show_in" => string_list(&entry.not_show_in, span),
          "actions" => Value::list(actions, span),
      },
      span,
   )
}

fn value_for_raw_file(file: &KeyFile, span: Span) -> Value {
   let sections = file
      .groups
      .iter()
      .map(|g| {
         let entries = g
            .entries
            .iter()
            .map(|e| {
               Value::record(
                  record! {
                      "key" => Value::string(&e.key, span),
                      "locale" => match &e.locale {
                          Some(l) => Value::string(l, span),
                          None => Value::nothing(span),
                      },
                      "value" => Value::string(&e.value, span),
                      "line" => Value::int(e.line as i64, span),
                  },
                  span,
               )
            })
            .collect::<Vec<Value>>();
         Value::record(
            record! {
                "section" => Value::string(&g.name, span),
                "entries" => Value::list(entries, span),
            },
            span,
         )
      })
      .collect::<Vec<Value>>();
   Value::list(sections, span)
}
