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
use xdg_core::mime;

pub struct MimeSetDefault;

impl SimplePluginCommand for MimeSetDefault {
   type Plugin = crate::NuPluginXdg;

   fn name(&self) -> &'static str {
      "xdg mime set-default"
   }

   fn signature(&self) -> Signature {
      Signature::build(self.name())
         .category(Category::Platform)
         .input_output_type(Type::Nothing, Type::Nothing)
         .required(
            "desktop",
            SyntaxShape::String,
            "The .desktop name to set as default (e.g. firefox.desktop)",
         )
         .rest(
            "mimetypes",
            SyntaxShape::String,
            "One or more MIME types to associate with the application",
         )
   }

   fn description(&self) -> &'static str {
      "Set the default application for one or more MIME types"
   }

   fn extra_description(&self) -> &'static str {
      "Edits the [Default Applications] section of mimeapps.list in your XDG config home, leaving \
       every other section, key and blank line alone. The write goes through a temp file and \
       rename so it is atomic. The file and section are created if they don't exist yet."
   }

   fn search_terms(&self) -> Vec<&str> {
      vec!["xdg", "mime", "default", "set", "associate"]
   }

   fn examples(&self) -> Vec<Example<'_>> {
      vec![Example {
         example:     "xdg mime set-default firefox.desktop text/html x-scheme-handler/https",
         description: "Make Firefox the default for HTML and HTTPS links",
         result:      None,
      }]
   }

   fn run(
      &self,
      _plugin: &Self::Plugin,
      engine: &EngineInterface,
      call: &EvaluatedCall,
      _input: &Value,
   ) -> Result<Value, LabeledError> {
      let dirs = crate::engine_env::xdg_dirs_from_engine(engine)?;
      let desktop = call.req::<String>(0)?;
      let mimetypes = call.rest::<String>(1)?;
      if mimetypes.is_empty() {
         return Err(LabeledError::new("no MIME types given").with_label(
            "expected at least one MIME type after the .desktop name",
            call.head,
         ));
      }

      for mimetype in &mimetypes {
         mime::set_default(&dirs, mimetype, &desktop).map_err(|err| {
            LabeledError::new(format!("Failed to update mimeapps.list: {err}"))
               .with_label("while setting default here", call.head)
         })?;
      }

      Ok(Value::nothing(call.head))
   }
}
