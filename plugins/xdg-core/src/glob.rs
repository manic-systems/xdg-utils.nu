//! Parsing and matching shared-mime-info `globs2` patterns.
//!
//! Each line contains a weight, MIME type, glob, and optional flags. The
//! matcher supports `*`, `?`, and character classes with ranges and negation.
//! The `cs` flag enables case-sensitive matching.

/// A single parsed `globs2` entry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Glob {
   pub weight:         u32,
   pub mime:           String,
   pub pattern:        String,
   pub case_sensitive: bool,
}

impl Glob {
   /// Parse one non-comment `globs2` line. Returns `None` for blank/comment
   /// lines or lines missing the weight/mime/glob fields.
   #[must_use]
   pub fn parse_line(line: &str) -> Option<Self> {
      let line = line.trim_end_matches('\r');
      if line.is_empty() || line.starts_with('#') {
         return None;
      }
      let mut parts = line.split(':');
      let weight = parts.next()?.parse::<u32>().ok()?;
      let mime = parts.next()?;
      let pattern = parts.next()?;
      let flags = parts.next().unwrap_or("");
      let case_sensitive = flags.split(',').any(|f| f == "cs");
      Some(Self {
         weight,
         mime: mime.to_owned(),
         pattern: pattern.to_owned(),
         case_sensitive,
      })
   }

   /// The length of the glob pattern, used as shared-mime-info's secondary
   /// tie-breaker (longer pattern is more specific).
   #[must_use]
   pub fn pattern_len(&self) -> usize {
      self.pattern.chars().count()
   }

   /// Whether this glob matches `name` comparing case-sensitively (pattern and
   /// name exactly as written).
   #[must_use]
   pub fn matches_case_sensitive(&self, name: &str) -> bool {
      glob_match(&to_chars(&self.pattern), &to_chars(name))
   }

   /// Whether this glob matches `name` with both folded to lowercase.
   #[must_use]
   pub fn matches_case_insensitive(&self, name: &str) -> bool {
      glob_match(
         &to_chars(&self.pattern.to_lowercase()),
         &to_chars(&name.to_lowercase()),
      )
   }

   /// Whether this glob matches `filename` using its case-sensitivity flag.
   /// Database lookups should use [`best_matches`] for two-pass matching.
   #[must_use]
   pub fn matches(&self, filename: &str) -> bool {
      if self.case_sensitive {
         self.matches_case_sensitive(filename)
      } else {
         self.matches_case_insensitive(filename)
      }
   }
}

/// Rank matching MIME types by weight and then pattern length, with duplicates
/// removed.
///
/// The first pass checks every pattern as written. The case-insensitive
/// patterns are folded only when that pass finds nothing. This keeps `*.c`
/// distinct from a case-sensitive `*.C`.
#[must_use]
pub fn best_matches(globs: &[Glob], filename: &str) -> Vec<(String, u32)> {
   let base = filename.rsplit('/').next().unwrap_or(filename);

   let mut matched = globs
      .iter()
      .filter(|g| g.matches_case_sensitive(base))
      .collect::<Vec<&Glob>>();
   if matched.is_empty() {
      matched = globs
         .iter()
         .filter(|g| !g.case_sensitive && g.matches_case_insensitive(base))
         .collect::<Vec<&Glob>>();
   }

   matched.sort_by(|a, b| {
      b.weight
         .cmp(&a.weight)
         .then_with(|| b.pattern_len().cmp(&a.pattern_len()))
   });
   let mut seen = std::collections::HashSet::new();
   matched
      .into_iter()
      .filter(|g| seen.insert(g.mime.clone()))
      .map(|g| (g.mime.clone(), g.weight))
      .collect()
}

fn to_chars(s: &str) -> Vec<char> {
   s.chars().collect()
}

/// Match `pat` against `text` with `*`, `?`, and character classes.
fn glob_match(pat: &[char], text: &[char]) -> bool {
   let mut pi = 0;
   let mut ti = 0;
   // Backtrack state for the most recent `*`.
   let mut star = None::<(usize, usize)>;

   while ti < text.len() {
      if pi < pat.len() {
         match pat[pi] {
            '*' => {
               star = Some((pi, ti));
               pi += 1;
               continue;
            },
            '?' => {
               pi += 1;
               ti += 1;
               continue;
            },
            '[' => {
               if let Some((matched, next_pi)) = match_class(pat, pi, text[ti]) {
                  if matched {
                     pi = next_pi;
                     ti += 1;
                     continue;
                  }
               } else {
                  // Treat an unterminated class opener as a literal.
                  if pat[pi] == text[ti] {
                     pi += 1;
                     ti += 1;
                     continue;
                  }
               }
            },
            c if c == text[ti] => {
               pi += 1;
               ti += 1;
               continue;
            },
            _ => {},
         }
      }
      // Backtrack to the last `*` and let it consume one more character.
      match star {
         Some((sp, st)) => {
            pi = sp + 1;
            ti = st + 1;
            star = Some((sp, st + 1));
         },
         None => return false,
      }
   }

   // Trailing `*`s match the empty remainder.
   while pi < pat.len() && pat[pi] == '*' {
      pi += 1;
   }
   pi == pat.len()
}

