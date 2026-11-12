use serde_json::{json, Value};
use std::collections::HashMap;
use unicode_normalization::{char::is_combining_mark, UnicodeNormalization};

/// Word order and accents ignored, so "Léa Martin" on WhatsApp meets "martin lea" on Instagram; one word is too
/// weak to merge on.
pub fn name_key(name: &str) -> Option<String> {
    let plain: String = name.nfkd().filter(|c| !is_combining_mark(*c)).collect::<String>().to_lowercase();
    let mut words: Vec<&str> = plain.split(|c: char| !c.is_alphabetic()).filter(|w| !w.is_empty()).collect();
    if words.len() < 2 {
        return None;
    }
    words.sort();
    let key = words.join(" ");
    // Names networks give accounts they cannot show: many strangers share them.
    const PLACEHOLDERS: [&str; 5] = ["instagram user", "unknown user", "facebook user", "deleted user", "linkedin member"];
    (!PLACEHOLDERS.contains(&key.as_str())).then(|| format!("name:{key}"))
}

/// The last 9 digits, so +33 6…, 06… and 0033 6… are one number.
pub fn phone_key(phone: &str) -> Option<String> {
    let digits: String = phone.chars().filter(char::is_ascii_digit).collect();
    (digits.len() >= 9).then(|| format!("tel:{}", &digits[digits.len() - 9..]))
}

/// A handle like "alexandre.chahinian" is the full name another network carries, when the profile shows one word.
fn handle_key(handle: &str) -> Option<String> {
    let words: Vec<&str> = handle.split(['.', '_']).filter(|w| !w.is_empty()).collect();
    if words.iter().any(|w| !w.chars().all(char::is_alphabetic)) {
        return None;
    }
    name_key(&words.join(" "))
}

fn other(chat: &Value) -> Option<&Value> {
    chat["participants"]["items"].as_array()?.iter().find(|p| p["isSelf"] != true && p["isNetworkBot"] != true)
}

fn name_of(chat: &Value) -> String {
    let full = other(chat).and_then(|p| p["fullName"].as_str()).unwrap_or("");
    if full.is_empty() { chat["title"].as_str().unwrap_or("").to_string() } else { full.to_string() }
}

fn keys(chat: &Value) -> Vec<String> {
    let mut keys: Vec<String> = name_key(&name_of(chat)).into_iter().collect();
    if let Some(p) = other(chat) {
        keys.extend(p["phoneNumber"].as_str().and_then(phone_key));
        keys.extend(p["username"].as_str().and_then(handle_key));
    }
    keys
}

fn id(chat: &Value) -> &str {
    chat["id"].as_str().unwrap_or("")
}

fn last(chat: &Value) -> &str {
    chat["lastActivity"].as_str().unwrap_or("")
}

fn find(parent: &mut [usize], mut i: usize) -> usize {
    while parent[i] != i {
        parent[i] = parent[parent[i]];
        i = parent[i];
    }
    i
}

/// A chat Beeper merged itself holds one participant per network of the same person, the first often without a
/// picture: take another one's, Instagram first, then WhatsApp, then Google Messages.
fn merged_picture(chat: &Value) -> Option<&str> {
    let rank = |p: &Value| ["instagram", "whatsapp", "gmessages"].iter().position(|n| p["id"].as_str().unwrap_or("").contains(n)).unwrap_or(3);
    let mut with: Vec<&Value> = chat["participants"]["items"].as_array()?.iter()
        .filter(|p| p["isSelf"] != true && p["isNetworkBot"] != true && p["imgURL"].is_string())
        .collect();
    with.sort_by_key(|p| rank(p));
    with.first().and_then(|p| p["imgURL"].as_str())
}

fn summary(chat: &Value) -> Value {
    json!({
        "id": id(chat), "network": chat["network"], "accountID": chat["accountID"], "title": name_of(chat),
        "unread": chat["unreadCount"].as_i64().unwrap_or(0), "last": last(chat), "preview": chat["preview"],
        "img": other(chat).and_then(|p| p["imgURL"].as_str()).or_else(|| merged_picture(chat)).or(chat["imgURL"].as_str()),
    })
}

