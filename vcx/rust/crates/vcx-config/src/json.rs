//! A JSON document that writes back the bytes it read: key order, number text and string escapes are kept, and a
//! value set anew is written the way the file's own writer writes it (Swift's `JSONEncoder` or Python's `json.dump`).
//! serde_json cannot do this without `preserve_order` and `arbitrary_precision`, which would change every crate of
//! the workspace through feature unification.

use std::fmt::Write as _;

const MAX_DEPTH: usize = 128;
/// Both `Double.description` (Swift) and `repr` (Python) turn exponential from 1e16 and below 1e-4.
const EXPONENT_FROM: f64 = 1e16;
const EXPONENT_BELOW: f64 = 1e-4;

/// Who wrote the file: the Swift app (`{"a":"x\/y"}`) or `background.py` (`{"a": "x/y"}`, ASCII only).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Style {
    #[default]
    Swift,
    Python,
}

#[derive(Debug, Clone)]
pub enum Json {
    Null,
    Bool(bool),
    Number(Number),
    String(Text),
    Array(Vec<Json>),
    Object(Vec<(Text, Json)>),
}

#[derive(Debug, Clone)]
pub enum Number {
    /// As it stood in the file.
    Raw(String),
    Float(f64),
    Int(i64),
}

#[derive(Debug, Clone)]
pub struct Text {
    value: String,
    /// The text between the quotes in the file, escapes as written; none for a string set anew.
    raw: Option<String>,
}

/// A parsed file: the value, the writer's style and the blank space around the value.
#[derive(Debug, Clone, Default)]
pub struct Document {
    pub root: Json,
    pub style: Style,
    lead: String,
    trail: String,
}

impl Default for Json {
    fn default() -> Self {
        Json::Object(Vec::new())
    }
}

impl Number {
    pub fn as_f64(&self) -> f64 {
        match self {
            Number::Raw(text) => text.parse().unwrap_or(f64::NAN),
            Number::Float(value) => *value,
            Number::Int(value) => *value as f64,
        }
    }
}

impl Text {
    pub fn new(value: impl Into<String>) -> Self {
        Text { value: value.into(), raw: None }
    }

    pub fn as_str(&self) -> &str {
        &self.value
    }
}

impl PartialEq for Text {
    fn eq(&self, other: &Self) -> bool {
        self.value == other.value
    }
}

impl PartialEq for Json {
    /// By meaning: key order, number text and escapes aside.
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Json::Null, Json::Null) => true,
            (Json::Bool(a), Json::Bool(b)) => a == b,
            (Json::Number(a), Json::Number(b)) => a.as_f64() == b.as_f64(),
            (Json::String(a), Json::String(b)) => a == b,
            (Json::Array(a), Json::Array(b)) => a == b,
            (Json::Object(a), Json::Object(b)) => {
                a.len() == b.len() && a.iter().all(|(key, value)| b.iter().any(|(other, found)| key == other && value == found))
            }
            _ => false,
        }
    }
}

impl From<bool> for Json {
    fn from(value: bool) -> Self {
        Json::Bool(value)
    }
}

impl From<&str> for Json {
    fn from(value: &str) -> Self {
        Json::String(Text::new(value))
    }
}

impl From<String> for Json {
    fn from(value: String) -> Self {
        Json::String(Text::new(value))
    }
}

impl From<i64> for Json {
    fn from(value: i64) -> Self {
        Json::Number(Number::Int(value))
    }
}

impl Json {
    /// A finite number; JSON has no other.
    pub fn number(value: f64) -> Option<Json> {
        value.is_finite().then_some(Json::Number(Number::Float(value)))
    }

    pub fn as_str(&self) -> Option<&str> {
        if let Json::String(text) = self { Some(text.as_str()) } else { None }
    }

    pub fn as_f64(&self) -> Option<f64> {
        if let Json::Number(number) = self { Some(number.as_f64()).filter(|value| value.is_finite()) } else { None }
    }

    pub fn as_bool(&self) -> Option<bool> {
        if let Json::Bool(value) = self { Some(*value) } else { None }
    }

    pub fn as_array(&self) -> Option<&[Json]> {
        if let Json::Array(items) = self { Some(items) } else { None }
    }

