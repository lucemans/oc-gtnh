//! OpenOS serialization as a serde format.
//!
//! What `serialization.serialize` writes in the game is a Lua table literal:
//! `{kind="chat",player="Steve",seq=4}`. What `serialization.unserialize`
//! reads is anything `load("return " .. text)` accepts. Both ends of this file
//! stay inside the subset the OpenOS library itself produces: nil, booleans,
//! integers, floats, quoted strings with backslash escapes, and tables whose
//! keys are identifiers, `["strings"]` or `[numbers]`.
//!
//! A table with only the keys 1..n reads as a sequence; anything else reads as
//! a map with every key spelled as a string, which is what a struct wants.

use std::fmt::Write as _;

use serde::de::{self, DeserializeOwned, IntoDeserializer, Visitor};
use serde::ser::{self, Serialize};

#[derive(Debug)]
pub struct Error(String);

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

impl ser::Error for Error {
    fn custom<T: std::fmt::Display>(msg: T) -> Self {
        Error(msg.to_string())
    }
}

impl de::Error for Error {
    fn custom<T: std::fmt::Display>(msg: T) -> Self {
        Error(msg.to_string())
    }
}

type Result<T> = std::result::Result<T, Error>;

// ---------------------------------------------------------------------------
// reading

/// One Lua value as the game writes it. Strings are bytes, since a Lua string
/// is bytes and a script's output need not be UTF-8.
#[derive(Debug, Clone, PartialEq)]
pub enum Lua {
    Nil,
    Bool(bool),
    Int(i64),
    Float(f64),
    Str(Vec<u8>),
    Table(Vec<(Lua, Lua)>),
}

struct Parser<'a> {
    text: &'a [u8],
    at: usize,
}

const KEYWORDS: [&str; 22] = [
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in",
    "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
];

fn is_identifier(text: &str) -> bool {
    let mut chars = text.chars();
    match chars.next() {
        Some(first) if first.is_ascii_alphabetic() || first == '_' => {}
        _ => return false,
    }
    chars.all(|c| c.is_ascii_alphanumeric() || c == '_') && !KEYWORDS.contains(&text)
}

impl<'a> Parser<'a> {
    fn peek(&self) -> Option<u8> {
        self.text.get(self.at).copied()
    }

