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

pub struct MimeListHandlers;

impl SimplePluginCommand for MimeListHandlers {
   type Plugin = crate::NuPluginXdg;

   fn name(&self) -> &'static str {
      "xdg mime list-handlers"
   }

   fn signature(&self) -> Signature {
      Signature::build(self.name())
         .category(Category::Platform)
         .input_output_type(Type::Nothing, Type::List(Type::String.into()))
         .required(
            "mimetype",
            SyntaxShape::String,
            "The MIME type to list registered handlers for",
         )
         .switch("visible", "Skip entries marked NoDisplay or Hidden", None)
   }

   fn description(&self) -> &'static str {
      "List the installed applications that can open a MIME type"
   }

   fn extra_description(&self) -> &'static str {
      "Gathers candidates from the whole mimeapps.list chain, defaults first, then added \
       associations, then every mimeinfo.cache. Anything listed under [Removed Associations] or \
       missing from disk is skipped. The result is de-duplicated and ordered by precedence. With \
       --visible, entries marked NoDisplay or Hidden are dropped too, which matters when picking a \
       handler automatically."
   }

   fn search_terms(&self) -> Vec<&str> {
      vec!["xdg", "mime", "handlers", "associations", "openers"]
   }

   fn examples(&self) -> Vec<Example<'_>> {
      vec![Example {
         example:     "xdg mime list-handlers text/html",
         description: "Every app that can open HTML, preferred first",
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
      let handlers = if call.has_flag("visible")? {
         mime::visible_handlers(&dirs, &mimetype)
      } else {
         mime::list_handlers(&dirs, &mimetype)
      };
      Ok(Value::list(
         handlers
            .into_iter()
            .map(|h| Value::string(h, call.head))
            .collect(),
         call.head,
      ))
   }
}