    pub fn as_array_mut(&mut self) -> Option<&mut Vec<Json>> {
        if let Json::Array(items) = self { Some(items) } else { None }
    }

    /// The object's entries in file order.
    pub fn entries(&self) -> impl Iterator<Item = (&str, &Json)> {
        let entries: &[(Text, Json)] = if let Json::Object(entries) = self { entries } else { &[] };
        entries.iter().map(|(key, value)| (key.as_str(), value))
    }

    pub fn get(&self, key: &str) -> Option<&Json> {
        self.entries().find(|(name, _)| *name == key).map(|(_, value)| value)
    }

    pub fn get_mut(&mut self, key: &str) -> Option<&mut Json> {
        let Json::Object(entries) = self else { return None };
        entries.iter_mut().find(|(name, _)| name.as_str() == key).map(|(_, value)| value)
    }

    /// Replaces the value in its place, or adds the key last. Does nothing on a value that is not an object.
    pub fn set(&mut self, key: &str, value: Json) {
        let Json::Object(entries) = self else { return };
        match entries.iter_mut().find(|(name, _)| name.as_str() == key) {
            Some((_, slot)) => *slot = value,
            None => entries.push((Text::new(key), value)),
        }
    }

    pub fn to_value(&self) -> serde_json::Value {
        use serde_json::Value;
        match self {
            Json::Null => Value::Null,
            Json::Bool(value) => Value::Bool(*value),
            Json::Number(Number::Int(value)) => Value::from(*value),
            Json::Number(number) => {
                if let Number::Raw(text) = number
                    && let Ok(value) = text.parse::<i64>()
                {
                    return Value::from(value);
                }
                serde_json::Number::from_f64(number.as_f64()).map_or(Value::Null, Value::Number)
            }
            Json::String(text) => Value::String(text.value.clone()),
            Json::Array(items) => Value::Array(items.iter().map(Json::to_value).collect()),
            Json::Object(entries) => Value::Object(entries.iter().map(|(key, value)| (key.value.clone(), value.to_value())).collect()),
        }
    }

    pub fn from_value(value: &serde_json::Value) -> Json {
        use serde_json::Value;
        match value {
            Value::Null => Json::Null,
            Value::Bool(value) => Json::Bool(*value),
            Value::Number(number) => match number.as_i64() {
                Some(value) => Json::Number(Number::Int(value)),
                None => Json::Number(Number::Float(number.as_f64().unwrap_or(0.0))),
            },
            Value::String(text) => Json::from(text.as_str()),
            Value::Array(items) => Json::Array(items.iter().map(Json::from_value).collect()),
            Value::Object(entries) => Json::Object(entries.iter().map(|(key, value)| (Text::new(key.as_str()), Json::from_value(value))).collect()),
        }
    }

    pub fn write(&self, style: Style) -> String {
        let mut out = String::new();
        self.write_into(&mut out, style);
        out
    }

    fn write_into(&self, out: &mut String, style: Style) {
        let (comma, colon) = match style {
            Style::Swift => (",", ":"),
            Style::Python => (", ", ": "),
        };
        match self {
            Json::Null => out.push_str("null"),
            Json::Bool(value) => out.push_str(if *value { "true" } else { "false" }),
            Json::Number(Number::Raw(text)) => out.push_str(text),
            Json::Number(Number::Int(value)) => {
                let _ = write!(out, "{value}");
            }
            Json::Number(Number::Float(value)) => out.push_str(&format_float(*value, style)),
            Json::String(text) => write_text(out, text, style),
            Json::Array(items) => {
                out.push('[');
                for (index, item) in items.iter().enumerate() {
                    if index > 0 {
                        out.push_str(comma);
                    }
                    item.write_into(out, style);
                }
                out.push(']');
            }
            Json::Object(entries) => {
                out.push('{');
                for (index, (key, value)) in entries.iter().enumerate() {
                    if index > 0 {
                        out.push_str(comma);
                    }
                    write_text(out, key, style);
                    out.push_str(colon);
                    value.write_into(out, style);
                }
                out.push('}');
            }
        }
    }
}

