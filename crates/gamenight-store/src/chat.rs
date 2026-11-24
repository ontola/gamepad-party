//! The chat of a player's own game: what they asked the Assistant and what
//! came of it, one atomic_lib [`ChatLog`](atomic_lib::urls::CHAT_LOG) page
//! per project (its child), so the conversation goes wherever the game goes.
//!
//! Entries are Atomic's chat-log entries (`a` author, `t` text, `c` created
//! at in ms) with `role` (`user` or `assistant`, as in Atomic's AI chat) and,
//! for an answer, `ok`. Every answer is an iteration: [`Store::restore_project`]
//! puts the game's files back as they were right after it, as a new edit, so
//! a restore can itself be undone.

use std::collections::BTreeMap;

use atomic_lib::chat_log::Entry;
use atomic_lib::loro::AtomicLoroDoc;
use atomic_lib::{urls, Resource, Storelike};
use loro::LoroValue;

use crate::projects::PROJECT_FILE;
use crate::{atomic, Result, Store};

/// One message in a game's chat.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct ChatEntry {
    pub key: String,
    /// `user` or `assistant`.
    pub role: String,
    pub text: String,
    /// Milliseconds since the Unix epoch.
    pub at: i64,
    /// For an answer: whether the change worked.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ok: Option<bool>,
}

const FILE_PATH: &str = "https://gamenight.ontola.io/ns/path";
const FILE_TEXT: &str = "https://gamenight.ontola.io/ns/text";
const FILE_REMOVED: &str = "https://gamenight.ontola.io/ns/removed";
/// The entries a chat keeps; older ones go.
const MAX_ENTRIES: usize = 400;
/// The longest message kept.
const MAX_TEXT: usize = 8_000;

fn text_field(entry: &LoroValue, name: &str) -> Option<String> {
    match entry {
        LoroValue::Map(m) => match m.get(name) {
            Some(LoroValue::String(s)) => Some(s.to_string()),
            _ => None,
        },
        _ => None,
    }
}

fn entry_of(key: &str, value: &LoroValue) -> ChatEntry {
    let ok = match value {
        LoroValue::Map(m) => match m.get("ok") {
            Some(LoroValue::Bool(b)) => Some(*b),
            _ => None,
        },
        _ => None,
    };
    ChatEntry {
        key: key.to_string(),
        role: text_field(value, "role").unwrap_or_else(|| "user".into()),
        text: atomic_lib::chat_log::entry_text(value)
            .unwrap_or_default()
            .to_string(),
        at: atomic_lib::chat_log::entry_created_at(value).unwrap_or_default(),
        ok,
    }
}

fn cut(text: &str) -> String {
    match text.char_indices().nth(MAX_TEXT) {
        Some((i, _)) => format!("{}…", &text[..i]),
        None => text.to_string(),
    }
}

impl Store {
    async fn project_subject(&self, owner: &str, id: &str) -> Result<String> {
        Ok(self
            .projects(owner)
            .await?
            .into_iter()
            .find(|p| p.id == id)
            .ok_or_else(|| format!("{owner} has no project {id}"))?
            .subject)
    }

    /// The project's chat page, made the first time it is needed.
    async fn chat_page(&self, project: &str, make: bool) -> Result<Option<Resource>> {
        let mut pages = self
            .db
            .get_children(project, Some(urls::CHAT_LOG))
            .await
            .map_err(atomic)?;
        // Two devices may each have made one before they synced: the oldest
        // by subject is the one both use from then on.
        pages.sort_by(|a, b| {
            a.get_subject()
                .to_string()
                .cmp(&b.get_subject().to_string())
        });
        if let Some(page) = pages.into_iter().next() {
            // A listed resource has no Loro document; the stored one has
            // the entries.
            let subject = page.get_subject().to_string();
            return Ok(Some(
                self.db
                    .get_resource(&subject.as_str().into())
                    .await
                    .map_err(atomic)?,
            ));
        }
        if !make {
            return Ok(None);
        }
        let subject = self
            .db
            .create_resource(urls::CHAT_LOG, project, "Chat", None)
            .await
            .map_err(atomic)?;
        self.db.flush().map_err(atomic)?;
        Ok(Some(
            self.db
                .get_resource(&subject.as_str().into())
                .await
                .map_err(atomic)?,
        ))
    }

    /// `owner`'s chat about project `id`, oldest first.
    pub async fn chat(&self, owner: &str, id: &str) -> Result<Vec<ChatEntry>> {
        let project = self.project_subject(owner, id).await?;
        let Some(mut page) = self.chat_page(&project, false).await? else {
            return Ok(Vec::new());
        };
        let doc: &AtomicLoroDoc = page.live_doc().map_err(atomic)?;
        let mut entries: Vec<ChatEntry> = doc
            .list_entries()
            .iter()
            .map(|(k, v)| entry_of(k, v))
            .collect();
        entries.sort_by(|a, b| a.at.cmp(&b.at).then(a.key.cmp(&b.key)));
        Ok(entries)
    }

