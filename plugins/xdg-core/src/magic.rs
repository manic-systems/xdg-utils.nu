//! Parser and matcher for the freedesktop shared-mime-info `magic` database.
//!
//! The on-disk format (`<datadir>/mime/magic`) begins with the literal
//! `MIME-Magic\0\n` followed by a sequence of sections.
//!
//! ```text
//! [<priority>:<mimetype>]\n
//! [indent]>offset=<2-byte big-endian length><value>[&<mask>][~<word-size>][+<range>]\n
//! ...
//! ```
//!
//! Match lines use indentation to form a tree. A section matches when every
//! rule along at least one path succeeds.
//!
//! Multi-byte words are converted from big endian to host order while parsing,
//! which keeps matching to a plain slice comparison.

use std::cmp;

use crate::diagnostic::{
   Diagnostic,
   Parsed,
};

/// One parsed magic match line, with value/mask pre-swapped to host order.
#[derive(Debug, Clone)]
struct Rule {
   indent: u32,
   offset: usize,
   value:  Vec<u8>,
   mask:   Option<Vec<u8>>,
   /// Number of extra start offsets to scan past `offset` (range length).
   range:  usize,
}

impl Rule {
   /// The last data byte this rule can touch (for sizing content reads).
   const fn extent(&self) -> usize {
      self.offset + self.range + self.value.len()
   }

   /// Test this rule against `data`, scanning its range.
   fn matches(&self, data: &[u8]) -> bool {
      let len = self.value.len();
      if len == 0 {
         return false;
      }
      for delta in 0..=self.range {
         let start = self.offset + delta;
         let Some(window) = data.get(start..start + len) else {
            break; // past end of data
         };
         let hit = match &self.mask {
            Some(m) => {
               window
                  .iter()
                  .zip(&self.value)
                  .zip(m)
                  .all(|((d, v), msk)| (d & msk) == (v & msk))
            },
            None => window == self.value.as_slice(),
         };
         if hit {
            return true;
         }
      }
      false
   }
}

/// A `[priority:mimetype]` section with its flat list of indented rules.
#[derive(Debug, Clone)]
struct Section {
   priority: u32,
   mime:     String,
   rules:    Vec<Rule>,
}

impl Section {
   /// A section matches if some root rule (indent 0) matches and, recursively,
   /// a matching path continues through its deeper-indented children.
   fn matches(&self, data: &[u8]) -> bool {
      matches_from(&self.rules, 0, 0, data)
   }
}

/// The whole parsed magic database, sections sorted by descending priority.
#[derive(Debug, Clone, Default)]
pub struct MagicDb {
   sections: Vec<Section>,
}

impl MagicDb {
   const HEADER: &'static [u8] = b"MIME-Magic\0\n";

   /// Parse one `magic` file's bytes, reporting malformed sections/rules as
   /// diagnostics instead of silently bailing. A bad header yields an empty db
   /// with one error.
   #[must_use]
   pub fn parse(bytes: &[u8]) -> Parsed<Self> {
      let mut db = Self::default();
      let mut diagnostics = Vec::new();
      if !bytes.starts_with(Self::HEADER) {
         diagnostics.push(Diagnostic::error(
            "not a magic database (bad MIME-Magic header)",
         ));
         return Parsed {
            value: db,
            diagnostics,
         };
      }

      let mut p = Self::HEADER.len();
      let n = bytes.len();
      let mut current = None::<Section>;

      while p < n {
         if bytes[p] == b'[' {
            if let Some(sec) = current.take() {
               db.sections.push(sec);
            }
            // The header ends at the newline.
            let line_end = memchr(bytes, p, b'\n').unwrap_or(n);
            let close = memchr(&bytes[..line_end], p, b']');
            match close {
               Some(end) => {
                  current = parse_section_header(&bytes[p + 1..end], &mut diagnostics);
               },
               None => {
                  diagnostics.push(Diagnostic::error("section header missing closing ']'"));
               },
            }
            p = line_end + 1;
            continue;
         }

         match parse_rule(bytes, &mut p, &mut diagnostics) {
            RuleLine::Rule(rule) => {
               if let Some(sec) = current.as_mut() {
                  sec.rules.push(rule);
               } else {
                  diagnostics.push(Diagnostic::error("magic rule before any section header"));
               }
            },
            RuleLine::Skip => {
               // Resume at the next line so later rules can still be parsed.
               p = memchr(bytes, p, b'\n').map_or(n, |i| i + 1);
            },
            RuleLine::Abort => break, // The diagnostic already explains the lost framing.
         }
      }
      if let Some(sec) = current.take() {
         db.sections.push(sec);
      }
      db.sections.sort_by_key(|s| cmp::Reverse(s.priority));
      Parsed {
         value: db,
         diagnostics,
      }
   }