impl Document {
    pub fn new(root: Json, style: Style) -> Self {
        Document { root, style, lead: String::new(), trail: String::new() }
    }

    pub fn parse(bytes: &[u8]) -> Result<Document, String> {
        let text = std::str::from_utf8(bytes).map_err(|_| "The file is not UTF-8.".to_owned())?;
        let mut parser = Parser { text, at: 0, spaced: None, escaped_slash: false };
        parser.blank();
        let lead = text[..parser.at].to_owned();
        let root = parser.value(0)?;
        let end = parser.at;
        parser.blank();
        if parser.at != text.len() {
            return Err(format!("Unexpected text at byte {}.", parser.at));
        }
        let style = if parser.escaped_slash || parser.spaced == Some(false) {
            Style::Swift
        } else if parser.spaced == Some(true) {
            Style::Python
        } else {
            Style::Swift
        };
        Ok(Document { root, style, lead, trail: text[end..].to_owned() })
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        format!("{}{}{}", self.lead, self.root.write(self.style), self.trail).into_bytes()
    }
}

/// `Double.description` minus its `.0` (Swift's `JSONEncoder`), or `repr` (Python).
pub fn format_float(value: f64, style: Style) -> String {
    let size = value.abs();
    if size >= EXPONENT_FROM || (size != 0.0 && size < EXPONENT_BELOW) {
        let text = format!("{value:e}");
        let (mantissa, exponent) = text.split_once('e').unwrap_or((&text, "0"));
        let exponent: i32 = exponent.parse().unwrap_or(0);
        let sign = if exponent < 0 { '-' } else { '+' };
        return format!("{mantissa}e{sign}{:02}", exponent.abs());
    }
    let text = format!("{value}");
    if style == Style::Python && !text.contains('.') { text + ".0" } else { text }
}

fn write_text(out: &mut String, text: &Text, style: Style) {
    out.push('"');
    if let Some(raw) = &text.raw {
        out.push_str(raw);
    } else {
        for character in text.value.chars() {
            match character {
                '"' => out.push_str("\\\""),
                '\\' => out.push_str("\\\\"),
                '/' if style == Style::Swift => out.push_str("\\/"),
                '\n' => out.push_str("\\n"),
                '\r' => out.push_str("\\r"),
                '\t' => out.push_str("\\t"),
                '\u{8}' => out.push_str("\\b"),
                '\u{c}' => out.push_str("\\f"),
                c if (c as u32) < 0x20 => {
                    let _ = write!(out, "\\u{:04x}", c as u32);
                }
                c if style == Style::Python && !(' '..='~').contains(&c) => {
                    let mut units = [0u16; 2];
                    for unit in c.encode_utf16(&mut units) {
                        let _ = write!(out, "\\u{unit:04x}");
                    }
                }
                c => out.push(c),
            }
        }
    }
    out.push('"');
}

struct Parser<'a> {
    text: &'a str,
    at: usize,
    /// Whether the first `:` of the file is followed by a space.
    spaced: Option<bool>,
    escaped_slash: bool,
}

