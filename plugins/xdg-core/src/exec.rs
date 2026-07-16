//! Desktop Entry `Exec=` parsing and field-code expansion.
//!
//! See <https://specifications.freedesktop.org/desktop-entry-spec/desktop-entry-spec-latest.html#exec-variables>.
//!
//! [`tokenize`] applies desktop entry quoting rules and separates literal text
//! from recognized [`FieldCode`]s. [`expand`] then substitutes [`FieldInputs`]
//! while enforcing rules for standalone and file-consuming codes.

/// Inputs available for field-code substitution.
#[derive(Debug, Default, Clone)]
pub struct FieldInputs {
   pub files:        Vec<String>,
   pub urls:         Vec<String>,
   pub icon:         Option<String>,
   pub name:         Option<String>,
   /// Location of the desktop file itself (for `%k`).
   pub desktop_path: Option<String>,
}

/// A recognized `%x` field code.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FieldCode {
   /// `%f` expands to one file path.
   SingleFile,
   /// `%F` expands to the full file list and must stand alone.
   FileList,
   /// `%u` expands to one URL.
   SingleUrl,
   /// `%U` expands to the full URL list and must stand alone.
   UrlList,
   /// `%i` expands to `--icon <name>` and must stand alone.
   Icon,
   /// `%c` expands to the translated application name.
   Name,
   /// `%k` expands to the desktop file location.
   DesktopPath,
   /// Deprecated codes that expand to nothing.
   Deprecated(char),
}

impl FieldCode {
   const fn from_char(c: char) -> Option<Self> {
      Some(match c {
         'f' => Self::SingleFile,
         'F' => Self::FileList,
         'u' => Self::SingleUrl,
         'U' => Self::UrlList,
         'i' => Self::Icon,
         'c' => Self::Name,
         'k' => Self::DesktopPath,
         'd' | 'D' | 'n' | 'N' | 'v' | 'm' => Self::Deprecated(c),
         _ => return None,
      })
   }

   /// Codes that expand into a whole argument (or several) and therefore must
   /// be the entire token.
   const fn is_standalone(self) -> bool {
      matches!(self, Self::FileList | Self::UrlList | Self::Icon)
   }

   /// Whether this code consumes a file/URL (only one such code is allowed in
   /// an `Exec` line).
   const fn is_file_code(self) -> bool {
      matches!(
         self,
         Self::SingleFile | Self::FileList | Self::SingleUrl | Self::UrlList
      )
   }
}

/// Literal text or a field code within an argument token.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Fragment {
   Literal(String),
   Field(FieldCode),
}

/// One argument from the `Exec` line, as an ordered list of fragments.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Token {
   pub fragments: Vec<Fragment>,
   /// Whether any part was double quoted. A quoted empty token survives
   /// expansion, while an unquoted one is removed.
   pub quoted:    bool,
}

impl Token {
   fn push_literal(&mut self, c: char) {
      match self.fragments.last_mut() {
         Some(Fragment::Literal(s)) => s.push(c),
         _ => self.fragments.push(Fragment::Literal(c.to_string())),
      }
   }

   /// Return the field code when it occupies the whole token.
   const fn sole_field(&self) -> Option<FieldCode> {
      match self.fragments.as_slice() {
         [Fragment::Field(code)] => Some(*code),
         _ => None,
      }
   }
}

#[derive(Debug, PartialEq, Eq)]
pub enum ExecError {
   /// A standalone-only code (`%F`, `%U`, `%i`) appeared inside a larger token.
   EmbeddedMultiCode(char),
   /// More than one file/URL code in a single Exec line.
   MultipleFileCodes,
   /// An unrecognized `%x` field code.
   UnknownCode(char),
   /// Unterminated quote in the Exec value.
   UnterminatedQuote,
}

impl std::fmt::Display for ExecError {
   fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
      match self {
         Self::EmbeddedMultiCode(c) => {
            write!(
               f,
               "field code %{c} must stand alone as it expands into multiple arguments"
            )
         },
         Self::MultipleFileCodes => {
            write!(
               f,
               "more than one file field code (%f, %F, %u, %U) in Exec key; this .desktop file is \
                invalid"
            )
         },
         Self::UnknownCode(c) => write!(f, "unknown field code %{c} in Exec key"),
         Self::UnterminatedQuote => write!(f, "unterminated quote in Exec value"),
      }
   }
}

impl std::error::Error for ExecError {}