   /// Fold another database's sections into this one, re-sorting by priority.
   pub fn merge(&mut self, other: Self) {
      self.sections.extend(other.sections);
      self.sections.sort_by_key(|s| cmp::Reverse(s.priority));
   }

   /// The highest-priority mimetype whose magic matches `data`, with its
   /// priority. Sections are pre-sorted, so the first match wins.
   #[must_use]
   pub fn match_data(&self, data: &[u8]) -> Option<(String, u32)> {
      self
         .sections
         .iter()
         .find(|sec| sec.matches(data))
         .map(|sec| (sec.mime.clone(), sec.priority))
   }

   /// The greatest data offset any rule can inspect. This bounds how much file
   /// content MIME detection needs to read.
   pub fn max_extent(&self) -> usize {
      self
         .sections
         .iter()
         .flat_map(|s| s.rules.iter())
         .map(Rule::extent)
         .max()
         .unwrap_or(0)
   }
}

/// Parse the `priority:mime` text between the header brackets.
fn parse_section_header(header: &[u8], diagnostics: &mut Vec<Diagnostic>) -> Option<Section> {
   let colon = header.iter().position(|&b| b == b':')?;
   let priority = if let Some(p) = std::str::from_utf8(&header[..colon])
      .ok()
      .and_then(|s| s.parse::<u32>().ok())
   {
      p
   } else {
      diagnostics.push(Diagnostic::warning(
         "magic section has a non-numeric priority; using 50",
      ));
      50
   };
   let mime = String::from_utf8_lossy(&header[colon + 1..]).into_owned();
   Some(Section {
      priority,
      mime,
      rules: Vec::new(),
   })
}

/// The outcome of parsing one rule line.
enum RuleLine {
   Rule(Rule),
   /// Malformed textual data that can resume at the next line.
   Skip,
   /// A binary framing error after which the cursor cannot be trusted.
   Abort,
}

/// Parse one rule at `*p` and advance past its newline. Failures are recorded
/// as diagnostics, with [`RuleLine`] describing whether parsing can continue.
fn parse_rule(bytes: &[u8], p: &mut usize, diagnostics: &mut Vec<Diagnostic>) -> RuleLine {
   let n = bytes.len();
   let line_start = *p;

   let indent = read_decimal(bytes, p).unwrap_or(0) as u32;
   if *p >= n || bytes[*p] != b'>' {
      diagnostics.push(Diagnostic::error(
         "magic rule missing '>' after indent; line skipped",
      ));
      return RuleLine::Skip;
   }
   *p += 1; // '>'

   let Some(offset) = read_decimal(bytes, p) else {
      diagnostics.push(Diagnostic::error("magic rule missing offset; line skipped"));
      return RuleLine::Skip;
   };
   let offset = offset as usize;
   if *p >= n || bytes[*p] != b'=' {
      diagnostics.push(Diagnostic::error(
         "magic rule missing '=' after offset; line skipped",
      ));
      return RuleLine::Skip;
   }
   *p += 1; // '='

   // 2-byte big-endian value length.
   if *p + 2 > n {
      diagnostics.push(Diagnostic::error("magic rule truncated at value length"));
      return RuleLine::Abort;
   }
   let len = ((bytes[*p] as usize) << 8_u32) | bytes[*p + 1] as usize;
   *p += 2;
   if *p + len > n {
      diagnostics.push(Diagnostic::error("magic rule value length exceeds file"));
      return RuleLine::Abort;
   }
   let raw_value = &bytes[*p..*p + len];
   *p += len;

   let mut raw_mask = None::<&[u8]>;
   let mut range = 0_usize;
   let mut word_size = 1_usize;

   if *p < n && bytes[*p] == b'&' {
      *p += 1;
      if *p + len > n {
         diagnostics.push(Diagnostic::error("magic rule mask length exceeds file"));
         return RuleLine::Abort;
      }
      raw_mask = Some(&bytes[*p..*p + len]);
      *p += len;
   }
   if *p < n && bytes[*p] == b'~' {
      *p += 1;
      word_size = read_decimal(bytes, p).unwrap_or(1) as usize;
   }
   if *p < n && bytes[*p] == b'+' {
      *p += 1;
      range = read_decimal(bytes, p).unwrap_or(0) as usize;
   }

   // Skip any trailing junk to end of line.
   while *p < n && bytes[*p] != b'\n' {
      *p += 1;
   }
   if *p < n {
      *p += 1; // consume newline
   }
   debug_assert!(*p > line_start, "rule parse must advance");

   let word_size = word_size.max(1);
   RuleLine::Rule(Rule {
      indent,
      offset,
      value: byteswap_words(raw_value, word_size),
      mask: raw_mask.map(|m| byteswap_words(m, word_size)),
      range,
   })
}