/// Profile pictures to try in turn: Instagram, then WhatsApp, then Google Messages, then the rest by recency.
fn pictures(chats: &[Value]) -> Vec<&str> {
    let rank = |c: &Value| ["Instagram", "WhatsApp", "Google Messages"].iter().position(|n| c["network"] == *n).unwrap_or(3);
    let mut ranked: Vec<&Value> = chats.iter().filter(|c| c["img"].is_string()).collect();
    ranked.sort_by_key(|c| rank(c));
    ranked.iter().filter_map(|c| c["img"].as_str()).collect()
}

/// People from one-to-one chats: chats sharing a name or a phone number are one person, except a chat in
/// `overrides.splits`, which stands alone; each pair in `overrides.merges` is then joined whatever its keys.
/// Group chats come back one by one.
pub fn build(chats: &[Value], overrides: &Value) -> Value {
    let singles: Vec<&Value> = chats.iter().filter(|c| c["type"] == "single").collect();
    let index: HashMap<&str, usize> = singles.iter().enumerate().map(|(i, c)| (id(c), i)).collect();
    let splits: Vec<&str> = overrides["splits"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
    let mut parent: Vec<usize> = (0..singles.len()).collect();
    let mut owner: HashMap<String, usize> = HashMap::new();
    for (i, chat) in singles.iter().enumerate() {
        if splits.contains(&id(chat)) {
            continue;
        }
        for key in keys(chat) {
            match owner.get(&key) {
                Some(&j) => {
                    let (a, b) = (find(&mut parent, i), find(&mut parent, j));
                    parent[a] = b;
                }
                None => {
                    owner.insert(key, i);
                }
            }
        }
    }
    for pair in overrides["merges"].as_array().into_iter().flatten() {
        if let (Some(&i), Some(&j)) = (pair[0].as_str().and_then(|a| index.get(a)), pair[1].as_str().and_then(|b| index.get(b))) {
            let (a, b) = (find(&mut parent, i), find(&mut parent, j));
            parent[a] = b;
        }
    }
    let mut groups: HashMap<usize, Vec<&Value>> = HashMap::new();
    for i in 0..singles.len() {
        let root = find(&mut parent, i);
        groups.entry(root).or_default().push(singles[i]);
    }
    let mut people: Vec<Value> = groups
        .into_values()
        .map(|mut members| {
            members.sort_by(|a, b| last(b).cmp(last(a)));
            let name = members.iter().map(|c| name_of(c)).max_by_key(|n| (name_key(n).map_or(0, |k| k.split(' ').count()), n.len())).unwrap_or_default();
            let chats: Vec<Value> = members.iter().map(|c| summary(c)).collect();
            json!({
                "id": members.iter().map(|c| id(c)).min().unwrap_or(""),
                "name": name,
                "imgs": pictures(&chats),
                "unread": chats.iter().map(|c| c["unread"].as_i64().unwrap_or(0)).sum::<i64>(),
                "last": last(members[0]),
                "preview": members[0]["preview"],
                "chats": chats,
            })
        })
        .collect();
    people.sort_by(|a, b| b["last"].as_str().cmp(&a["last"].as_str()));
    let mut rooms: Vec<Value> = chats
        .iter()
        .filter(|c| c["type"] != "single")
        .map(|c| {
            let s = summary(c);
            json!({ "id": s["id"], "name": c["title"], "imgs": c["imgURL"].as_str().into_iter().collect::<Vec<_>>(), "unread": s["unread"], "last": s["last"], "preview": s["preview"], "chats": [s] })
        })
        .collect();
    rooms.sort_by(|a, b| b["last"].as_str().cmp(&a["last"].as_str()));
    json!({ "people": people, "groups": rooms })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chat(id: &str, network: &str, name: &str, phone: Option<&str>, last: &str) -> Value {
        json!({ "id": id, "type": "single", "network": network, "lastActivity": last, "unreadCount": 1,
            "participants": { "items": [{ "isSelf": true, "fullName": "Me" }, { "fullName": name, "phoneNumber": phone, "imgURL": format!("mxc://{}", &id[..id.find('-').unwrap()]) }] } })
    }

    fn fixture() -> Vec<Value> {
        vec![
            chat("wa-lea", "WhatsApp", "Lea Martin", Some("+33 6 12 34 56 78"), "2026-11-10T10:00:00Z"),
            chat("ig-lea", "Instagram", "Léa  MARTIN", None, "2026-11-11T10:00:00Z"),
            chat("sms-lea", "Google Messages", "06 12 34 56 78", Some("0612345678"), "2026-11-11T12:00:00Z"),
            chat("dc-tom", "Discord", "tom", None, "2026-11-09T10:00:00Z"),
            chat("wa-tom", "WhatsApp", "Tom B", Some("+33 7 00 00 00 01"), "2026-11-08T10:00:00Z"),
            json!({ "id": "grp", "type": "group", "title": "Team", "network": "Discord", "lastActivity": "2026-11-12T00:00:00Z" }),
        ]
    }

    fn people(out: &Value) -> Vec<Vec<String>> {
        let mut v: Vec<Vec<String>> = out["people"].as_array().unwrap().iter()
            .map(|p| { let mut ids: Vec<String> = p["chats"].as_array().unwrap().iter().map(|c| c["id"].as_str().unwrap().into()).collect(); ids.sort(); ids })
            .collect();
        v.sort();
        v
    }

    #[test]
    fn groups_by_name_and_phone() {
        let out = build(&fixture(), &json!({}));
        assert_eq!(people(&out), vec![vec!["dc-tom"], vec!["ig-lea", "sms-lea", "wa-lea"], vec!["wa-tom"]]);
        let lea = &out["people"][0];
        assert_eq!(lea["name"], "Léa  MARTIN");
        assert_eq!(lea["unread"], 3);
        assert_eq!(lea["chats"][0]["id"], "sms-lea");
        assert_eq!(lea["imgs"], json!(["mxc://ig", "mxc://wa", "mxc://sms"]));
        assert_eq!(out["groups"][0]["id"], "grp");
    }

    #[test]
    fn split_and_merge_override_keys() {
        let out = build(&fixture(), &json!({ "splits": ["sms-lea"], "merges": [["dc-tom", "wa-tom"]] }));
        assert_eq!(people(&out), vec![vec!["dc-tom", "wa-tom"], vec!["ig-lea", "wa-lea"], vec!["sms-lea"]]);
    }

    #[test]
    fn merged_chat_takes_another_participants_picture() {
        let c = json!({ "id": "bp-eliot", "type": "single", "network": "Beeper (Matrix)", "lastActivity": "2026-11-12T00:00:00Z",
            "participants": { "items": [{ "isSelf": true }, { "id": "a", "fullName": "Eliot G" },
                { "id": "@whatsapp_1:x", "imgURL": "mxc://wa" }, { "id": "@instagram_2:x", "imgURL": "file://ig" }] } });
        assert_eq!(build(&[c], &json!({}))["people"][0]["imgs"], json!(["file://ig"]));
    }

    #[test]
    fn handle_meets_full_name() {
        let ig = json!({ "id": "ig-alex", "type": "single", "network": "Instagram", "lastActivity": "2026-11-12T00:00:00Z",
            "participants": { "items": [{ "isSelf": true }, { "fullName": "Alexandre", "username": "alexandre.chahinian" }] } });
        let wa = chat("wa-alex", "WhatsApp", "Alexandre Chahinian", Some("+33 6 00 00 00 09"), "2026-11-01T00:00:00Z");
        let li = json!({ "id": "li-x", "type": "single", "network": "LinkedIn", "lastActivity": "2026-11-02T00:00:00Z",
            "participants": { "items": [{ "isSelf": true }, { "fullName": "Alex", "username": "ACoAAEKc-97TUQ" }] } });
        assert_eq!(people(&build(&[ig, wa, li], &json!({}))), vec![vec!["ig-alex", "wa-alex"], vec!["li-x"]]);
    }

    #[test]
    fn keys() {
        assert_eq!(name_key("Martin, Léa"), Some("name:lea martin".into()));
        assert_eq!(name_key("tom"), None);
        assert_eq!(name_key("Instagram User"), None);
        assert_eq!(name_key("user unknown"), None);
        assert_eq!(phone_key("+33 (0)6 12-34-56-78"), Some("tel:612345678".into()));
        assert_eq!(phone_key("1234"), None);
    }
}
