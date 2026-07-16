use nu_protocol::{record, Span, Value};
use serde::Deserialize;

macro_rules! list_to_value {
    ($list:expr, $span:expr) => {
        Value::list($list.iter().map(|i| i.to_value($span)).collect(), $span)
    };
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "kebab-case")]
pub struct Node {
    #[serde(default, rename = "@name")]
    pub name: Option<String>,
    #[serde(default, rename = "interface")]
    pub interfaces: Vec<Interface>,
    #[serde(default, rename = "node")]
    pub children: Vec<Self>,
}

impl Node {
    pub fn from_xml(xml: &str) -> Result<Self, serde_xml_rs::Error> {
        serde_xml_rs::SerdeXml::new()
            .overlapping_sequences(true)
            .from_str(xml)
    }

    #[cfg(test)]
    pub fn with_name(name: impl Into<String>) -> Self {
        Self {
            name: Some(name.into()),
            interfaces: vec![],
            children: vec![],
        }
    }

    pub fn get_interface(&self, name: &str) -> Option<&Interface> {
        self.interfaces.iter().find(|i| i.name == name)
    }

    /// Find a method on an interface on this node, and then generate the signature of the method
    /// args.
    pub fn get_method_args_signature(&self, interface: &str, method: &str) -> Option<String> {
        Some(
            self.get_interface(interface)?
                .get_method(method)?
                .in_signature(),
        )
    }

    /// Find the signature of a property on an interface on this node.
    pub fn get_property_signature(&self, interface: &str, property: &str) -> Option<&str> {
        Some(
            &self
                .get_interface(interface)?
                .get_property(property)?
                .r#type,
        )
    }

    /// Represent the node as a nushell [Value].
    pub fn to_value(&self, span: Span) -> Value {
        Value::record(
            record! {
                "name" => self.name.as_ref().map(|s| Value::string(s, span)).unwrap_or_default(),
                "interfaces" => list_to_value!(self.interfaces, span),
                "children" => list_to_value!(self.children, span),
            },
            span,
        )
    }
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub struct Interface {
    #[serde(rename = "@name")]
    pub name: String,
    #[serde(default, rename = "method")]
    pub methods: Vec<Method>,
    #[serde(default, rename = "signal")]
    pub signals: Vec<Signal>,
    #[serde(default, rename = "property")]
    pub properties: Vec<Property>,
    #[serde(default, rename = "annotation")]
    pub annotations: Vec<Annotation>,
}

impl Interface {
    pub fn get_method(&self, name: &str) -> Option<&Method> {
        self.methods.iter().find(|m| m.name == name)
    }

    #[expect(dead_code, reason = "unused by the plugin but part of the introspection API")]
    pub fn get_signal(&self, name: &str) -> Option<&Signal> {
        self.signals.iter().find(|s| s.name == name)
    }

    pub fn get_property(&self, name: &str) -> Option<&Property> {
        self.properties.iter().find(|p| p.name == name)
    }