    /// Add a message to `owner`'s chat about project `id`: `role` is `user`
    /// or `assistant`, `ok` whether an answer's change worked. Returns its key.
    pub async fn add_chat(
        &mut self,
        owner: &str,
        id: &str,
        role: &str,
        text: &str,
        ok: Option<bool>,
    ) -> Result<String> {
        if !matches!(role, "user" | "assistant") {
            return Err(format!("{role} is not a chat role").into());
        }
        let project = self.project_subject(owner, id).await?;
        let mut page = self
            .chat_page(&project, true)
            .await?
            .ok_or("No chat page")?;
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        let author = self.agent().unwrap_or_default();
        let mut entry = Entry::new(author, cut(text), now);
        entry.extra.insert("role".into(), role.into());
        if let Some(ok) = ok {
            entry.extra.insert("ok".into(), LoroValue::Bool(ok));
        }
        let doc = page.live_doc().map_err(atomic)?;
        let key = doc.add_entry(&entry).map_err(atomic)?;
        let mut keys: Vec<String> = doc.entries().into_keys().collect();
        keys.sort();
        let extra = keys.len().saturating_sub(MAX_ENTRIES);
        for old in &keys[..extra] {
            doc.remove_entry(old).map_err(atomic)?;
        }
        page.save_locally(&self.db).await.map_err(atomic)?;
        self.db.flush().map_err(atomic)?;
        Ok(key)
    }

    /// Put `owner`'s project `id` back as it was at `at` (ms since the Unix
    /// epoch, such as an answer's time): each file gets the text it had then,
    /// files made later are removed. A new edit, so the history keeps both.
    /// Returns how many files changed.
    pub async fn restore_project(&mut self, owner: &str, id: &str, at: i64) -> Result<usize> {
        let project = self.project_subject(owner, id).await?;
        let at_seconds = at.div_euclid(1000);
        let mut back: BTreeMap<String, String> = BTreeMap::new();
        for listed in self
            .db
            .get_children(&project, Some(PROJECT_FILE))
            .await
            .map_err(atomic)?
        {
            // As with the chat page: the stored resource has the history.
            let mut file = self
                .db
                .get_resource(&listed.get_subject().to_string().as_str().into())
                .await
                .map_err(atomic)?;
            let Ok(path) = file.get(FILE_PATH).map(|p| p.to_string()) else {
                continue;
            };
            let doc = file.live_doc().map_err(atomic)?;
            // The latest change at or before `at` is its state then. Several
            // changes can share a second; the Lamport clock orders them.
            let Some(version) = doc
                .get_history()
                .into_iter()
                .filter(|v| v.timestamp <= at_seconds)
                .max_by_key(|v| (v.timestamp, v.lamport))
            else {
                continue; // made after `at`
            };
            let then = doc.get_properties_at(&version.id).map_err(atomic)?;
            if matches!(then.get(FILE_REMOVED), Some(LoroValue::Bool(true))) {
                continue;
            }
            if let Some(LoroValue::String(text)) = then.get(FILE_TEXT) {
                back.insert(path, text.to_string());
            }
        }
        if back.is_empty() {
            return Err("The game had no files then".into());
        }
        let changed = self.save_files_of(&project, &back).await?;
        self.db.flush().map_err(atomic)?;
        Ok(changed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn temp() -> PathBuf {
        std::env::temp_dir().join(format!("gamenight-chat-{}", uuid::Uuid::new_v4()))
    }

    #[tokio::test]
    async fn a_games_chat_keeps_each_iteration_and_goes_back_to_one() {
        let (dir, folder) = (temp(), temp());
        let mut store = Store::open(&dir).await.unwrap();
        let owner = store.agent().unwrap();
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::write(
            folder.join("game.toml"),
            "id = \"penguins\"\ntitle = \"Penguins\"\n",
        )
        .unwrap();
        std::fs::write(folder.join("main.luau"), "local WIN = 12\n").unwrap();
        store.save_project(&owner, &folder).await.unwrap();
        assert!(store.chat(&owner, "penguins").await.unwrap().is_empty());

        store
            .add_chat(&owner, "penguins", "user", "Win with 5 coins", None)
            .await
            .unwrap();
        // The Assistant's change, then its answer: the first iteration.
        std::fs::write(folder.join("main.luau"), "local WIN = 5\n").unwrap();
        store.save_project(&owner, &folder).await.unwrap();
        store
            .add_chat(
                &owner,
                "penguins",
                "assistant",
                "You now win with 5.",
                Some(true),
            )
            .await
            .unwrap();
        let first = store.chat(&owner, "penguins").await.unwrap();
        assert_eq!(first.len(), 2);
        assert_eq!(first[0].role, "user");
        assert_eq!(first[1].role, "assistant");
        assert_eq!(first[1].ok, Some(true));
        assert_eq!(first[1].text, "You now win with 5.");

        // History has a resolution of seconds: the next change is later.
        tokio::time::sleep(std::time::Duration::from_millis(2100)).await;
        store
            .add_chat(&owner, "penguins", "user", "Add a shark", None)
            .await
            .unwrap();
        std::fs::write(
            folder.join("main.luau"),
            "local WIN = 5\nlocal SHARK = true\n",
        )
        .unwrap();
        std::fs::write(folder.join("shark.luau"), "return {}\n").unwrap();
        store.save_project(&owner, &folder).await.unwrap();
        store
            .add_chat(
                &owner,
                "penguins",
                "assistant",
                "There is a shark.",
                Some(true),
            )
            .await
            .unwrap();
        assert_eq!(store.chat(&owner, "penguins").await.unwrap().len(), 4);

        // Back to the first iteration: no shark, and the shark file is gone.
        let changed = store
            .restore_project(&owner, "penguins", first[1].at)
            .await
            .unwrap();
        assert_eq!(changed, 2);
        let out = temp();
        store.write_project(&owner, "penguins", &out).await.unwrap();
        assert_eq!(
            std::fs::read_to_string(out.join("main.luau")).unwrap(),
            "local WIN = 5\n"
        );
        assert!(!out.join("shark.luau").exists());
        for d in [dir, folder, out] {
            let _ = std::fs::remove_dir_all(d);
        }
    }
}
