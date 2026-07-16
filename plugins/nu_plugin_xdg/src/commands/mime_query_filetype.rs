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

pub struct MimeQueryFiletype;

impl SimplePluginCommand for MimeQueryFiletype {
   type Plugin = crate::NuPluginXdg;

   fn name(&self) -> &'static str {
      "xdg mime query filetype"
   }

   fn signature(&self) -> Signature {
      Signature::build(self.name())
         .category(Category::Platform)
         .input_output_type(Type::Nothing, Type::Any)
         .required(
            "filename",
            SyntaxShape::String,
            "The filename (or path) to detect the MIME type of",
         )
         .switch(
            "glob",
            "Match by name only (globs), without reading file content",
            Some('g'),
         )
   }

   fn description(&self) -> &'static str {
      "Detect a file's MIME type from its name and content"
   }

   fn extra_description(&self) -> &'static str {
      "Matches the filename against the shared-mime-info globs and sniffs the content against the \
       magic database. A strong magic match beats the glob guess, otherwise the glob wins and \
       magic just breaks ties. The result is resolved to its canonical type. Only regular files \
       are read, and if neither method knows the file you get nothing back, so you can fall back \
       to something like gio. Pass --glob to skip the content read entirely, which also works for \
       paths that don't exist."
   }

   fn search_terms(&self) -> Vec<&str> {
      vec!["xdg", "mime", "filetype", "detect", "magic", "glob"]
   }

   fn examples(&self) -> Vec<Example<'_>> {
      vec![Example {
         example:     "xdg mime query filetype report.pdf",
         description: "Detect a file's MIME type from name + content",
         result:      Some(Value::test_string("application/pdf")),
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
      let filename = call.req::<String>(0)?;
      let result = if call.has_flag("glob")? {
         mime::detect_by_glob(&dirs, &filename)
      } else {
         mime::detect(&dirs, std::path::Path::new(&filename))
      };
      match result {
         Some(mimetype) => Ok(Value::string(mimetype, call.head)),
         None => Ok(Value::nothing(call.head)),
      }
   }
}
