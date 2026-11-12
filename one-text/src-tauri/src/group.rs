use serde_json::{json, Value};
use std::collections::HashMap;
use unicode_normalization::{char::is_combining_mark, UnicodeNormalization};

/// Word order and accents ignored, so "Léa Martin" on WhatsApp meets "martin lea" on Instagram; one word is too
/// weak to merge on.
/// Lowercase, accents off, and the Greek or Cyrillic lookalikes of stylised names ("ƒαustine") read as Latin.
fn plain(name: &str) -> String {
    const LOOK: [(char, char); 22] = [('ƒ', 'f'), ('α', 'a'), ('β', 'b'), ('ε', 'e'), ('η', 'n'), ('ι', 'i'), ('κ', 'k'), ('ν', 'v'), ('ο', 'o'), ('ρ', 'p'),
        ('τ', 't'), ('υ', 'u'), ('χ', 'x'), ('ω', 'w'), ('а', 'a'), ('е', 'e'), ('о', 'o'), ('р', 'p'), ('с', 'c'), ('х', 'x'), ('ı', 'i'), ('ł', 'l')];
    name.nfkd().filter(|c| !is_combining_mark(*c)).collect::<String>().to_lowercase()
        .chars().map(|c| LOOK.iter().find(|(l, _)| *l == c).map_or(c, |(_, r)| *r)).collect()
}

