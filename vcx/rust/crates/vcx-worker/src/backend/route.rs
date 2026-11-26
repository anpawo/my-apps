//! The Swift `Session`'s project routing: a window opened at `/` or `~` starts its first task in the task's project,
//! `/` when none fits; each later prompt asks again while it stays at `/`. The prompt is already in the chat; the
//! agent moves to its project behind it.

use super::SessionBackend;
use crate::project;
use crate::session::Outgoing;
use serde_json::json;
use std::rc::Rc;
use std::time::Duration;
use tokio::sync::watch;
use vcx_config::Account;

/// The router takes 2 to 3 s; started this long after the draft last changed, Enter rarely waits on it.
const GUESS_DELAY: Duration = Duration::from_millis(500);
const ROOT: &str = "/";
const CHOOSING: &str = "Choosing the project…";
const WORKING: &str = "Working…";

/// A route asked while the prompt was typed: its text, and the answer once the router gave it.
pub(super) struct Guess {
    text: String,
    route: watch::Receiver<Option<Option<String>>>,
}

fn home() -> String {
    vcx_config::homes::home_directory().to_string_lossy().into_owned()
}

impl SessionBackend {
    /// The session's Claude account, else his first enabled one, else the default Claude login.
    fn route_account(&self) -> Account {
        let current = self.current_account();
        if current.provider == "claude" {
            return current;
        }
        self.settings().accounts().into_iter().find(|account| account.provider == "claude" && account.enabled).unwrap_or_else(|| crate::provider::built_in("claude"))
    }

    async fn ask_router(&self, prompts: Vec<String>) -> Option<String> {
        let (router, account) = (self.config.router.clone(), self.route_account());
        project::route(&router, &prompts, &account, &vcx_config::homes::home_directory()).await
    }

    /// The prompts sent before `text` when sending it asks the router.
    pub(super) fn routing(&self, text: &str, retry: bool) -> Option<Vec<String>> {
        let session = self.session.borrow();
        (!self.config.router.is_empty() && !retry && !session.busy && !text.is_empty() && session.routable(&home())).then(|| session.sent_prompts())
    }

    /// The Swift `guessProject`: the route of the draft being typed, asked once it rests.
    pub(super) fn guess_project(self: &Rc<Self>) {
        if let Some(delay) = self.guess_delay.borrow_mut().take() {
            delay.abort();
        }
        let text = {
            let session = self.session.borrow();
            if self.config.router.is_empty() || session.busy || !session.routable(&home()) {
                return;
            }
            session.draft.iter().filter_map(|piece| piece.get("text").and_then(serde_json::Value::as_str)).collect::<String>().trim().to_owned()
        };
        if text.is_empty() || text.starts_with('/') || self.project_guess.borrow().as_ref().is_some_and(|guess| guess.text == text) {
            return;
        }
        let backend = Rc::clone(self);
        let delay = tokio::task::spawn_local(async move {
            tokio::time::sleep(GUESS_DELAY).await;
            let mut prompts = backend.session.borrow().sent_prompts();
            prompts.push(text.clone());
            let (sender, route) = watch::channel(None);
            *backend.project_guess.borrow_mut() = Some(Guess { text, route });
            let (router, account) = (backend.config.router.clone(), backend.route_account());
            // Not under the delay's handle: a later keystroke cancels the wait, never a route already asked.
            tokio::task::spawn_local(async move {
                let route = project::route(&router, &prompts, &account, &vcx_config::homes::home_directory()).await;
                let _ = sender.send(Some(route));
            });
        });
        *self.guess_delay.borrow_mut() = Some(delay);
    }

    /// The Swift `projectRoute`: a guess from three quarters of the prompt stands, its last words rarely change the project.
    async fn project_route(&self, prompt: &str, earlier: &[String]) -> Option<String> {
        if let Some(delay) = self.guess_delay.borrow_mut().take() {
            delay.abort();
        }
        let guess = self.project_guess.borrow_mut().take();
        let text = prompt.trim();
        let fits = |guess: &Guess| text.starts_with(&guess.text) && guess.text.chars().count() * 4 >= text.chars().count() * 3;
        if let Some(mut route) = guess.filter(fits).map(|guess| guess.route) {
            if let Ok(answer) = route.wait_for(Option::is_some).await {
                return (*answer).clone().flatten();
            }
        }
        self.ask_router(earlier.iter().cloned().chain(std::iter::once(text.to_owned())).collect()).await
    }

    /// Moves the session to the project `text` is about before `outgoing` goes: a chat that already holds prompts is
    /// told to cd there, a first prompt starts a new agent in it.
    pub(super) async fn route(self: &Rc<Self>, outgoing: &mut Outgoing, text: &str, earlier: &[String]) -> Result<(), String> {
        self.session.borrow_mut().status = CHOOSING.into();
        self.schedule();
        let project = self.project_route(text, earlier).await.unwrap_or_else(|| ROOT.into());
        if project == self.session.borrow().cwd {
            self.session.borrow_mut().status = WORKING.into();
            return Ok(());
        }
        if earlier.is_empty() {
            return self.reopen_in(outgoing, &project).await;
        }
        // The agent already holds the chat where it stands: it is told to cd, as a session that found its project itself.
        if let Some(input) = outgoing.params["input"].as_array_mut() {
            input.insert(0, json!({"type": "text", "text": format!("This chat's project folder is {project}: cd there before working on it.")}));
        }
        outgoing.params["cwd"] = json!(project);
        let moved = self.session.borrow_mut().move_directory(&project);
        self.session.borrow_mut().status = WORKING.into();
        self.run_effects(vec![moved]);
        Ok(())
    }

    async fn reopen_in(self: &Rc<Self>, outgoing: &mut Outgoing, project: &str) -> Result<(), String> {
        let (previous, stopping) = {
            let mut session = self.session.borrow_mut();
            let previous = (session.cwd.clone(), session.conversation_directory.clone());
            session.cwd = project.to_owned();
            session.conversation_directory = project.to_owned();
            session.clear_repository();
            (previous, session.stop_requested)
        };
        if let Err(error) = self.activate(&self.current_account(), None, None).await {
            let mut session = self.session.borrow_mut();
            (session.cwd, session.conversation_directory) = previous;
            return Err(error);
        }
        {
            let mut session = self.session.borrow_mut();
            session.injected_context.clear();
            session.busy = true;
            session.stop_requested = stopping;
            session.status = WORKING.into();
            outgoing.params["threadId"] = json!(session.thread_id.clone().unwrap_or_default());
            outgoing.params["cwd"] = json!(session.cwd);
        }
        let backend = Rc::clone(self);
        self.detach(async move { backend.refresh_catalog().await });
        Ok(())
    }
}