/// Match one sibling at `level` together with any child rules beneath it.
fn matches_from(rules: &[Rule], start: usize, level: u32, data: &[u8]) -> bool {
   let mut i = start;
   while i < rules.len() {
      let rule = &rules[i];
      if rule.indent < level {
         break;
      }
      if rule.indent == level && rule.matches(data) {
         let child_start = i + 1;
         let has_children = rules.get(child_start).is_some_and(|c| c.indent > level);
         if !has_children || matches_from(rules, child_start, level + 1, data) {
            return true;
         }
      }
      i += 1;
   }
   false
}

/// On a little-endian host, reverse each `word`-sized group (the db is
/// big-endian). `word <= 1` (or a big-endian host) is a straight copy.
fn byteswap_words(bytes: &[u8], word: usize) -> Vec<u8> {
   let mut out = bytes.to_vec();
   if word > 1 && cfg!(target_endian = "little") {
      for chunk in out.chunks_mut(word) {
         chunk.reverse();
      }
   }
   out
}

/// Read consecutive ASCII digits starting at `*p`, advancing past them.
fn read_decimal(bytes: &[u8], p: &mut usize) -> Option<u64> {
   let start = *p;
   while *p < bytes.len() && bytes[*p].is_ascii_digit() {
      *p += 1;
   }
   if *p == start {
      return None;
   }
   std::str::from_utf8(&bytes[start..*p]).ok()?.parse().ok()
}

fn memchr(bytes: &[u8], from: usize, needle: u8) -> Option<usize> {
   bytes[from..]
      .iter()
      .position(|&b| b == needle)
      .map(|i| from + i)
}

#[cfg(test)]
mod tests {
   use super::*;

