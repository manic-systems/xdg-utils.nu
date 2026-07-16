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

pub struct DesktopFind;

impl SimplePluginCommand for DesktopFind {
   type Plugin = crate::NuPluginXdg;

   fn name(&self) -> &'static str {
      "xdg desktop find"
   }

   fn signature(&self) -> Signature {
      Signature::build(self.name())
         .category(Category::Platform)
         .input_output_type(Type::Nothing, Type::Any)
         .required(
            "name",
            SyntaxShape::String,
            "Desktop entry stem or full filename (e.g. `firefox` or `firefox.desktop`)",
         )
   }

   fn description(&self) -> &'static str {
      "Find an installed desktop entry's path"
   }

   fn extra_description(&self) -> &'static str {
      "Checks applications/ under each XDG data dir in order, plus the legacy applnk tree. \
       Vendor-prefixed names work too, so vendor-app.desktop also matches vendor/app.desktop. \
       Returns the first hit as an absolute path, or nothing if the entry isn't installed anywhere."
   }

   fn search_terms(&self) -> Vec<&str> {
      vec!["xdg", "desktop", "find", "locate"]
   }

   fn examples(&self) -> Vec<Example<'_>> {
      vec![Example {
         example:     "xdg desktop find firefox",
         description: "Find Firefox's .desktop file (the `.desktop` suffix is optional)",
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
      let raw = call.req::<String>(0)?;
      match xdg_core::desktop_entry::find_desktop_file(&dirs, &raw) {
         Some(path) => Ok(Value::string(path.to_string_lossy(), call.head)),
         None => Ok(Value::nothing(call.head)),
      }
   }
}
