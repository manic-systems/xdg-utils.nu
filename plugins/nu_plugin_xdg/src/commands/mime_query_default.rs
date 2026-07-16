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

pub struct MimeQueryDefault;

impl SimplePluginCommand for MimeQueryDefault {
   type Plugin = crate::NuPluginXdg;

   fn name(&self) -> &'static str {
      "xdg mime query default"
   }

   fn signature(&self) -> Signature {
      Signature::build(self.name())
         .category(Category::Platform)
         .input_output_type(Type::Nothing, Type::Any)
         .required(
            "mimetype",
            SyntaxShape::String,
            "The MIME type to look up (e.g. text/html)",
         )
   }

   fn description(&self) -> &'static str {
      "Look up the default application for a MIME type"
   }

   fn extra_description(&self) -> &'static str {
      "Walks the mimeapps.list chain in spec order, config dirs before data dirs and \
       desktop-prefixed files before plain ones. The first [Default Applications] entry that is \
       actually installed wins. Returns nothing when no default is set."
   }

   fn search_terms(&self) -> Vec<&str> {
      vec!["xdg", "mime", "default", "handler"]
   }

   fn examples(&self) -> Vec<Example<'_>> {
      vec![Example {
         example:     "xdg mime query default text/html",
         description: "Find the default browser's desktop file",
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
      let mimetype = call.req::<String>(0)?;
      match mime::query_default(&dirs, &mimetype) {
         Some(desktop) => Ok(Value::string(desktop, call.head)),
         None => Ok(Value::nothing(call.head)),
      }
   }
}