   /// Test rule fields in parser order.
   type TestRule<'a> = (u32, usize, &'a [u8], Option<&'a [u8]>, usize, usize);
   /// Test section fields in parser order.
   type TestSection<'a> = (u32, &'a str, &'a [TestRule<'a>]);

   /// Build a magic file from the given sections.
   fn build(sections: &[TestSection]) -> Vec<u8> {
      let mut out = MagicDb::HEADER.to_vec();
      for (prio, mime, rules) in sections {
         out.extend(format!("[{prio}:{mime}]\n").bytes());
         for (indent, offset, value, mask, range, word) in *rules {
            if *indent > 0 {
               out.extend(indent.to_string().bytes());
            }
            out.push(b'>');
            out.extend(offset.to_string().bytes());
            out.push(b'=');
            out.push((value.len() >> 8_u32) as u8);
            out.push((value.len() & 0xFF) as u8);
            out.extend_from_slice(value);
            if let Some(m) = mask {
               out.push(b'&');
               out.extend_from_slice(m);
            }
            if *word > 1 {
               out.push(b'~');
               out.extend(word.to_string().bytes());
            }
            if *range > 0 {
               out.push(b'+');
               out.extend(range.to_string().bytes());
            }
            out.push(b'\n');
         }
      }
      out
   }

   #[test]
   fn matches_simple_signature() {
      let db = MagicDb::parse(&build(&[(50, "image/png", &[(
         0,
         0,
         &[0x89, b'P', b'N', b'G'],
         None,
         0,
         1,
      )])]))
      .value;
      assert_eq!(
         db.match_data(&[0x89, b'P', b'N', b'G', 0x0D]),
         Some(("image/png".to_owned(), 50))
      );
      assert_eq!(db.match_data(b"not png"), None);
   }

   #[test]
   fn indent_tree_requires_child_path() {
      // The root matches "AB" and its child requires "CD" at offset 2.
      let bytes = build(&[(60, "x/test", &[
         (0, 0, b"AB", None, 0, 1),
         (1, 2, b"CD", None, 0, 1),
      ])]);
      let db = MagicDb::parse(&bytes).value;
      assert_eq!(db.match_data(b"ABCD"), Some(("x/test".to_owned(), 60)));
      // root matches but child does not → no match.
      assert_eq!(db.match_data(b"ABXX"), None);
   }

   #[test]
   fn range_and_mask() {
      // value "ID3" allowed to start anywhere in offset 0..=3.
      let db = MagicDb::parse(&build(&[(50, "audio/mpeg", &[(0, 0, b"ID3", None, 3, 1)])])).value;
      assert_eq!(
         db.match_data(b"\x00\x00ID3xx").map(|m| m.0),
         Some("audio/mpeg".to_owned())
      );
      // Only the high nibble of the first byte matters.
      let db = MagicDb::parse(&build(&[(50, "x/masked", &[(
         0,
         0,
         &[0xF0],
         Some(&[0xF0]),
         0,
         1,
      )])]))
      .value;
      assert_eq!(
         db.match_data(&[0xFA]).map(|m| m.0),
         Some("x/masked".to_owned())
      );
      assert_eq!(db.match_data(&[0x0A]), None);
   }

   #[test]
   fn word_byteswap_matches_host_order_data() {
      // A `~2` word stores 0xFEFF in big endian and matches host-order data.
      let db = MagicDb::parse(&build(&[(50, "x/utf16", &[(
         0,
         0,
         &[0xFE, 0xFF],
         None,
         0,
         2,
      )])]))
      .value;
      let host_order = if cfg!(target_endian = "little") {
         [0xFF, 0xFE]
      } else {
         [0xFE, 0xFF]
      };
      assert_eq!(
         db.match_data(&host_order).map(|m| m.0),
         Some("x/utf16".to_owned())
      );
   }

   #[test]
   fn priority_orders_matches_and_max_extent() {
      let db = MagicDb::parse(&build(&[
         (40, "x/low", &[(0, 0, b"AA", None, 0, 1)]),
         (80, "x/high", &[(0, 0, b"AA", None, 0, 1)]),
      ]))
      .value;
      assert_eq!(db.match_data(b"AA"), Some(("x/high".to_owned(), 80)));
      assert_eq!(db.max_extent(), 2);
   }

   #[test]
   fn malformed_textual_rule_is_skipped_not_fatal() {
      let mut bytes = build(&[(50, "x/first", &[(0, 0, b"AA", None, 0, 1)])]);
      bytes.extend(b"[50:x/bad]\nthis is not a rule line\n");
      let second = build(&[(50, "x/second", &[(0, 0, b"BB", None, 0, 1)])]);
      bytes.extend(&second[MagicDb::HEADER.len()..]);

      let parsed = MagicDb::parse(&bytes);
      assert!(
         parsed
            .diagnostics
            .iter()
            .any(|d| d.message.contains("skipped"))
      );
      // Sections after the malformed line still load and match.
      assert_eq!(
         parsed.value.match_data(b"AA").map(|m| m.0),
         Some("x/first".to_owned())
      );
      assert_eq!(
         parsed.value.match_data(b"BB").map(|m| m.0),
         Some("x/second".to_owned())
      );
   }

   #[test]
   fn bad_header_reports_diagnostic() {
      let parsed = MagicDb::parse(b"garbage");
      assert!(parsed.value.match_data(b"anything").is_none());
      assert!(
         parsed
            .diagnostics
            .iter()
            .any(|d| d.message.contains("header"))
      );
   }
}
