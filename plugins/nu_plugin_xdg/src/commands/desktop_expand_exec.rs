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
   SyntaxShape,
   Type,
   Value,
};
use xdg_core::exec::{
   self,
   FieldInputs,
};

pub struct DesktopExpandExec;

impl SimplePluginCommand for DesktopExpandExec {
   type Plugin = crate::NuPluginXdg;

   fn name(&self) -> &'static str {
      "xdg desktop expand-exec"
   }

   fn signature(&self) -> Signature {
      Signature::build(self.name())
         .category(Category::Platform)
         .input_output_type(Type::Nothing, Type::List(Type::String.into()))
         .required(
            "exec",
            SyntaxShape::String,
            "The raw Exec= value from a Desktop Entry",
         )
         .named(
            "files",
            SyntaxShape::List(SyntaxShape::String.into()),
            "Local file paths to substitute for %f/%F",
            Some('f'),
         )
         .named(
            "urls",
            SyntaxShape::List(SyntaxShape::String.into()),
            "URLs to substitute for %u/%U",
            Some('u'),
         )
         .named(
            "icon",
            SyntaxShape::String,
            "Icon name to substitute for %i (expands to `--icon <name>`)",
            Some('i'),
         )
         .named(
            "name",
            SyntaxShape::String,
            "Application name to substitute for %c",
            Some('n'),
         )
         .named(
            "desktop-path",
            SyntaxShape::String,
            "Path to the .desktop file, substituted for %k",
            Some('k'),
         )
   }

   fn description(&self) -> &'static str {
      "Expand the field codes in an Exec= value into an argv list"
   }

   fn extra_description(&self) -> &'static str {
      "Follows the Desktop Entry quoting rules. %f and %u take a single file or URL, %F and %U \
       take the whole list and must stand alone, %i expands to --icon plus the icon name, %c is \
       the localized name, %k is the desktop file path, and %% is a literal percent. Deprecated \
       codes like %d and %m are dropped. More than one file or URL code in a line is an error. \
       When the line has no file or URL code at all, the first input is appended at the end, which \
       is what xdg-open does."
   }

   fn search_terms(&self) -> Vec<&str> {
      vec!["xdg", "desktop", "exec", "field", "code"]
   }

   fn examples(&self) -> Vec<Example<'_>> {
      vec![
         Example {
            example:     "xdg desktop expand-exec 'firefox %u' --urls [https://example.com]",
            description: "Expand a single-url launcher",
            result:      Some(Value::test_list(vec![
               Value::test_string("firefox"),
               Value::test_string("https://example.com"),
            ])),
         },
         Example {
            example:     "xdg desktop expand-exec 'gimp %F' --files [a.png b.png]",
            description: "Expand a multi-file launcher",
            result:      Some(Value::test_list(vec![
               Value::test_string("gimp"),
               Value::test_string("a.png"),
               Value::test_string("b.png"),
            ])),
         },
      ]
   }

   fn run(
      &self,
      _plugin: &Self::Plugin,
      _engine: &EngineInterface,
      call: &EvaluatedCall,
      _input: &Value,
   ) -> Result<Value, LabeledError> {
      let exec_str = call.req::<String>(0)?;
      let inputs = FieldInputs {
         files:        call.get_flag("files")?.unwrap_or_default(),
         urls:         call.get_flag("urls")?.unwrap_or_default(),
         icon:         call.get_flag("icon")?,
         name:         call.get_flag("name")?,
         desktop_path: call.get_flag("desktop-path")?,
      };

      let tokens = exec::tokenize(&exec_str).map_err(|err| {
         LabeledError::new(err.to_string()).with_label("in this Exec value", call.head)
      })?;
      let argv = exec::expand(&tokens, &inputs).map_err(|err| {
         LabeledError::new(err.to_string()).with_label("in this Exec value", call.head)
      })?;

      Ok(Value::list(
         argv
            .into_iter()
            .map(|a| Value::string(a, call.head))
            .collect(),
         call.head,
      ))
   }
}