impl Parser<'_> {
    fn peek(&self) -> Option<u8> {
        self.text.as_bytes().get(self.at).copied()
    }

    fn blank(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.at += 1;
        }
    }

    fn fail<T>(&self, what: &str) -> Result<T, String> {
        Err(format!("{what} at byte {}.", self.at))
    }

    fn expect(&mut self, byte: u8) -> Result<(), String> {
        if self.peek() != Some(byte) {
            return self.fail(&format!("Expected '{}'", byte as char));
        }
        self.at += 1;
        Ok(())
    }

    fn value(&mut self, depth: usize) -> Result<Json, String> {
        if depth > MAX_DEPTH {
            return self.fail("Nested too deep");
        }
        self.blank();
        match self.peek() {
            Some(b'{') => self.object(depth),
            Some(b'[') => self.array(depth),
            Some(b'"') => Ok(Json::String(self.string()?)),
            Some(b't') => self.literal("true", Json::Bool(true)),
            Some(b'f') => self.literal("false", Json::Bool(false)),
            Some(b'n') => self.literal("null", Json::Null),
            Some(b'-' | b'0'..=b'9') => self.number(),
            _ => self.fail("Expected a value"),
        }
    }

    fn literal(&mut self, word: &str, value: Json) -> Result<Json, String> {
        if !self.text[self.at..].starts_with(word) {
            return self.fail("Unknown word");
        }
        self.at += word.len();
        Ok(value)
    }

    fn object(&mut self, depth: usize) -> Result<Json, String> {
        self.at += 1;
        let mut entries = Vec::new();
        self.blank();
        if self.peek() == Some(b'}') {
            self.at += 1;
            return Ok(Json::Object(entries));
        }
        loop {
            self.blank();
            if self.peek() != Some(b'"') {
                return self.fail("Expected a key");
            }
            let key = self.string()?;
            self.blank();
            self.expect(b':')?;
            if self.spaced.is_none() {
                self.spaced = Some(self.peek() == Some(b' '));
            }
            let value = self.value(depth + 1)?;
            entries.push((key, value));
            self.blank();
            match self.peek() {
                Some(b',') => self.at += 1,
                Some(b'}') => {
                    self.at += 1;
                    return Ok(Json::Object(entries));
                }
                _ => return self.fail("Expected ',' or '}'"),
            }
        }
    }

    fn array(&mut self, depth: usize) -> Result<Json, String> {
        self.at += 1;
        let mut items = Vec::new();
        self.blank();
        if self.peek() == Some(b']') {
            self.at += 1;
            return Ok(Json::Array(items));
        }
        loop {
            items.push(self.value(depth + 1)?);
            self.blank();
            match self.peek() {
                Some(b',') => self.at += 1,
                Some(b']') => {
                    self.at += 1;
                    return Ok(Json::Array(items));
                }
                _ => return self.fail("Expected ',' or ']'"),
            }
        }
    }

    fn number(&mut self) -> Result<Json, String> {
        let start = self.at;
        let digits = |parser: &mut Self| {
            let from = parser.at;
            while matches!(parser.peek(), Some(b'0'..=b'9')) {
                parser.at += 1;
            }
            parser.at > from
        };
        if self.peek() == Some(b'-') {
            self.at += 1;
        }
        if self.peek() == Some(b'0') {
            self.at += 1;
        } else if !digits(self) {
            return self.fail("Expected digits");
        }
        if self.peek() == Some(b'.') {
            self.at += 1;
            if !digits(self) {
                return self.fail("Expected digits after '.'");
            }
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.at += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.at += 1;
            }
            if !digits(self) {
                return self.fail("Expected an exponent");
            }
        }
        Ok(Json::Number(Number::Raw(self.text[start..self.at].to_owned())))
    }

    fn hex(&mut self) -> Result<u32, String> {
        let digits = self.text.get(self.at..self.at + 4).filter(|digits| digits.bytes().all(|byte| byte.is_ascii_hexdigit()));
        let Some(digits) = digits else { return self.fail("Expected four hex digits") };
        self.at += 4;
        Ok(u32::from_str_radix(digits, 16).unwrap_or(0))
    }

    fn string(&mut self) -> Result<Text, String> {
        self.at += 1;
        let start = self.at;
        let mut value = String::new();
        let mut plain = self.at;
        loop {
            match self.peek() {
                None => return self.fail("Unterminated string"),
                Some(b'"') => {
                    value.push_str(&self.text[plain..self.at]);
                    let raw = self.text[start..self.at].to_owned();
                    self.at += 1;
                    return Ok(Text { value, raw: Some(raw) });
                }
                Some(byte) if byte < 0x20 => return self.fail("Control character in a string"),
                Some(b'\\') => {
                    value.push_str(&self.text[plain..self.at]);
                    self.at += 1;
                    let escape = self.peek();
                    self.at += 1;
                    match escape {
                        Some(b'"') => value.push('"'),
                        Some(b'\\') => value.push('\\'),
                        Some(b'/') => {
                            value.push('/');
                            self.escaped_slash = true;
                        }
                        Some(b'b') => value.push('\u{8}'),
                        Some(b'f') => value.push('\u{c}'),
                        Some(b'n') => value.push('\n'),
                        Some(b'r') => value.push('\r'),
                        Some(b't') => value.push('\t'),
                        Some(b'u') => value.push(self.unicode()?),
                        _ => return self.fail("Unknown escape"),
                    }
                    plain = self.at;
                }
                Some(_) => self.at += 1,
            }
        }
    }

    fn unicode(&mut self) -> Result<char, String> {
        let unit = self.hex()?;
        let code = if (0xD800..0xDC00).contains(&unit) {
            if !self.text[self.at..].starts_with("\\u") {
                return self.fail("Lone surrogate");
            }
            self.at += 2;
            let low = self.hex()?;
            if !(0xDC00..0xE000).contains(&low) {
                return self.fail("Lone surrogate");
            }
            0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
        } else {
            unit
        };
        match char::from_u32(code) {
            Some(character) => Ok(character),
            None => self.fail("Lone surrogate"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_back_the_bytes_it_read_in_either_style() {
        for text in [
            r#"{"b":"x\/y","a":[1,2.50,-0,1e+16],"c":{"d":null,"e":true},"u":"\u00e9 é \ud83d\ude80"}"#,
            r#"{"b": "x/y", "a": [1, 2.5, 3.0], "u": "\u00e9\t"}"#,
            "  {}\n",
        ] {
            let document = Document::parse(text.as_bytes()).unwrap();

            assert_eq!(String::from_utf8(document.to_bytes()).unwrap(), text);
        }
    }

    #[test]
    fn tells_the_swift_writer_from_the_python_one() {
        let swift = Document::parse(br#"{"a":1}"#).unwrap();
        let python = Document::parse(br#"{"a": 1}"#).unwrap();

        assert_eq!((swift.style, python.style), (Style::Swift, Style::Python));
    }

    #[test]
    fn writes_a_new_string_the_way_each_writer_escapes_it() {
        let value = Json::from("a/b é\u{1}\u{7f} 🚀\"");

        assert_eq!(value.write(Style::Swift), "\"a\\/b é\\u0001\u{7f} 🚀\\\"\"");
        assert_eq!(value.write(Style::Python), "\"a/b \\u00e9\\u0001\\u007f \\ud83d\\ude80\\\"\"");
    }

    #[test]
    fn writes_a_new_number_the_way_each_writer_prints_it() {
        let cases = [(1e16, "1e+16", "1e+16"), (9007199254740992.0, "9007199254740992", "9007199254740992.0"), (1e-5, "1e-05", "1e-05"), (0.0001, "0.0001", "0.0001"), (3.0, "3", "3.0"), (-0.0, "-0", "-0.0"), (1e300, "1e+300", "1e+300"), (-2.5e-7, "-2.5e-07", "-2.5e-07"), (1764095623.512978, "1764095623.512978", "1764095623.512978")];

        let swift: Vec<String> = cases.iter().map(|case| format_float(case.0, Style::Swift)).collect();
        let python: Vec<String> = cases.iter().map(|case| format_float(case.0, Style::Python)).collect();

        assert_eq!(swift, cases.iter().map(|case| case.1).collect::<Vec<_>>());
        assert_eq!(python, cases.iter().map(|case| case.2).collect::<Vec<_>>());
    }

    #[test]
    fn refuses_what_is_not_json() {
        for text in ["{", "{\"a\":}", "[1,]", "\"\\ud800\"", "01", "{} x", "\"a\u{1}\""] {
            assert!(Document::parse(text.as_bytes()).is_err(), "{text}");
        }
    }

    #[test]
    fn replaces_a_value_in_place_and_adds_a_new_key_last() {
        let mut document = Document::parse(br#"{"a":1,"b":2}"#).unwrap();

        document.root.set("a", Json::from(true));
        document.root.set("c", Json::from("x"));

        assert_eq!(String::from_utf8(document.to_bytes()).unwrap(), r#"{"a":true,"b":2,"c":"x"}"#);
    }

    #[test]
    fn stops_at_a_depth_no_settings_file_reaches() {
        let deep = "[".repeat(MAX_DEPTH + 2) + &"]".repeat(MAX_DEPTH + 2);

        assert!(Document::parse(deep.as_bytes()).is_err());
    }
}