/// Lex an `Exec=` value into typed argument [`Token`]s.
///
/// Double quotes group text and backslashes escape `"`, `` ` ``, `$`, and `\`
/// within them. `%%` becomes a literal `%` and unknown codes are rejected. A
/// trailing bare `%` is ignored for compatibility with desktop files accepted
/// by upstream xdg-open.
pub fn tokenize(exec: &str) -> Result<Vec<Token>, ExecError> {
   let mut tokens = Vec::new();
   let mut current = Token::default();
   let mut have_token = false;
   let mut in_quote = false;
   let mut chars = exec.chars().peekable();

   while let Some(c) = chars.next() {
      if in_quote {
         match c {
            '"' => in_quote = false,
            '\\' => {
               match chars.peek().copied() {
                  Some(esc @ ('"' | '`' | '$' | '\\')) => {
                     chars.next();
                     current.push_literal(esc);
                  },
                  _ => current.push_literal('\\'),
               }
            },
            '%' => push_field(&mut current, &mut chars)?,
            _ => current.push_literal(c),
         }
         continue;
      }
      match c {
         ' ' | '\t' | '\n' => {
            if have_token {
               tokens.push(std::mem::take(&mut current));
               have_token = false;
            }
         },
         '"' => {
            in_quote = true;
            have_token = true;
            current.quoted = true;
         },
         '%' => {
            push_field(&mut current, &mut chars)?;
            have_token = true;
         },
         _ => {
            current.push_literal(c);
            have_token = true;
         },
      }
   }
   if in_quote {
      return Err(ExecError::UnterminatedQuote);
   }
   if have_token {
      tokens.push(current);
   }
   Ok(tokens)
}

/// Consume the character after a `%` and append the corresponding fragment.
fn push_field(
   token: &mut Token,
   chars: &mut std::iter::Peekable<std::str::Chars<'_>>,
) -> Result<(), ExecError> {
   match chars.next() {
      None => Ok(()), // dangling '%' at end of value: dropped, see tokenize
      Some('%') => {
         token.push_literal('%');
         Ok(())
      },
      Some(c) => {
         match FieldCode::from_char(c) {
            Some(code) => {
               token.fragments.push(Fragment::Field(code));
               Ok(())
            },
            None => Err(ExecError::UnknownCode(c)),
         }
      },
   }
}

/// Expand tokenised `Exec` args into the final argv, substituting `inputs`.
///
/// Allows one file or URL code and requires `%F`, `%U`, and `%i` to stand
/// alone. Without a file code, the first file or URL is appended as upstream
/// xdg-open does. Empty unquoted expansions are removed, while a quoted `""`
/// remains an empty argument.
pub fn expand(tokens: &[Token], inputs: &FieldInputs) -> Result<Vec<String>, ExecError> {
   let mut out = Vec::new();
   let mut file_codes = 0_usize;

   for token in tokens {
      // A standalone code occupying the whole token.
      if let Some(code) = token.sole_field() {
         match code {
            FieldCode::FileList => {
               out.extend(inputs.files.iter().cloned());
               file_codes += 1;
               continue;
            },
            FieldCode::UrlList => {
               out.extend(inputs.urls.iter().cloned());
               file_codes += 1;
               continue;
            },
            FieldCode::Icon => {
               if let Some(icon) = &inputs.icon {
                  out.push("--icon".to_owned());
                  out.push(icon.clone());
               }
               continue;
            },
            FieldCode::SingleFile
            | FieldCode::SingleUrl
            | FieldCode::Name
            | FieldCode::DesktopPath
            | FieldCode::Deprecated(_) => {},
         }
      }

      // Otherwise build the token from its fragments.
      let mut s = String::new();
      for frag in &token.fragments {
         match frag {
            Fragment::Literal(lit) => s.push_str(lit),
            Fragment::Field(code) if code.is_standalone() => {
               return Err(ExecError::EmbeddedMultiCode(standalone_char(*code)));
            },
            Fragment::Field(code) => {
               if code.is_file_code() {
                  file_codes += 1;
               }
               expand_inline(*code, inputs, &mut s);
            },
         }
      }
      if s.is_empty() && !token.quoted {
         continue;
      }
      out.push(s);
   }

   if file_codes > 1 {
      return Err(ExecError::MultipleFileCodes);
   }
   if file_codes == 0
      && let Some(first) = inputs.files.first().or_else(|| inputs.urls.first())
   {
      out.push(first.clone());
   }
   Ok(out)
}

fn expand_inline(code: FieldCode, inputs: &FieldInputs, out: &mut String) {
   match code {
      FieldCode::SingleFile => out.push_str(inputs.files.first().map_or("", String::as_str)),
      FieldCode::SingleUrl => out.push_str(inputs.urls.first().map_or("", String::as_str)),
      FieldCode::Name => {
         if let Some(name) = &inputs.name {
            out.push_str(name);
         }
      },
      FieldCode::DesktopPath => {
         if let Some(path) = &inputs.desktop_path {
            out.push_str(path);
         }
      },
      // Deprecated codes vanish because standalone codes were handled above.
      FieldCode::Deprecated(_) | FieldCode::FileList | FieldCode::UrlList | FieldCode::Icon => {},
   }
}