pub fn name_key(name: &str) -> Option<String> {
    let plain = plain(name);
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

fn words(name: &str) -> Vec<String> {
    let plain = plain(name);
    plain.split(|c: char| !c.is_alphabetic()).filter(|w| !w.is_empty()).map(str::to_string).collect()
}

fn one_word(name: &str) -> Option<String> {
    let w = words(name);
    (w.len() == 1 && w[0].chars().count() >= 3).then(|| w[0].clone())
}

/// "victor__k__" → ("victor", 'k'): a first name and one letter, nothing else.
fn initial_handle(handle: &str) -> Option<(String, char)> {
    let parts: Vec<&str> = handle.split(['.', '_']).filter(|w| !w.is_empty()).collect();
    match parts[..] {
        [name, letter] if name.chars().count() >= 3 && name.chars().all(char::is_alphabetic) && letter.chars().count() == 1 && letter.chars().all(char::is_alphabetic) =>
            Some((name.to_lowercase(), letter.to_lowercase().chars().next()?)),
        _ => None,
    }
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

/// Four members' pictures, for the tile after the app's logo: the one their person has (a picture set by hand, or
/// one from another app) before the one this app gives.
fn faces(chat: &Value, pic_of: &HashMap<String, String>) -> Vec<String> {
    let members = chat["participants"]["items"].as_array().into_iter().flatten().filter(|p| p["isSelf"] != true && p["isNetworkBot"] != true);
    members.filter_map(|p| p["id"].as_str().and_then(|i| pic_of.get(i)).map(String::clone).or(p["imgURL"].as_str().map(String::from))).take(4).collect()
}

fn pictures(chats: &[Value]) -> Vec<&str> {
    let rank = |c: &Value| ["Instagram", "WhatsApp", "Google Messages"].iter().position(|n| c["network"] == *n).unwrap_or(3);
    let mut ranked: Vec<&Value> = chats.iter().filter(|c| c["img"].is_string()).collect();
    ranked.sort_by_key(|c| rank(c));
    ranked.iter().filter_map(|c| c["img"].as_str()).collect()
}

/// People from one-to-one chats: chats sharing a name or a phone number are one person, except a chat in
/// `overrides.splits`, which stands alone; each pair in `overrides.merges` is then joined whatever its keys.
/// Group chats come back one by one.
/// Bits apart, out of 64, under which two profile pictures are the same photo: 13 for one photo cropped by
/// Instagram and WhatsApp, 16 for two different photos of the same first name (measured on his chats).
const SAME_PICTURE: u32 = 13;

fn first_name(chat: &Value) -> Option<String> {
    words(&name_of(chat)).into_iter().next().filter(|w| w.chars().count() >= 3)
}

/// A single chat's picture worth hashing: another app has a chat under the same first name.
pub fn picture_candidates(chats: &[Value]) -> Vec<String> {
    let mut nets: HashMap<String, std::collections::HashSet<&str>> = HashMap::new();
    for c in chats.iter().filter(|c| c["type"] == "single") {
        if let Some(f) = first_name(c) {
            nets.entry(f).or_default().insert(c["network"].as_str().unwrap_or(""));
        }
    }
    chats.iter().filter(|c| c["type"] == "single" && first_name(c).is_some_and(|f| nets[&f].len() > 1))
        .filter_map(|c| other(c)?["imgURL"].as_str().map(String::from)).collect()
}

fn pictures_may_meet(a: &Value, b: &Value) -> bool {
    a["network"] != b["network"] && a["pictureHash"].is_array() && b["pictureHash"].is_array() && first_name(a).is_some() && first_name(a) == first_name(b)
}

fn picture_distance(a: &Value, b: &Value) -> u32 {
    let h = |c: &Value| c["pictureHash"].as_array().into_iter().flatten().filter_map(Value::as_u64).collect::<Vec<_>>();
    let (a, b) = (h(a), h(b));
    a.iter().flat_map(|x| b.iter().map(move |y| (x ^ y).count_ones())).min().unwrap_or(64)
}

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
    // A first name alone ("Cyprien") is one person when no app has two chats under it; on one app, it is ambiguous.
    let mut first: HashMap<String, Vec<usize>> = HashMap::new();
    for (i, chat) in singles.iter().enumerate() {
        if let Some(word) = one_word(&name_of(chat)).filter(|_| !splits.contains(&id(chat))) {
            first.entry(word).or_default().push(i);
        }
    }
    for same in first.values().filter(|v| v.len() > 1) {
        let apps: std::collections::HashSet<String> = same.iter().map(|&i| format!("{} {}", singles[i]["network"], singles[i]["accountID"])).collect();
        if apps.len() == same.len() {
            for &i in &same[1..] {
                let (a, b) = (find(&mut parent, i), find(&mut parent, same[0]));
                parent[a] = b;
            }
        }
    }
    // A handle like "victor__k__" is the one full name on another app that starts with Victor K.
    for (i, chat) in singles.iter().enumerate() {
        let Some((name, initial)) = other(chat).and_then(|p| p["username"].as_str()).and_then(initial_handle) else { continue };
        if splits.contains(&id(chat)) {
            continue;
        }
        let fits: Vec<usize> = (0..singles.len()).filter(|&j| j != i && !splits.contains(&id(singles[j]))).filter(|&j| {
            let w = words(&name_of(singles[j]));
            w.len() >= 2 && w[0] == name && w.last().is_some_and(|l| l.starts_with(initial))
        }).collect();
        let names: std::collections::HashSet<Option<String>> = fits.iter().map(|&j| name_key(&name_of(singles[j]))).collect();
        if names.len() == 1 {
            for &j in &fits {
                let (a, b) = (find(&mut parent, i), find(&mut parent, j));
                parent[a] = b;
            }
        }
    }
    // Instagram gives no phone number to meet WhatsApp on: the same profile photo (each app crops it its own way)
    // under the same first name on two apps is one person, when each is the other's closest picture.
    let near: Vec<Option<usize>> = (0..singles.len()).map(|i| {
        (0..singles.len()).filter(|&j| j != i && pictures_may_meet(singles[i], singles[j]) && !splits.contains(&id(singles[j])))
            .map(|j| (picture_distance(singles[i], singles[j]), j)).min().filter(|&(d, _)| d <= SAME_PICTURE).map(|(_, j)| j)
    }).collect();
    for (i, n) in near.iter().enumerate() {
        if let Some(j) = *n {
            if near[j] == Some(i) && !splits.contains(&id(singles[i])) {
                let (a, b) = (find(&mut parent, i), find(&mut parent, j));
                parent[a] = b;
            }
        }
    }
    let mut beeper: HashMap<&str, usize> = HashMap::new();
    for (i, chat) in singles.iter().enumerate() {
        let Some(union) = chat["mergedInto"].as_str().filter(|_| !splits.contains(&id(chat))) else { continue };
        match beeper.get(union) {
            Some(&j) => {
                let (a, b) = (find(&mut parent, i), find(&mut parent, j));
                parent[a] = b;
            }
            None => {
                beeper.insert(union, i);
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
    let mut pic_of: HashMap<String, String> = HashMap::new();
    let mut people: Vec<Value> = groups
        .into_values()
        .map(|mut members| {
            members.sort_by(|a, b| last(b).cmp(last(a)));
            let name = members.iter().map(|c| name_of(c)).max_by_key(|n| (name_key(n).map_or(0, |k| k.split(' ').count()), n.len())).unwrap_or_default();
            let chats: Vec<Value> = members.iter().map(|c| summary(c)).collect();
            // A picture set by hand (overrides.pictures, by chat id) comes first.
            let custom = members.iter().find_map(|c| overrides["pictures"][id(c)].as_str());
            let alias = members.iter().find_map(|c| overrides["names"][id(c)].as_str());
            if let Some(img) = custom.or_else(|| pictures(&chats).into_iter().next()) {
                for p in members.iter().filter_map(|c| other(c)?["id"].as_str()) {
                    pic_of.insert(p.to_string(), img.to_string());
                }
            }
            json!({
                "id": members.iter().map(|c| id(c)).min().unwrap_or(""),
                "name": alias.unwrap_or(&name),
                "original": alias.map(|_| &name),
                "imgs": custom.into_iter().chain(pictures(&chats)).collect::<Vec<_>>(),
                "unread": chats.iter().map(|c| c["unread"].as_i64().unwrap_or(0)).sum::<i64>(),
                "last": last(members[0]),
                "preview": members[0]["preview"],
                "chats": chats,
            })
        })
        .collect();
    people.sort_by(|a, b| b["last"].as_str().cmp(&a["last"].as_str()));
    let hidden: Vec<&str> = overrides["hidden"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
    let mut rooms: Vec<Value> = chats
        .iter()
        .filter(|c| c["type"] != "single")
        .map(|c| {
            let s = summary(c);
            json!({ "id": s["id"], "hidden": hidden.contains(&id(c)), "name": overrides["names"][id(c)].as_str().map_or(c["title"].clone(), |n| json!(n)), "original": overrides["names"][id(c)].as_str().and(c["title"].as_str()), "imgs": overrides["pictures"][id(c)].as_str().or(c["imgURL"].as_str()).into_iter().collect::<Vec<_>>(), "faces": faces(c, &pic_of), "unread": s["unread"], "last": s["last"], "preview": s["preview"], "chats": [s] })
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
    fn lookalike_letters_read_as_latin() {
        assert_eq!(one_word("ƒαustine"), Some("faustine".into()));
        assert_eq!(name_key("Lεa Martιn"), name_key("lea martin"));
    }

    #[test]
    fn a_renamed_group_keeps_its_original_name() {
        let g = json!({ "id": "g1", "type": "group", "network": "Discord", "title": "general-chat", "participants": { "total": 30, "items": [] } });
        let out = build(&[g.clone()], &json!({ "names": { "g1": "Rust FR" } }));
        assert_eq!((&out["groups"][0]["name"], &out["groups"][0]["original"]), (&json!("Rust FR"), &json!("general-chat")));
        assert!(build(&[g], &json!({}))["groups"][0]["original"].is_null());
        let out = build(&fixture(), &json!({ "names": { "wa-lea": "Lele" } }));
        let lea = out["people"].as_array().unwrap().iter().find(|p| p["name"] == "Lele").unwrap();
        assert_eq!(lea["original"], "Léa  MARTIN");
    }

    #[test]
    fn same_picture_on_another_app_is_one_person() {
        let at = "2026-11-12T00:00:00Z";
        let mut rsst = chat("ig-rsst", "Instagram", "ƒαustine", None, at);
        let mut wa = chat("wa-f", "WhatsApp", "Faustine", None, at);
        let mut lcll = chat("ig-lcll", "Instagram", "Faustine", None, at);
        rsst["pictureHash"] = json!([0u64, 1u64 << 63]);
        wa["pictureHash"] = json!([(1u64 << 13) - 1]);
        lcll["pictureHash"] = json!([0xFFFFu64 << 40]);
        let all = [rsst, wa, lcll];
        assert_eq!(picture_candidates(&all).len(), 3);
        assert_eq!(people(&build(&all, &json!({}))), vec![vec!["ig-lcll".to_string()], vec!["ig-rsst".into(), "wa-f".into()]]);
        assert_eq!(people(&build(&all, &json!({ "splits": ["wa-f"] }))).len(), 3);
    }

    #[test]
    fn first_name_alone_merges_once_per_app() {
        let at = "2026-11-12T00:00:00Z";
        let cyp = [chat("ig-c", "Instagram", "Cyprien", None, at), chat("wa-c", "WhatsApp", "Cyprien", None, at)];
        assert_eq!(people(&build(&cyp, &json!({}))), vec![vec!["ig-c", "wa-c"]]);
        assert_eq!(people(&build(&cyp, &json!({ "splits": ["wa-c"] }))).len(), 2);
        let tom = [chat("ig-t", "Instagram", "Tom", None, at), chat("ig-u", "Instagram", "Tom", None, at), chat("wa-t", "WhatsApp", "Tom", None, at)];
        assert_eq!(people(&build(&tom, &json!({}))).len(), 3);
    }

    #[test]
    fn handle_with_an_initial_meets_the_one_full_name() {
        let at = "2026-11-12T00:00:00Z";
        let ig = json!({ "id": "ig-v", "type": "single", "network": "Instagram", "lastActivity": at,
            "participants": { "items": [{ "isSelf": true }, { "fullName": "Victor", "username": "victor__k__" }] } });
        let wa = chat("wa-v", "WhatsApp", "Victor Koscher", None, at);
        assert_eq!(people(&build(&[ig.clone(), wa.clone()], &json!({}))), vec![vec!["ig-v", "wa-v"]]);
        let other = chat("wa-w", "WhatsApp", "Victor Kalinski", None, at);
        assert_eq!(people(&build(&[ig, wa, other], &json!({}))).len(), 3);
    }

    #[test]
    fn beeper_merged_parts_stay_one_person() {
        let mut ig = chat("ig-eliot", "Instagram", "eliot.g", None, "2026-11-12T00:00:00Z");
        let mut sms = chat("sms-eliot", "Google Messages", "06 11 22 33 44", Some("0611223344"), "2026-11-01T00:00:00Z");
        ig["mergedInto"] = json!("!union");
        sms["mergedInto"] = json!("!union");
        assert_eq!(people(&build(&[ig.clone(), sms.clone()], &json!({}))), vec![vec!["ig-eliot", "sms-eliot"]]);
        assert_eq!(people(&build(&[ig, sms], &json!({ "splits": ["sms-eliot"] }))).len(), 2);
    }

    #[test]
    fn small_groups_show_members() {
        let g = |net: &str, total: u64, img: Option<&str>| json!({ "id": "g", "type": "group", "network": net, "imgURL": img,
            "participants": { "total": total, "items": [{ "isSelf": true, "imgURL": "mxc://me" }, { "id": "@a", "imgURL": "mxc://a" }, { "id": "@b", "imgURL": "mxc://b" }, { "id": "@c", "imgURL": "mxc://c" }] } });
        let mut pic_of = HashMap::new();
        assert_eq!(faces(&g("Discord", 30, Some("mxc://group")), &pic_of), vec!["mxc://a", "mxc://b", "mxc://c"]);
        pic_of.insert("@b".to_string(), "data:mine".to_string());
        assert_eq!(faces(&g("Discord", 30, None), &pic_of), vec!["mxc://a", "data:mine", "mxc://c"]);
    }

    #[test]
    fn picture_set_by_hand_comes_first() {
        let out = build(&fixture(), &json!({ "pictures": { "sms-lea": "data:image/jpeg;base64,AA", "grp": "data:image/png;base64,BB" } }));
        let lea = out["people"].as_array().unwrap().iter().find(|p| p["id"] == "ig-lea").unwrap();
        assert_eq!(lea["imgs"][0], "data:image/jpeg;base64,AA");
        assert_eq!(out["groups"][0]["imgs"], json!(["data:image/png;base64,BB"]));
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