    /// Represent the interface as a nushell [Value].
    pub fn to_value(&self, span: Span) -> Value {
        Value::record(
            record! {
                "name" => Value::string(&self.name, span),
                "methods" => list_to_value!(self.methods, span),
                "signals" => list_to_value!(self.signals, span),
                "properties" => list_to_value!(self.properties, span),
                "annotations" => list_to_value!(self.annotations, span),
            },
            span,
        )
    }
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub struct Method {
    #[serde(rename = "@name")]
    pub name: String,
    #[serde(default, rename = "arg")]
    pub args: Vec<MethodArg>,
    #[serde(default, rename = "annotation")]
    pub annotations: Vec<Annotation>,
}

impl Method {
    /// Get the signature of the method args.
    pub fn in_signature(&self) -> String {
        self.args
            .iter()
            .filter(|arg| arg.direction == Direction::In)
            .map(|arg| &*arg.r#type)
            .collect()
    }

    #[expect(dead_code, reason = "kept to mirror in_signature")]
    /// Get the signature of the method result.
    pub fn out_signature(&self) -> String {
        self.args
            .iter()
            .filter(|arg| arg.direction == Direction::Out)
            .map(|arg| &*arg.r#type)
            .collect()
    }

    /// Represent the method as a nushell [Value].
    pub fn to_value(&self, span: Span) -> Value {
        Value::record(
            record! {
                "name" => Value::string(&self.name, span),
                "args" => list_to_value!(self.args, span),
                "annotations" => list_to_value!(self.annotations, span),
            },
            span,
        )
    }
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub struct MethodArg {
    #[serde(default, rename = "@name")]
    pub name: Option<String>,
    #[serde(rename = "@type")]
    pub r#type: String,
    #[serde(default, rename = "@direction")]
    pub direction: Direction,
}

impl MethodArg {
    #[cfg(test)]
    pub fn new(
        name: impl Into<String>,
        r#type: impl Into<String>,
        direction: Direction,
    ) -> Self {
        Self {
            name: Some(name.into()),
            r#type: r#type.into(),
            direction,
        }
    }

    /// Represent the method as a nushell [Value].
    pub fn to_value(&self, span: Span) -> Value {
        Value::record(
            record! {
                "name" => self.name.as_ref().map(|n| Value::string(n, span)).unwrap_or_default(),
                "type" => Value::string(&self.r#type, span),
                "direction" => self.direction.to_value(span),
            },
            span,
        )
    }
}

#[derive(Debug, Clone, Copy, Deserialize, Default, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum Direction {
    #[default]
    In,
    Out,
}

impl Direction {
    /// Represent the direction as a nushell [Value].
    pub fn to_value(self, span: Span) -> Value {
        match self {
            Self::In => Value::string("in", span),
            Self::Out => Value::string("out", span),
        }
    }
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub struct Signal {
    #[serde(rename = "@name")]
    pub name: String,
    #[serde(default, rename = "arg")]
    pub args: Vec<SignalArg>,
    #[serde(default, rename = "annotation")]
    pub annotations: Vec<Annotation>,
}

impl Signal {
    /// Represent the signal as a nushell [Value].
    pub fn to_value(&self, span: Span) -> Value {
        Value::record(
            record! {
                "name" => Value::string(&self.name, span),
                "args" => list_to_value!(self.args, span),
                "annotations" => list_to_value!(self.annotations, span),
            },
            span,
        )
    }
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub struct SignalArg {
    #[serde(default, rename = "@name")]
    pub name: Option<String>,
    #[serde(rename = "@type")]
    pub r#type: String,
}

impl SignalArg {
    /// Represent the argument as a nushell [Value].
    pub fn to_value(&self, span: Span) -> Value {
        Value::record(
            record! {
                "name" => self.name.as_ref().map(|n| Value::string(n, span)).unwrap_or_default(),
                "type" => Value::string(&self.r#type, span),
            },
            span,
        )
    }
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub struct Property {
    #[serde(rename = "@name")]
    pub name: String,
    #[serde(rename = "@type")]
    pub r#type: String,
    #[serde(rename = "@access")]
    pub access: Access,
    #[serde(default, rename = "annotation")]
    pub annotations: Vec<Annotation>,
}

impl Property {
    /// Represent the property as a nushell [Value].
    pub fn to_value(&self, span: Span) -> Value {
        Value::record(
            record! {
                "name" => Value::string(&self.name, span),
                "type" => Value::string(&self.r#type, span),
                "args" => self.access.to_value(span),
                "annotations" => list_to_value!(self.annotations, span),
            },
            span,
        )
    }
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Access {
    Read,
    Write,
    ReadWrite,
}

impl Access {
    /// Represent the access as a nushell [Value].
    pub fn to_value(&self, span: Span) -> Value {
        match self {
            Self::Read => Value::string("read", span),
            Self::Write => Value::string("write", span),
            Self::ReadWrite => Value::string("readwrite", span),
        }
    }
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub struct Annotation {
    #[serde(rename = "@name")]
    pub name: String,
    #[serde(rename = "@value")]
    pub value: String,
}

impl Annotation {
    #[cfg(test)]
    pub fn new(name: impl Into<String>, value: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            value: value.into(),
        }
    }

    /// Represent the annotation as a nushell [Value].
    pub fn to_value(&self, span: Span) -> Value {
        Value::record(
            record! {
                "name" => Value::string(&self.name, span),
                "value" => Value::string(&self.value, span),
            },
            span,
        )
    }
}

#[cfg(test)]
pub fn test_introspection_doc_rs() -> Node {
    Node {
        name: Some("/com/example/sample_object0".into()),
        interfaces: vec![Interface {
            name: "com.example.SampleInterface0".into(),
            methods: vec![
                Method {
                    name: "Frobate".into(),
                    args: vec![
                        MethodArg::new("foo", "i", Direction::In),
                        MethodArg::new("bar", "as", Direction::In),
                        MethodArg::new("baz", "a{us}", Direction::Out),
                    ],
                    annotations: vec![Annotation::new("org.freedesktop.DBus.Deprecated", "true")],
                },
                Method {
                    name: "Bazify".into(),
                    args: vec![
                        MethodArg::new("bar", "(iiu)", Direction::In),
                        MethodArg::new("len", "u", Direction::Out),
                        MethodArg::new("bar", "v", Direction::Out),
                    ],
                    annotations: vec![],
                },
                Method {
                    name: "Mogrify".into(),
                    args: vec![MethodArg::new("bar", "(iiav)", Direction::In)],
                    annotations: vec![],
                },
            ],
            signals: vec![Signal {
                name: "Changed".into(),
                args: vec![SignalArg {
                    name: Some("new_value".into()),
                    r#type: "b".into(),
                }],
                annotations: vec![],
            }],
            properties: vec![Property {
                name: "Bar".into(),
                r#type: "y".into(),
                access: Access::ReadWrite,
                annotations: vec![],
            }],
            annotations: vec![],
        }],
        children: vec![
            Node::with_name("child_of_sample_object"),
            Node::with_name("another_child_of_sample_object"),
        ],
    }
}

#[test]
#[expect(clippy::panic_in_result_fn, reason = "tests assert")]
pub fn parse_introspection_doc() -> Result<(), serde_xml_rs::Error> {
    let xml = include_str!("test_introspection_doc.xml");
    let result = Node::from_xml(xml)?;
    assert_eq!(result, test_introspection_doc_rs());
    Ok(())
}

#[test]
pub fn get_method_args_signature() {
    assert_eq!(
        test_introspection_doc_rs()
            .get_method_args_signature("com.example.SampleInterface0", "Frobate"),
        Some("ias".into())
    );
}