/// Match the character class at `start` and return the index after it.
fn match_class(pat: &[char], start: usize, ch: char) -> Option<(bool, usize)> {
   let mut i = start + 1;
   let negated = matches!(pat.get(i), Some('!' | '^'));
   if negated {
      i += 1;
   }
   let mut matched = false;
   // A leading `]` is a literal rather than the class terminator.
   let mut first = true;
   while i < pat.len() {
      let c = pat[i];
      if c == ']' && !first {
         return Some((matched ^ negated, i + 1));
      }
      first = false;
      // Range `a-b`, but only when `-` sits between two members (not before the
      // closing `]`).
      if pat.get(i + 1) == Some(&'-') && pat.get(i + 2).is_some_and(|&n| n != ']') {
         if (c..=pat[i + 2]).contains(&ch) {
            matched = true;
         }
         i += 3;
      } else {
         if c == ch {
            matched = true;
         }
         i += 1;
      }
   }
   None
}

#[cfg(test)]
mod tests {
   use super::*;

   fn m(pat: &str, name: &str) -> bool {
      glob_match(&to_chars(pat), &to_chars(name))
   }

   #[test]
   fn basic_wildcards() {
      assert!(m("*.txt", "a.txt"));
      assert!(!m("*.txt", "a.md"));
      assert!(m("foo?bar", "fooXbar"));
      assert!(!m("foo?bar", "foobar"));
      assert!(m("*", "anything"));
      assert!(m("a*b*c", "axxbyyc"));
      assert!(m("Makefile*", "Makefile.am"));
   }

   #[test]
   fn character_classes() {
      assert!(m("*.[ch]", "main.c"));
      assert!(m("*.[ch]", "defs.h"));
      assert!(!m("*.[ch]", "main.o"));
      assert!(m("*.[ch]pp", "a.cpp"));
      assert!(m("*.[ch]pp", "a.hpp"));
      // ranges
      assert!(m("file[0-9]", "file7"));
      assert!(!m("file[0-9]", "fileA"));
      // negation
      assert!(m("x[!0-9]", "xa"));
      assert!(!m("x[!0-9]", "x5"));
   }

   #[test]
   fn case_sensitivity_flag() {
      let ci = Glob::parse_line("50:text/x-readme:README*").unwrap();
      assert!(!ci.case_sensitive);
      assert!(ci.matches("readme.md"));
      assert!(ci.matches("README"));

      let cs = Glob::parse_line("50:text/x-readme:README*:cs").unwrap();
      assert!(cs.case_sensitive);
      assert!(cs.matches("README"));
      assert!(!cs.matches("readme.md"));
   }

   #[test]
   fn parse_line_fields() {
      let g = Glob::parse_line("50:application/pdf:*.pdf").unwrap();
      assert_eq!(g.weight, 50);
      assert_eq!(g.mime, "application/pdf");
      assert_eq!(g.pattern, "*.pdf");
      assert!(Glob::parse_line("# comment").is_none());
      assert!(Glob::parse_line("").is_none());
   }

   #[test]
   fn unterminated_class_is_literal() {
      assert!(m("a[bc", "a[bc"));
   }

   #[test]
   fn two_pass_disambiguates_c_from_cpp() {
      // The real shared-mime-info entries for C / C++ sources.
      let globs = [
         "50:text/x-c++src:*.C:cs",
         "50:text/x-c++src:*.C",
         "50:text/x-csrc:*.c:cs",
         "50:text/x-csrc:*.c",
         "50:text/x-chdr:*.h",
      ]
      .into_iter()
      .filter_map(Glob::parse_line)
      .collect::<Vec<Glob>>();

      // A case-sensitive `*.c` match prevents fallback to folded `*.C`.
      assert_eq!(
         best_matches(&globs, "main.c").first().map(|m| m.0.as_str()),
         Some("text/x-csrc")
      );
      // `main.C` is C++.
      assert_eq!(
         best_matches(&globs, "main.C").first().map(|m| m.0.as_str()),
         Some("text/x-c++src")
      );
      assert_eq!(
         best_matches(&globs, "defs.h").first().map(|m| m.0.as_str()),
         Some("text/x-chdr")
      );
   }

   #[test]
   fn ranks_by_weight_then_length() {
      let globs = [
         "50:text/plain:*.txt",
         "10:app/low:*.txt",
         "50:app/longer:*.tar.txt",
      ]
      .into_iter()
      .filter_map(Glob::parse_line)
      .collect::<Vec<Glob>>();
      // Higher weight wins first, followed by the longer pattern.
      assert_eq!(
         best_matches(&globs, "foo.tar.txt")
            .first()
            .map(|m| m.0.as_str()),
         Some("app/longer")
      );
      assert_eq!(
         best_matches(&globs, "foo.txt")
            .first()
            .map(|m| m.0.as_str()),
         Some("text/plain")
      );
   }

   #[test]
   fn case_insensitive_fallback_when_no_sensitive_match() {
      let globs = Glob::parse_line("50:text/plain:*.txt")
         .into_iter()
         .collect::<Vec<Glob>>();
      // No case-sensitive match for FILE.TXT, so the folded pass catches it.
      assert_eq!(
         best_matches(&globs, "FILE.TXT")
            .first()
            .map(|m| m.0.as_str()),
         Some("text/plain")
      );
   }
}
