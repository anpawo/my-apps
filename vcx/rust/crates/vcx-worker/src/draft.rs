//! A sent prompt taken back into the composer, as the Swift `withdrawnDraft` builds it: its images back in their
//! places, and the draft typed meanwhile kept after it.

use serde_json::{Value, json};
use std::collections::BTreeSet;

const IMAGE_TAG: &str = "[Image #";

fn text_piece(pieces: &mut Vec<Value>, text: &str) {
    if !text.is_empty() {
        pieces.push(json!({"type": "text", "text": text}));
    }
}

/// The Swift `inlineImages`: a sent prompt names its images "[Image #N]" in its text and lists them after it.
pub fn inline_images(content: &[Value]) -> Vec<Value> {
    let images: Vec<&Value> = content.iter().filter(|piece| piece.get("text").is_none() && piece.get("path").is_some()).collect();
    let (mut used, mut pieces) = (BTreeSet::new(), Vec::new());
    for text in content.iter().filter_map(|piece| piece.get("text").and_then(Value::as_str)) {
        let (mut start, mut search) = (0, 0);
        while let Some(found) = text[search..].find(IMAGE_TAG) {
            let at = search + found;
            let digits = at + IMAGE_TAG.len();
            let end = digits + text[digits..].bytes().take_while(u8::is_ascii_digit).count();
            search = digits;
            if end == digits || !text[end..].starts_with(']') {
                continue;
            }
            search = end + 1;
            let number = text[digits..end].parse::<usize>().ok().filter(|number| (1..=images.len()).contains(number) && used.insert(*number));
            if let Some(number) = number {
                text_piece(&mut pieces, &text[start..at]);
                pieces.push(images[number - 1].clone());
                start = search;
            }
        }
        text_piece(&mut pieces, &text[start..]);
    }
    pieces.extend(images.iter().enumerate().filter(|(index, _)| !used.contains(&(index + 1))).map(|(_, image)| (*image).clone()));
    pieces
}

/// The Swift `plainDraftContent`: paste and command chips read as their text, neighbouring texts joined.
fn plain(pieces: &[Value]) -> Vec<Value> {
    let mut plain: Vec<Value> = Vec::new();
    for piece in pieces {
        let kind = piece.get("type").and_then(Value::as_str).unwrap_or_default();
        let piece = if ["paste", "command"].contains(&kind) { json!({"type": "text", "text": piece.get("text").and_then(Value::as_str).unwrap_or_default()}) } else { piece.clone() };
        match plain.last_mut() {
            Some(last) if last["type"] == "text" && piece["type"] == "text" => {
                let joined = last["text"].as_str().unwrap_or_default().to_owned() + piece["text"].as_str().unwrap_or_default();
                last["text"] = json!(joined);
            }
            _ => plain.push(piece),
        }
    }
    plain
}

/// The prompt `content` back in the composer; a draft that is not already that prompt stays after it.
pub fn withdrawn(content: &[Value], draft: &[Value]) -> Vec<Value> {
    let mut restored = inline_images(content);
    if plain(draft) != plain(&restored) {
        restored.extend(draft.iter().cloned());
    }
    restored
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn puts_each_named_image_back_in_its_place_and_the_others_after_the_text() {
        let content = [json!({"type": "text", "text": "see [Image #2] then [Image #9]"}), json!({"type": "localImage", "path": "/a.png"}), json!({"type": "localImage", "path": "/b.png"})];

        let pieces = inline_images(&content);

        assert_eq!(pieces, [json!({"type": "text", "text": "see "}), json!({"type": "localImage", "path": "/b.png"}), json!({"type": "text", "text": " then [Image #9]"}), json!({"type": "localImage", "path": "/a.png"})]);
    }

    #[test]
    fn keeps_a_draft_typed_since_after_the_withdrawn_prompt_and_not_the_same_prompt_twice() {
        let content = [json!({"type": "text", "text": "fix it"})];
        let typed = [json!({"type": "text", "text": " and test"})];

        let (with_typed, recalled) = (withdrawn(&content, &typed), withdrawn(&content, &[json!({"type": "paste", "text": "fix it", "number": 1})]));

        assert_eq!(with_typed, [json!({"type": "text", "text": "fix it"}), json!({"type": "text", "text": " and test"})]);
        assert_eq!(recalled, content);
    }
}
