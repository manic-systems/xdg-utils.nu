use nu_plugin::{
   EngineInterface,
   EvaluatedCall,
   SimplePluginCommand,
};
use nu_protocol::{
   Category,
   LabeledError,
   Signature,
   Value,
};

pub struct Main;

impl SimplePluginCommand for Main {
   type Plugin = crate::NuPluginXdg;

   fn name(&self) -> &'static str {
      "xdg"
   }

   fn signature(&self) -> Signature {
      Signature::build(self.name()).category(Category::Platform)
   }

   fn description(&self) -> &'static str {
      "Commands for interacting with the Freedesktop XDG specification"
   }

   fn search_terms(&self) -> Vec<&str> {
      vec!["xdg", "freedesktop", "desktop", "mime"]
   }

   fn run(
      &self,
      _plugin: &Self::Plugin,
      engine: &EngineInterface,
      call: &EvaluatedCall,
      _input: &Value,
   ) -> Result<Value, LabeledError> {
      Ok(Value::string(engine.get_help()?, call.head))
   }
}