    fn skip_space(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.at += 1;
        }
    }

    fn expect(&mut self, byte: u8) -> Result<()> {
        self.skip_space();
        if self.peek() == Some(byte) {
            self.at += 1;
            Ok(())
        } else {
            Err(Error(format!(
                "expected '{}' at byte {}",
                byte as char, self.at
            )))
        }
    }

    fn word(&mut self) -> &'a str {
        let start = self.at;
        while matches!(self.peek(), Some(c) if c.is_ascii_alphanumeric() || c == b'_' || c == b'.')
        {
            self.at += 1;
        }
        std::str::from_utf8(&self.text[start..self.at]).unwrap_or("")
    }

    fn value(&mut self) -> Result<Lua> {
        self.skip_space();
        match self.peek() {
            None => Err(Error("unexpected end".into())),
            Some(b'{') => self.table(),
            Some(b'"') | Some(b'\'') => self.string().map(Lua::Str),
            Some(b'-') | Some(b'0'..=b'9') => self.number(),
            Some(_) => {
                let word = self.word();
                match word {
                    "nil" => Ok(Lua::Nil),
                    "true" => Ok(Lua::Bool(true)),
                    "false" => Ok(Lua::Bool(false)),
                    "math.huge" => Ok(Lua::Float(f64::INFINITY)),
                    "" => Err(Error(format!("unexpected byte at {}", self.at))),
                    other => Err(Error(format!("unexpected word {other}"))),
                }
            }
        }
    }

    fn number(&mut self) -> Result<Lua> {
        let start = self.at;
        if self.peek() == Some(b'-') {
            self.at += 1;
            self.skip_space();
            if self.text[self.at..].starts_with(b"math.huge") {
                self.at += "math.huge".len();
                return Ok(Lua::Float(f64::NEG_INFINITY));
            }
        }
        while matches!(
            self.peek(),
            Some(c) if c.is_ascii_hexdigit() || matches!(c, b'.' | b'x' | b'X' | b'p' | b'P' | b'+' | b'-' | b'e' | b'E')
        ) {
            // a sign only continues an exponent
            if matches!(self.peek(), Some(b'+' | b'-'))
                && !matches!(self.text.get(self.at - 1), Some(b'e' | b'E' | b'p' | b'P'))
            {
                break;
            }
            self.at += 1;
        }
        let raw = std::str::from_utf8(&self.text[start..self.at]).unwrap_or("");
        if raw == "0" && self.text[self.at..].starts_with(b"/0") {
            self.at += 2;
            return Ok(Lua::Float(f64::NAN));
        }
        if let Ok(int) = raw.parse::<i64>() {
            return Ok(Lua::Int(int));
        }
        if let Some(hex) = raw.strip_prefix("0x").or_else(|| raw.strip_prefix("0X")) {
            if let Ok(int) = i64::from_str_radix(hex, 16) {
                return Ok(Lua::Int(int));
            }
        }
        raw.parse::<f64>()
            .map(Lua::Float)
            .map_err(|_| Error(format!("not a number: {raw}")))
    }

    fn string(&mut self) -> Result<Vec<u8>> {
        let quote = self.peek().expect("checked by caller");
        self.at += 1;
        let mut out = Vec::new();
        loop {
            let byte = self
                .peek()
                .ok_or_else(|| Error("unterminated string".into()))?;
            self.at += 1;
            if byte == quote {
                return Ok(out);
            }
            if byte != b'\\' {
                out.push(byte);
                continue;
            }
            let escaped = self
                .peek()
                .ok_or_else(|| Error("unterminated escape".into()))?;
            self.at += 1;
            match escaped {
                b'n' => out.push(b'\n'),
                b'r' => out.push(b'\r'),
                b't' => out.push(b'\t'),
                b'a' => out.push(7),
                b'b' => out.push(8),
                b'f' => out.push(12),
                b'v' => out.push(11),
                b'\\' => out.push(b'\\'),
                b'"' => out.push(b'"'),
                b'\'' => out.push(b'\''),
                b'\n' => out.push(b'\n'),
                b'x' => {
                    let hex = self
                        .text
                        .get(self.at..self.at + 2)
                        .ok_or_else(|| Error("short \\x".into()))?;
                    let text = std::str::from_utf8(hex).map_err(|_| Error("bad \\x".into()))?;
                    out.push(u8::from_str_radix(text, 16).map_err(|_| Error("bad \\x".into()))?);
                    self.at += 2;
                }
                b'z' => self.skip_space(),
                b'0'..=b'9' => {
                    let mut value: u32 = u32::from(escaped - b'0');
                    for _ in 0..2 {
                        match self.peek() {
                            Some(digit @ b'0'..=b'9') => {
                                value = value * 10 + u32::from(digit - b'0');
                                self.at += 1;
                            }
                            _ => break,
                        }
                    }
                    out.push(u8::try_from(value).map_err(|_| Error("escape over 255".into()))?);
                }
                other => return Err(Error(format!("unknown escape \\{}", other as char))),
            }
        }
    }

    fn table(&mut self) -> Result<Lua> {
        self.expect(b'{')?;
        let mut entries = Vec::new();
        let mut next_index: i64 = 1;
        loop {
            self.skip_space();
            match self.peek() {
                Some(b'}') => {
                    self.at += 1;
                    return Ok(Lua::Table(entries));
                }
                Some(b'[') => {
                    self.at += 1;
                    let key = self.value()?;
                    self.expect(b']')?;
                    self.expect(b'=')?;
                    let value = self.value()?;
                    entries.push((key, value));
                }
                Some(c) if c.is_ascii_alphabetic() || c == b'_' => {
                    let start = self.at;
                    let word = self.word().to_string();
                    self.skip_space();
                    if self.peek() == Some(b'=') && is_identifier(&word) {
                        self.at += 1;
                        let value = self.value()?;
                        entries.push((Lua::Str(word.into_bytes()), value));
                    } else {
                        self.at = start;
                        let value = self.value()?;
                        entries.push((Lua::Int(next_index), value));
                        next_index += 1;
                    }
                }
                Some(_) => {
                    let value = self.value()?;
                    entries.push((Lua::Int(next_index), value));
                    next_index += 1;
                }
                None => return Err(Error("unterminated table".into())),
            }
            self.skip_space();
            match self.peek() {
                Some(b',') | Some(b';') => self.at += 1,
                Some(b'}') => {}
                _ => return Err(Error(format!("expected ',' or '}}' at byte {}", self.at))),
            }
        }
    }
}

