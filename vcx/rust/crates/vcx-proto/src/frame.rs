use serde_json::{Map, Value};
use std::fmt;

pub type Object = Map<String, Value>;

pub const MAX_FRAME_BYTES: usize = 32 * 1024 * 1024;
const FRAME_END: u8 = b'\n';

#[derive(Debug)]
pub enum FrameError {
    TooLarge,
    Empty,
    NotAnObject,
    Json(serde_json::Error),
}

impl fmt::Display for FrameError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::TooLarge => write!(f, "Runtime frame exceeds the size limit."),
            Self::Empty => write!(f, "Runtime frame is empty."),
            Self::NotAnObject => write!(f, "Runtime frame is not a JSON object."),
            Self::Json(error) => write!(f, "Runtime frame is not valid JSON: {error}"),
        }
    }
}

impl std::error::Error for FrameError {}

pub fn encode(message: &Object) -> Result<Vec<u8>, FrameError> {
    let mut data = serde_json::to_vec(message).map_err(FrameError::Json)?;
    if data.len() > MAX_FRAME_BYTES {
        return Err(FrameError::TooLarge);
    }
    data.push(FRAME_END);
    Ok(data)
}

/// Splits a byte stream into frames. An error is final: the peer closes the connection, as the Swift channel does.
#[derive(Default)]
pub struct FrameDecoder {
    buffer: Vec<u8>,
    scanned: usize,
}

impl FrameDecoder {
    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<Object>, FrameError> {
        self.buffer.extend_from_slice(bytes);
        let mut frames = Vec::new();
        let mut start = 0;
        while let Some(offset) = self.buffer[self.scanned..].iter().position(|byte| *byte == FRAME_END) {
            let end = self.scanned + offset;
            frames.push(decode(&self.buffer[start..end])?);
            start = end + 1;
            self.scanned = start;
        }
        self.buffer.drain(..start);
        self.scanned = self.buffer.len();
        if self.buffer.len() > MAX_FRAME_BYTES {
            return Err(FrameError::TooLarge);
        }
        Ok(frames)
    }
}

fn decode(data: &[u8]) -> Result<Object, FrameError> {
    if data.is_empty() {
        return Err(FrameError::Empty);
    }
    if data.len() > MAX_FRAME_BYTES {
        return Err(FrameError::TooLarge);
    }
    match serde_json::from_slice(data).map_err(FrameError::Json)? {
        Value::Object(object) => Ok(object),
        _ => Err(FrameError::NotAnObject),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn object(value: Value) -> Object {
        value.as_object().unwrap().clone()
    }

    #[test]
    fn returns_each_frame_when_several_arrive_in_one_read() {
        let mut decoder = FrameDecoder::default();

        let frames = decoder.push(b"{\"id\":\"1\"}\n{\"id\":\"2\"}\n").unwrap();

        assert_eq!(frames, vec![object(json!({"id": "1"})), object(json!({"id": "2"}))]);
    }

    #[test]
    fn keeps_a_partial_frame_until_its_newline_arrives() {
        let mut decoder = FrameDecoder::default();

        let first = decoder.push(b"{\"method\":\"session/").unwrap();
        let second = decoder.push(b"update\"}\n{\"id\"").unwrap();
        let third = decoder.push(b":\"3\"}\n").unwrap();

        assert!(first.is_empty());
        assert_eq!(second, vec![object(json!({"method": "session/update"}))]);
        assert_eq!(third, vec![object(json!({"id": "3"}))]);
    }

    #[test]
    fn keeps_a_newline_escaped_inside_a_string_in_one_frame() {
        let message = object(json!({"text": "line one\nline two"}));
        let mut decoder = FrameDecoder::default();

        let frames = decoder.push(&encode(&message).unwrap()).unwrap();

        assert_eq!(frames, vec![message]);
    }

    #[test]
    fn rejects_an_empty_line() {
        let mut decoder = FrameDecoder::default();

        let result = decoder.push(b"\n");

        assert!(matches!(result, Err(FrameError::Empty)));
    }

    #[test]
    fn rejects_a_frame_that_is_not_an_object() {
        let mut decoder = FrameDecoder::default();

        let result = decoder.push(b"[1,2]\n");

        assert!(matches!(result, Err(FrameError::NotAnObject)));
    }

    #[test]
    fn writes_keys_sorted_so_both_ends_hash_the_same_bytes() {
        let message = object(json!({"params": {}, "id": "7", "method": "hello"}));

        let data = encode(&message).unwrap();

        assert_eq!(data, b"{\"id\":\"7\",\"method\":\"hello\",\"params\":{}}\n");
    }
}
