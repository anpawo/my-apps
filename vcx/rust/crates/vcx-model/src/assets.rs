//! What the page may load besides the template: chart pages and the user's pictures, each under a name the core gave
//! it. The page cannot name a file of its own: only what a view registered is served.

use std::collections::{HashMap, VecDeque};
use std::hash::{DefaultHasher, Hash, Hasher};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};

/// The most entries of each kind kept; the oldest goes first. A thread of thousands of rows keeps its last charts.
const MAX_ENTRIES: usize = 512;

struct Registry<T> {
    entries: HashMap<String, T>,
    order: VecDeque<String>,
}

impl<T: Clone> Registry<T> {
    fn new() -> Self {
        Self { entries: HashMap::new(), order: VecDeque::new() }
    }

    fn insert(&mut self, id: String, value: T) -> String {
        if !self.entries.contains_key(&id) {
            self.order.push_back(id.clone());
            if self.order.len() > MAX_ENTRIES {
                let oldest = self.order.pop_front().expect("a full registry has an oldest entry");
                self.entries.remove(&oldest);
            }
        }
        self.entries.insert(id.clone(), value);
        id
    }

    fn get(&self, id: &str) -> Option<T> {
        self.entries.get(id).cloned()
    }
}

fn charts() -> &'static Mutex<Registry<Arc<str>>> {
    static CHARTS: OnceLock<Mutex<Registry<Arc<str>>>> = OnceLock::new();
    CHARTS.get_or_init(|| Mutex::new(Registry::new()))
}

fn images() -> &'static Mutex<Registry<PathBuf>> {
    static IMAGES: OnceLock<Mutex<Registry<PathBuf>>> = OnceLock::new();
    IMAGES.get_or_init(|| Mutex::new(Registry::new()))
}

/// The same text always gets the same name, so a redrawn row keeps its frame's address and the frame is not loaded again.
fn name(kind: &str, text: &str) -> String {
    let mut hasher = DefaultHasher::new();
    (kind, text).hash(&mut hasher);
    format!("{:016x}", hasher.finish())
}

/// Registers the HTML of a chart block and gives the name it is served under, `vcx://chart/<name>`.
pub fn chart(html: &str) -> String {
    charts().lock().unwrap().insert(name("chart", html), Arc::from(html))
}

pub fn chart_page(id: &str) -> Option<Arc<str>> {
    charts().lock().unwrap().get(id)
}

/// Registers a picture the user attached and gives the name it is served under, `vcx://image/<name>`.
pub fn image(path: &str) -> String {
    images().lock().unwrap().insert(name("image", path), PathBuf::from(path))
}

pub fn image_path(id: &str) -> Option<PathBuf> {
    images().lock().unwrap().get(id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serves_a_registered_chart_under_a_stable_name() {
        let first = chart("<p>one</p>");

        let again = chart("<p>one</p>");

        assert_eq!(first, again);
        assert_eq!(chart_page(&first).as_deref(), Some("<p>one</p>"));
        assert_eq!(chart_page("0000000000000000"), None);
    }

    #[test]
    fn serves_only_pictures_a_view_registered() {
        let id = image("/tmp/shot.png");

        assert_eq!(image_path(&id), Some(PathBuf::from("/tmp/shot.png")));
        assert_eq!(image_path("etc-passwd"), None);
    }

    #[test]
    fn forgets_the_oldest_entry_past_the_limit() {
        let mut registry = Registry::new();
        for index in 0..=MAX_ENTRIES {
            registry.insert(index.to_string(), index);
        }

        assert_eq!(registry.get("0"), None);
        assert_eq!(registry.get(&MAX_ENTRIES.to_string()), Some(MAX_ENTRIES));
    }
}
