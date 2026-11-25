//! What the agent waits on: a question for Marius or an approval, read from the worker's `permissions` metadata and
//! drawn as cards the page answers through the core, as the Swift `QuestionPanel` and `PermissionView` do.

use crate::item::text;
use crate::state::Object;
use serde_json::{Value, json};

const QUESTION_METHOD: &str = "item/tool/requestUserInput";
const FILE_CHANGE_METHOD: &str = "item/fileChange/requestApproval";

pub fn views(permissions: Option<&Value>) -> Vec<Value> {
    permissions.and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_object).filter_map(view).collect()
}

fn view(request: &Object) -> Option<Value> {
    let method = text(request, "method")?;
    let params = request.get("params").and_then(Value::as_object).cloned().unwrap_or_default();
    let mut card = json!({"id": text(request, "id").unwrap_or_default(), "rpcID": request.get("rpcID")?, "method": method});
    let questions: Vec<Value> = params.get("questions").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_object).enumerate().map(question).collect();
    if method == QUESTION_METHOD {
        if questions.is_empty() {
            return None;
        }
        card["kind"] = json!("question");
        card["questions"] = Value::Array(questions);
        return Some(card);
    }
    let changes: Vec<&Object> = params.get("changes").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_object).collect();
    let detail = match text(&params, "command") {
        Some(command) => command.to_owned(),
        None => changes.iter().map(|change| format!("{}\n{}", text(change, "path").unwrap_or_default(), text(change, "diff").unwrap_or_default())).collect::<Vec<_>>().join("\n"),
    };
    card["kind"] = json!("approval");
    card["reason"] = json!(text(&params, "reason").unwrap_or("Review this action before allowing it."));
    card["detail"] = json!(detail);
    card["canAllow"] = json!(method != FILE_CHANGE_METHOD || !changes.is_empty());
    Some(card)
}

fn question((index, question): (usize, &Object)) -> Value {
    let options: Vec<Value> = question.get("options").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_object).map(|option| {
        json!({"label": text(option, "label").unwrap_or("Option"), "description": text(option, "description").unwrap_or_default()})
    }).collect();
    json!({
        "id": text(question, "id").map_or_else(|| index.to_string(), str::to_owned),
        "header": text(question, "header"),
        "question": text(question, "question").unwrap_or("Question"),
        "options": options,
        "multiple": question.get("multiSelect") == Some(&Value::Bool(true)),
        "secret": question.get("isSecret") == Some(&Value::Bool(true)),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn draws_a_pending_question_with_its_numbered_options() {
        let permissions = json!([{"id": "P1", "rpcID": 7, "method": QUESTION_METHOD, "params": {"questions": [
            {"id": "style", "header": "Button", "question": "Which style?", "options": [{"label": "Shared", "description": "Follows the theme."}, {"label": "Fixed"}]},
            {"question": "Anything else?", "multiSelect": true, "options": []}
        ]}}]);

        let cards = views(Some(&permissions));

        assert_eq!(cards.len(), 1);
        assert_eq!((&cards[0]["kind"], &cards[0]["rpcID"]), (&json!("question"), &json!(7)));
        assert_eq!(cards[0]["questions"][0]["options"], json!([{"label": "Shared", "description": "Follows the theme."}, {"label": "Fixed", "description": ""}]));
        assert_eq!((&cards[0]["questions"][1]["id"], &cards[0]["questions"][1]["multiple"]), (&json!("1"), &json!(true)));
    }

    #[test]
    fn draws_an_approval_and_refuses_allowing_an_empty_file_change() {
        let permissions = json!([
            {"id": "P2", "rpcID": "a", "method": "item/commandExecution/requestApproval", "params": {"command": "rm -rf build", "reason": "Cleans the build."}},
            {"id": "P3", "rpcID": "b", "method": FILE_CHANGE_METHOD, "params": {"changes": []}}
        ]);

        let cards = views(Some(&permissions));

        assert_eq!((&cards[0]["detail"], &cards[0]["reason"], &cards[0]["canAllow"]), (&json!("rm -rf build"), &json!("Cleans the build."), &json!(true)));
        assert_eq!(cards[1]["canAllow"], false);
    }

    #[test]
    fn skips_a_request_with_no_id_to_answer() {
        let permissions = json!([{"method": QUESTION_METHOD, "params": {"questions": [{"question": "?"}]}}]);

        assert!(views(Some(&permissions)).is_empty());
        assert!(views(None).is_empty());
    }
}