pub fn parse(text: &[u8]) -> Result<Lua> {
    let mut parser = Parser { text, at: 0 };
    let value = parser.value()?;
    parser.skip_space();
    if parser.at != text.len() {
        return Err(Error(format!("trailing text at byte {}", parser.at)));
    }
    Ok(value)
}

impl Lua {
    fn is_sequence(entries: &[(Lua, Lua)]) -> bool {
        !entries.is_empty()
            && entries
                .iter()
                .enumerate()
                .all(|(index, (key, _))| *key == Lua::Int(index as i64 + 1))
    }

    fn key_text(&self) -> String {
        match self {
            Lua::Str(bytes) => String::from_utf8_lossy(bytes).into_owned(),
            Lua::Int(int) => int.to_string(),
            Lua::Float(float) => float.to_string(),
            Lua::Bool(b) => b.to_string(),
            Lua::Nil => "nil".to_string(),
            Lua::Table(_) => "table".to_string(),
        }
    }
}

impl<'de> de::Deserializer<'de> for Lua {
    type Error = Error;

    fn deserialize_any<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        match self {
            Lua::Nil => visitor.visit_unit(),
            Lua::Bool(b) => visitor.visit_bool(b),
            Lua::Int(int) => visitor.visit_i64(int),
            Lua::Float(float) => visitor.visit_f64(float),
            // lossy on purpose: a script's output is whatever bytes it printed,
            // and the reader wants text
            Lua::Str(bytes) => visitor.visit_string(String::from_utf8_lossy(&bytes).into_owned()),
            Lua::Table(entries) => {
                if Lua::is_sequence(&entries) {
                    let values: Vec<Lua> = entries.into_iter().map(|(_, v)| v).collect();
                    visitor.visit_seq(de::value::SeqDeserializer::new(values.into_iter()))
                } else {
                    let pairs: Vec<(String, Lua)> = entries
                        .into_iter()
                        .map(|(k, v)| (k.key_text(), v))
                        .collect();
                    visitor.visit_map(de::value::MapDeserializer::new(pairs.into_iter()))
                }
            }
        }
    }

    fn deserialize_option<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        match self {
            Lua::Nil => visitor.visit_none(),
            other => visitor.visit_some(other),
        }
    }

    fn deserialize_unit<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        visitor.visit_unit()
    }

    fn deserialize_newtype_struct<V: Visitor<'de>>(
        self,
        _name: &'static str,
        visitor: V,
    ) -> Result<V::Value> {
        visitor.visit_newtype_struct(self)
    }

    fn deserialize_enum<V: Visitor<'de>>(
        self,
        _name: &'static str,
        _variants: &'static [&'static str],
        visitor: V,
    ) -> Result<V::Value> {
        match self {
            Lua::Str(bytes) => visitor.visit_enum(
                String::from_utf8_lossy(&bytes)
                    .into_owned()
                    .into_deserializer(),
            ),
            other => other.deserialize_any(visitor),
        }
    }

    serde::forward_to_deserialize_any! {
        bool i8 i16 i32 i64 i128 u8 u16 u32 u64 u128 f32 f64 char str string
        bytes byte_buf unit_struct seq tuple tuple_struct map struct identifier
        ignored_any
    }
}

impl<'de> IntoDeserializer<'de, Error> for Lua {
    type Deserializer = Lua;

    fn into_deserializer(self) -> Lua {
        self
    }
}

pub fn from_lua<T: DeserializeOwned>(value: Lua) -> Result<T> {
    T::deserialize(value)
}

pub fn from_bytes<T: DeserializeOwned>(text: &[u8]) -> Result<T> {
    from_lua(parse(text)?)
}

// ---------------------------------------------------------------------------
// writing

fn quote(out: &mut String, text: &str) {
    out.push('"');
    for byte in text.bytes() {
        match byte {
            b'"' => out.push_str("\\\""),
            b'\\' => out.push_str("\\\\"),
            b'\n' => out.push_str("\\n"),
            b'\r' => out.push_str("\\r"),
            0..=31 | 127 => {
                let _ = write!(out, "\\{byte:03}");
            }
            // a byte is a byte to Lua, so UTF-8 passes through unescaped
            _ => out.push(byte as char),
        }
    }
    out.push('"');
}

