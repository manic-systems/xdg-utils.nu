use nu_plugin::{
   MsgPackSerializer,
   Plugin,
   PluginCommand,
   serve_plugin,
};

mod commands;
mod engine_env;

fn main() {
   serve_plugin(&NuPluginXdg, MsgPackSerializer);
}

/// Plugin entry point.
pub struct NuPluginXdg;

impl Plugin for NuPluginXdg {
   fn version(&self) -> String {
      env!("CARGO_PKG_VERSION").into()
   }

   fn commands(&self) -> Vec<Box<dyn PluginCommand<Plugin = Self>>> {
      vec![
         Box::new(commands::Main),
         Box::new(commands::DesktopParse),
         Box::new(commands::DesktopFind),
         Box::new(commands::DesktopExpandExec),
         Box::new(commands::MimeQueryDefault),
         Box::new(commands::MimeQueryFiletype),
         Box::new(commands::MimeSetDefault),
         Box::new(commands::MimeListHandlers),
      ]
   }
}
