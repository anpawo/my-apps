//! Codex's multiple-choice question tool, as `ClaudeCompatibility.questionTool` gives it: offered as a dynamic tool on
//! a new Codex thread, its call is shown as the question VCX asks for Claude, and the answer goes back as its result.

use serde_json::{Value, json};

pub type Object = serde_json::Map<String, Value>;

pub const TOOL: &str = "AskUserQuestion";
/// The question the frontend shows; the call is answered through it.
pub const ASKED_METHOD: &str = "item/tool/requestUserInput";
pub const MARKER: &str = "vcxQuestionTool";
const QUESTIONS: std::ops::RangeInclusive<usize> = 1..=4;
const OPTIONS: std::ops::RangeInclusive<usize> = 2..=4;
const INVALID: &str = "Invalid question. Supply 1 to 4 questions with 2 to 4 distinct options each.";

pub fn tool() -> Value {
    let option = json!({"type": "object", "properties": {"label": {"type": "string"}, "description": {"type": "string"}}, "required": ["label", "description"], "additionalProperties": false});
    let question = json!({"type": "object", "properties": {"question": {"type": "string"}, "header": {"type": "string"}, "multiSelect": {"type": "boolean"}, "options": {"type": "array", "items": option, "minItems": 2, "maxItems": 4}}, "required": ["question", "header", "multiSelect", "options"], "additionalProperties": false});
    json!({"type": "function", "name": TOOL, "description": "Ask the user 1 to 4 clarification questions with choices in vcx, in either plan or implementation mode. Each question also accepts free text. Wait for the user's answer before proceeding with dependent work. Do not use this tool to bypass approval restrictions.", "inputSchema": {"type": "object", "properties": {"questions": {"type": "array", "items": question, "minItems": 1, "maxItems": 4}}, "required": ["questions"], "additionalProperties": false}})
}

fn valid(question: &Value) -> bool {
    let Some(text) = question["question"].as_str() else { return false };
    let Some(options) = question["options"].as_array().filter(|options| OPTIONS.contains(&options.len())) else { return false };
    let labels: Vec<&str> = options.iter().filter_map(|option| option["label"].as_str()).collect();
    let distinct: std::collections::HashSet<&&str> = labels.iter().collect();
    !text.trim().is_empty() && labels.len() == options.len() && labels.iter().all(|label| !label.is_empty()) && distinct.len() == labels.len()
}

/// The question to show for a call of the tool, each question given an id, or `None` for a call to refuse.
pub fn questions(params: &Object) -> Option<Object> {
    let questions = params.get("arguments")?.get("questions")?.as_array()?;
    if params.get("tool").and_then(Value::as_str) != Some(TOOL) || !QUESTIONS.contains(&questions.len()) || !questions.iter().all(valid) {
        return None;
    }
    let mut shown = params.clone();
    shown.insert(MARKER.into(), json!(true));
    let numbered = questions.iter().enumerate().map(|(index, question)| {
        let mut question = question.clone();
        question["id"] = json!(format!("question-{index}"));
        question
    });
    shown.insert("questions".into(), Value::Array(numbered.collect()));
    Some(shown)
}

/// The tool's result for a refused call.
pub fn refused() -> Value {
    json!({"success": false, "contentItems": [{"type": "inputText", "text": INVALID}]})
}

/// The tool's result for the user's answers (`{"answers": {id: {"answers": [...]}}}`): none is a cancel.
pub fn answer(shown: &Object, result: &Object) -> Value {
    let given = result.get("answers").and_then(Value::as_object);
    let mut answers = Vec::new();
    for question in shown.get("questions").and_then(Value::as_array).into_iter().flatten() {
        let Some(id) = question["id"].as_str() else { continue };
        let Some(chosen) = given.and_then(|given| given.get(id)).and_then(|value| value["answers"].as_array()) else { continue };
        if chosen.iter().all(Value::is_string) {
            answers.push(json!({"id": id, "question": question["question"].as_str().unwrap_or_default(), "header": question["header"].as_str().unwrap_or_default(), "answers": chosen}));
        }
    }
    let text = json!({"answers": answers, "cancelled": answers.is_empty()}).to_string();
    json!({"success": !answers.is_empty(), "contentItems": [{"type": "inputText", "text": text}]})
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(questions: Value) -> Object {
        json!({"threadId": "T", "tool": TOOL, "arguments": {"questions": questions}}).as_object().unwrap().clone()
    }

    fn choice(text: &str, labels: &[&str]) -> Value {
        json!({"question": text, "header": "H", "multiSelect": false, "options": labels.iter().map(|label| json!({"label": label, "description": ""})).collect::<Vec<_>>()})
    }

    #[test]
    fn a_valid_call_becomes_a_question_with_numbered_ids() {
        let shown = questions(&call(json!([choice("Which?", &["A", "B"]), choice("And?", &["C", "D"])]))).unwrap();

        assert_eq!(shown[MARKER], json!(true));
        assert_eq!(shown["questions"].as_array().unwrap().iter().map(|question| question["id"].clone()).collect::<Vec<_>>(), [json!("question-0"), json!("question-1")]);
    }

    #[test]
    fn refuses_repeated_labels_a_single_option_a_blank_question_or_another_tool() {
        let refused = [
            call(json!([choice("Which?", &["A", "A"])])),
            call(json!([choice("Which?", &["A"])])),
            call(json!([choice("  ", &["A", "B"])])),
            call(json!([])),
            json!({"tool": "Other", "arguments": {"questions": [choice("Which?", &["A", "B"])]}}).as_object().unwrap().clone(),
        ];

        assert!(refused.iter().all(|params| questions(params).is_none()));
    }

    #[test]
    fn the_answer_goes_back_as_the_tools_text_result() {
        let shown = questions(&call(json!([choice("Which?", &["A", "B"])]))).unwrap();
        let result = json!({"answers": {"question-0": {"answers": ["B"]}}}).as_object().unwrap().clone();

        let answered = answer(&shown, &result);

        let text: Value = serde_json::from_str(answered["contentItems"][0]["text"].as_str().unwrap()).unwrap();
        assert_eq!(answered["success"], json!(true));
        assert_eq!(text, json!({"answers": [{"id": "question-0", "question": "Which?", "header": "H", "answers": ["B"]}], "cancelled": false}));
    }

    #[test]
    fn no_answer_is_a_cancel() {
        let shown = questions(&call(json!([choice("Which?", &["A", "B"])]))).unwrap();

        let answered = answer(&shown, &Object::new());

        assert_eq!(answered["success"], json!(false));
        assert_eq!(answered["contentItems"][0]["text"], json!(r#"{"answers":[],"cancelled":true}"#));
    }
}