pub struct Serializer {
    out: String,
}

pub struct Compound<'a> {
    ser: &'a mut Serializer,
    first: bool,
}

impl Compound<'_> {
    fn comma(&mut self) {
        if !self.first {
            self.ser.out.push(',');
        }
        self.first = false;
    }
}

impl<'a> ser::Serializer for &'a mut Serializer {
    type Ok = ();
    type Error = Error;
    type SerializeSeq = Compound<'a>;
    type SerializeTuple = Compound<'a>;
    type SerializeTupleStruct = Compound<'a>;
    type SerializeTupleVariant = Compound<'a>;
    type SerializeMap = Compound<'a>;
    type SerializeStruct = Compound<'a>;
    type SerializeStructVariant = Compound<'a>;

    fn serialize_bool(self, v: bool) -> Result<()> {
        self.out.push_str(if v { "true" } else { "false" });
        Ok(())
    }
    fn serialize_i8(self, v: i8) -> Result<()> {
        self.serialize_i64(i64::from(v))
    }
    fn serialize_i16(self, v: i16) -> Result<()> {
        self.serialize_i64(i64::from(v))
    }
    fn serialize_i32(self, v: i32) -> Result<()> {
        self.serialize_i64(i64::from(v))
    }
    fn serialize_i64(self, v: i64) -> Result<()> {
        let _ = write!(self.out, "{v}");
        Ok(())
    }
    fn serialize_u8(self, v: u8) -> Result<()> {
        self.serialize_i64(i64::from(v))
    }
    fn serialize_u16(self, v: u16) -> Result<()> {
        self.serialize_i64(i64::from(v))
    }
    fn serialize_u32(self, v: u32) -> Result<()> {
        self.serialize_i64(i64::from(v))
    }
    fn serialize_u64(self, v: u64) -> Result<()> {
        let _ = write!(self.out, "{v}");
        Ok(())
    }
    fn serialize_f32(self, v: f32) -> Result<()> {
        self.serialize_f64(f64::from(v))
    }
    fn serialize_f64(self, v: f64) -> Result<()> {
        if v.is_nan() {
            self.out.push_str("0/0");
        } else if v == f64::INFINITY {
            self.out.push_str("math.huge");
        } else if v == f64::NEG_INFINITY {
            self.out.push_str("-math.huge");
        } else if v.fract() == 0.0 && v.abs() < 1e15 {
            let _ = write!(self.out, "{v:.1}");
        } else {
            let _ = write!(self.out, "{v}");
        }
        Ok(())
    }
    fn serialize_char(self, v: char) -> Result<()> {
        self.serialize_str(&v.to_string())
    }
    fn serialize_str(self, v: &str) -> Result<()> {
        quote(&mut self.out, v);
        Ok(())
    }
    fn serialize_bytes(self, v: &[u8]) -> Result<()> {
        self.out.push('"');
        for byte in v {
            match byte {
                b'"' => self.out.push_str("\\\""),
                b'\\' => self.out.push_str("\\\\"),
                32..=126 => self.out.push(*byte as char),
                _ => {
                    let _ = write!(self.out, "\\{byte:03}");
                }
            }
        }
        self.out.push('"');
        Ok(())
    }
    fn serialize_none(self) -> Result<()> {
        self.out.push_str("nil");
        Ok(())
    }
    fn serialize_some<T: ?Sized + Serialize>(self, value: &T) -> Result<()> {
        value.serialize(self)
    }
    fn serialize_unit(self) -> Result<()> {
        self.serialize_none()
    }
    fn serialize_unit_struct(self, _name: &'static str) -> Result<()> {
        self.serialize_none()
    }
    fn serialize_unit_variant(
        self,
        _name: &'static str,
        _index: u32,
        variant: &'static str,
    ) -> Result<()> {
        self.serialize_str(variant)
    }
    fn serialize_newtype_struct<T: ?Sized + Serialize>(
        self,
        _name: &'static str,
        value: &T,
    ) -> Result<()> {
        value.serialize(self)
    }
    fn serialize_newtype_variant<T: ?Sized + Serialize>(
        self,
        _name: &'static str,
        _index: u32,
        variant: &'static str,
        value: &T,
    ) -> Result<()> {
        self.out.push('{');
        self.out.push_str(variant);
        self.out.push('=');
        value.serialize(&mut *self)?;
        self.out.push('}');
        Ok(())
    }
    fn serialize_seq(self, _len: Option<usize>) -> Result<Compound<'a>> {
        self.out.push('{');
        Ok(Compound {
            ser: self,
            first: true,
        })
    }
    fn serialize_tuple(self, len: usize) -> Result<Compound<'a>> {
        self.serialize_seq(Some(len))
    }
    fn serialize_tuple_struct(self, _name: &'static str, len: usize) -> Result<Compound<'a>> {
        self.serialize_seq(Some(len))
    }
    fn serialize_tuple_variant(
        self,
        _name: &'static str,
        _index: u32,
        variant: &'static str,
        _len: usize,
    ) -> Result<Compound<'a>> {
        self.out.push('{');
        self.out.push_str(variant);
        self.out.push_str("={");
        Ok(Compound {
            ser: self,
            first: true,
        })
    }
    fn serialize_map(self, _len: Option<usize>) -> Result<Compound<'a>> {
        self.out.push('{');
        Ok(Compound {
            ser: self,
            first: true,
        })
    }
    fn serialize_struct(self, _name: &'static str, _len: usize) -> Result<Compound<'a>> {
        self.out.push('{');
        Ok(Compound {
            ser: self,
            first: true,
        })
    }
    fn serialize_struct_variant(
        self,
        _name: &'static str,
        _index: u32,
        variant: &'static str,
        _len: usize,
    ) -> Result<Compound<'a>> {
        self.out.push('{');
        self.out.push_str(variant);
        self.out.push_str("={");
        Ok(Compound {
            ser: self,
            first: true,
        })
    }
}