const fn standalone_char(code: FieldCode) -> char {
   match code {
      FieldCode::FileList => 'F',
      FieldCode::UrlList => 'U',
      FieldCode::Icon => 'i',
      FieldCode::SingleFile
      | FieldCode::SingleUrl
      | FieldCode::Name
      | FieldCode::DesktopPath
      | FieldCode::Deprecated(_) => '?',
   }
}

#[cfg(test)]
mod tests {
   use super::*;

   fn inputs() -> FieldInputs {
      FieldInputs {
         files:        vec!["/a b.txt".into(), "/c.txt".into()],
         urls:         vec!["https://x".into()],
         icon:         Some("editor".into()),
         name:         Some("Editor".into()),
         desktop_path: Some("/app.desktop".into()),
      }
   }

   fn run(exec: &str, inputs: &FieldInputs) -> Result<Vec<String>, ExecError> {
      expand(&tokenize(exec)?, inputs)
   }

   #[test]
   fn quoting_groups_arguments() {
      let toks = tokenize(r#"foo "a b" c"#).unwrap();
      assert_eq!(toks.len(), 3);
      assert_eq!(expand(&toks, &FieldInputs::default()).unwrap(), vec![
         "foo", "a b", "c"
      ]);
   }

   #[test]
   fn single_and_list_codes() {
      assert_eq!(run("app %f", &inputs()).unwrap(), vec!["app", "/a b.txt"]);
      assert_eq!(run("app %F", &inputs()).unwrap(), vec![
         "app", "/a b.txt", "/c.txt"
      ]);
      assert_eq!(run("app %u", &inputs()).unwrap(), vec!["app", "https://x"]);
   }

   #[test]
   fn icon_and_name_and_desktop_path() {
      // These codes are not file codes, so with no file/url inputs nothing is
      // appended and the substitution stands on its own.
      let meta = FieldInputs {
         icon: Some("editor".into()),
         name: Some("Editor".into()),
         desktop_path: Some("/app.desktop".into()),
         ..Default::default()
      };
      assert_eq!(run("app %i", &meta).unwrap(), vec![
         "app", "--icon", "editor"
      ]);
      assert_eq!(run("app %c", &meta).unwrap(), vec!["app", "Editor"]);
      assert_eq!(run("app %k", &meta).unwrap(), vec!["app", "/app.desktop"]);
   }

   #[test]
   fn non_file_code_still_appends_first_file() {
      // %c is not a file code, so xdg-open's "append the file" rule applies.
      assert_eq!(run("app %c", &inputs()).unwrap(), vec![
         "app", "Editor", "/a b.txt"
      ]);
   }

   #[test]
   fn literal_percent_and_inline_field() {
      assert_eq!(run("app 100%%", &FieldInputs::default()).unwrap(), vec![
         "app", "100%"
      ]);
      // Inline single-file code inside a larger token.
      assert_eq!(run("prefix=%f", &inputs()).unwrap(), vec![
         "prefix=/a b.txt"
      ]);
   }

   #[test]
   fn no_file_code_appends_first_input() {
      assert_eq!(run("app", &inputs()).unwrap(), vec!["app", "/a b.txt"]);
      assert_eq!(run("app", &FieldInputs::default()).unwrap(), vec!["app"]);
   }

   #[test]
   fn deprecated_codes_drop() {
      assert_eq!(
         run("app %d %D extra", &FieldInputs::default()).unwrap(),
         vec!["app", "extra"]
      );
   }

   #[test]
   fn empty_expansions_vanish_unless_quoted() {
      // A file code with no input leaves no empty argument behind.
      assert_eq!(run("app %f extra", &FieldInputs::default()).unwrap(), vec![
         "app", "extra"
      ]);
      // A quoted empty token is a deliberate empty argument.
      assert_eq!(
         run(r#"app "" extra"#, &FieldInputs::default()).unwrap(),
         vec!["app", "", "extra"]
      );
   }

   #[test]
   fn dangling_percent_is_dropped() {
      assert_eq!(run("app %", &FieldInputs::default()).unwrap(), vec!["app"]);
      assert_eq!(run("app %", &inputs()).unwrap(), vec!["app", "/a b.txt"]);
   }

   #[test]
   fn errors() {
      assert_eq!(tokenize("app %z"), Err(ExecError::UnknownCode('z')));
      assert_eq!(
         tokenize(r#"app "unterminated"#),
         Err(ExecError::UnterminatedQuote)
      );
      assert_eq!(
         run("app x%F", &inputs()),
         Err(ExecError::EmbeddedMultiCode('F'))
      );
      assert_eq!(
         run("app %f %u", &inputs()),
         Err(ExecError::MultipleFileCodes)
      );
   }
}