impl ser::SerializeSeq for Compound<'_> {
    type Ok = ();
    type Error = Error;
    fn serialize_element<T: ?Sized + Serialize>(&mut self, value: &T) -> Result<()> {
        self.comma();
        value.serialize(&mut *self.ser)
    }
    fn end(self) -> Result<()> {
        self.ser.out.push('}');
        Ok(())
    }
}

impl ser::SerializeTuple for Compound<'_> {
    type Ok = ();
    type Error = Error;
    fn serialize_element<T: ?Sized + Serialize>(&mut self, value: &T) -> Result<()> {
        ser::SerializeSeq::serialize_element(self, value)
    }
    fn end(self) -> Result<()> {
        ser::SerializeSeq::end(self)
    }
}

impl ser::SerializeTupleStruct for Compound<'_> {
    type Ok = ();
    type Error = Error;
    fn serialize_field<T: ?Sized + Serialize>(&mut self, value: &T) -> Result<()> {
        ser::SerializeSeq::serialize_element(self, value)
    }
    fn end(self) -> Result<()> {
        ser::SerializeSeq::end(self)
    }
}

impl ser::SerializeTupleVariant for Compound<'_> {
    type Ok = ();
    type Error = Error;
    fn serialize_field<T: ?Sized + Serialize>(&mut self, value: &T) -> Result<()> {
        ser::SerializeSeq::serialize_element(self, value)
    }
    fn end(self) -> Result<()> {
        self.ser.out.push_str("}}");
        Ok(())
    }
}

fn key(out: &mut String, name: &str) {
    if is_identifier(name) {
        out.push_str(name);
    } else {
        out.push('[');
        quote(out, name);
        out.push(']');
    }
    out.push('=');
}

impl ser::SerializeMap for Compound<'_> {
    type Ok = ();
    type Error = Error;
    fn serialize_key<T: ?Sized + Serialize>(&mut self, name: &T) -> Result<()> {
        self.comma();
        let mut probe = Serializer { out: String::new() };
        name.serialize(&mut probe)?;
        // a string key arrives quoted; an identifier wants no quotes at all
        let text = probe.out;
        if let Some(inner) = text.strip_prefix('"').and_then(|t| t.strip_suffix('"')) {
            if is_identifier(inner) {
                self.ser.out.push_str(inner);
                self.ser.out.push('=');
                return Ok(());
            }
        }
        self.ser.out.push('[');
        self.ser.out.push_str(&text);
        self.ser.out.push_str("]=");
        Ok(())
    }
    fn serialize_value<T: ?Sized + Serialize>(&mut self, value: &T) -> Result<()> {
        value.serialize(&mut *self.ser)
    }
    fn end(self) -> Result<()> {
        self.ser.out.push('}');
        Ok(())
    }
}

impl ser::SerializeStruct for Compound<'_> {
    type Ok = ();
    type Error = Error;
    fn serialize_field<T: ?Sized + Serialize>(
        &mut self,
        name: &'static str,
        value: &T,
    ) -> Result<()> {
        self.comma();
        key(&mut self.ser.out, name);
        value.serialize(&mut *self.ser)
    }
    fn end(self) -> Result<()> {
        self.ser.out.push('}');
        Ok(())
    }
}

impl ser::SerializeStructVariant for Compound<'_> {
    type Ok = ();
    type Error = Error;
    fn serialize_field<T: ?Sized + Serialize>(
        &mut self,
        name: &'static str,
        value: &T,
    ) -> Result<()> {
        ser::SerializeStruct::serialize_field(self, name, value)
    }
    fn end(self) -> Result<()> {
        self.ser.out.push_str("}}");
        Ok(())
    }
}

pub fn to_string<T: Serialize>(value: &T) -> Result<String> {
    let mut serializer = Serializer { out: String::new() };
    value.serialize(&mut serializer)?;
    Ok(serializer.out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::{Deserialize, Serialize};

    #[derive(Serialize, Deserialize, Debug, PartialEq)]
    #[serde(tag = "kind")]
    enum Message {
        #[serde(rename = "chat")]
        Chat {
            player: String,
            text: String,
            seq: i64,
        },
        #[serde(rename = "ping")]
        Ping { seq: i64 },
    }

    #[test]
    fn reads_what_openos_writes() {
        let text = br#"{kind="chat",player="Steve",text="how much \"diesel\"?\nnow",seq=4}"#;
        let message: Message = from_bytes(text).unwrap();
        assert_eq!(
            message,
            Message::Chat {
                player: "Steve".into(),
                text: "how much \"diesel\"?\nnow".into(),
                seq: 4
            }
        );
    }

    #[test]
    fn reads_sequences_and_odd_keys() {
        #[derive(Deserialize)]
        struct Fluid {
            name: String,
            amount: i64,
            rate: f64,
        }
        #[derive(Deserialize)]
        struct Report {
            fluids: Vec<Fluid>,
            #[serde(rename = "odd key")]
            odd: bool,
        }
        let report: Report = from_bytes(
            br#"{fluids={{name="Diesel",amount=42000,rate=-1.5}},["odd key"]=true,[3]=nil}"#,
        )
        .unwrap();
        assert_eq!(report.fluids.len(), 1);
        assert_eq!(report.fluids[0].name, "Diesel");
        assert_eq!(report.fluids[0].amount, 42000);
        assert_eq!(report.fluids[0].rate, -1.5);
        assert!(report.odd);
    }

    #[test]
    fn reads_decimal_escapes_and_bare_newlines() {
        let value = parse(b"\"a\\009b\\\nc\"").unwrap();
        assert_eq!(value, Lua::Str(b"a\tb\nc".to_vec()));
    }

    #[test]
    fn writes_what_openos_reads() {
        let text = to_string(&Message::Ping { seq: 2 }).unwrap();
        assert_eq!(text, r#"{kind="ping",seq=2}"#);
        let text = to_string(&Message::Chat {
            player: "x".into(),
            text: "say \"hi\"\n".into(),
            seq: 1,
        })
        .unwrap();
        assert_eq!(
            text,
            r#"{kind="chat",player="x",text="say \"hi\"\n",seq=1}"#
        );
        let back: Message = from_bytes(text.as_bytes()).unwrap();
        assert!(matches!(back, Message::Chat { .. }));
    }

    #[test]
    fn writes_options_and_floats_lua_accepts() {
        #[derive(Serialize)]
        struct Ask {
            id: String,
            host: Option<String>,
            wait: f64,
        }
        let text = to_string(&Ask {
            id: "a1".into(),
            host: None,
            wait: 5.0,
        })
        .unwrap();
        assert_eq!(text, r#"{id="a1",host=nil,wait=5.0}"#);
    }
}
