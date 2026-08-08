use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashMap, VecDeque},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::io::{self, AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::sync::{OnceCell, OwnedSemaphorePermit, Semaphore, mpsc};
use tokio::task::{JoinError, JoinSet};
use tokio::time::{Instant, sleep_until};

const GIT_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_CONCURRENT_GIT_REQUESTS: usize = 4;
const MAX_REQUEST_PATH_BYTES: usize = 4096;
// A valid path may expand sixfold when JSON escapes ASCII control bytes. Keep
// enough headroom for the request envelope and a maximum-width u64 request ID.
const MAX_REQUEST_LINE_BYTES: usize = MAX_REQUEST_PATH_BYTES * 6 + 1024;
// Protocol 2 adds the optional per-path `files` map, `files_truncated` and
// `repo_root` to the git_info event, and advertises capabilities on the version
// reply.  Every one of those is additive: a protocol-1 client that ignores them
// still reads the same event it always did.
const PROTOCOL_VERSION: u32 = 2;
// A dirty tree of 200k files must not turn one refresh into a multi-megabyte
// JSON line.  Beyond this many paths the map is cut off and `files_truncated`
// says so, which is honest about the tabline showing fewer marks than there are
// changes.
const MAX_TRACKED_PATHS: usize = 2000;
// Watching is what lets a client stop polling, so the daemon must be the one
// paying for it — and it pays in inotify watch descriptors, a finite per-user
// resource shared with every other program on the machine.  A session that
// visits many repositories therefore keeps only the most recently requested
// directories watched; the rest are withdrawn and go back on the client's poll.
const MAX_WATCHED_DIRS: usize = 16;
// A recursive watch costs one descriptor per directory in the tree.  The
// default /proc/sys/fs/inotify/max_user_watches is 8192 on many distributions,
// so one monorepo could consume the whole quota — for the editor *and* for
// every other watcher the user is running.  A tree bigger than this keeps being
// polled, which is exactly what it did before watching existed.
const MAX_WATCH_TREE_DIRS: usize = 4096;
// A single `git add` or editor save produces a burst of filesystem events.
// Coalescing them into one `git status` is the difference between event-driven
// and event-stormed; the hard deadline keeps a continuously churning tree (a
// build writing into the worktree) from starving the client forever.
const WATCH_QUIET_WINDOW: Duration = Duration::from_millis(200);
const WATCH_HARD_DEADLINE: Duration = Duration::from_millis(1000);
const GIT_REPOSITORY_ENV_VARS: [&str; 8] = [
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_CEILING_DIRECTORIES",
    "GIT_DISCOVERY_ACROSS_FILESYSTEM",
];

#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
enum Request {
    #[serde(rename = "version")]
    Version { id: u64 },
    #[serde(rename = "git_info")]
    GitInfo {
        id: u64,
        path: String,
        // Collecting and serializing every changed path is only worth it when
        // the client paints per-file marks, so it is opt-in per request. An
        // older client omits the field entirely.
        #[serde(default)]
        want_files: bool,
    },
    /// Report this directory's changes instead of being asked for them. The
    /// answer is a `watch` event saying whether the watch was granted; a
    /// refusal is a normal outcome and means "keep polling".
    #[serde(rename = "watch")]
    Watch {
        id: u64,
        path: String,
        #[serde(default)]
        want_files: bool,
    },
    #[serde(rename = "unwatch")]
    Unwatch { id: u64, path: String },
}

#[derive(Debug, Serialize)]
#[serde(tag = "type")]
enum Event {
    #[serde(rename = "version")]
    Version {
        id: u64,
        version: &'static str,
        protocol: u32,
        // The supervisor stores this as a dictionary and answers HasCap() from
        // it, so a client can ask for a feature by name instead of inferring it
        // from a version number.
        capabilities: BTreeMap<&'static str, bool>,
    },
    #[serde(rename = "git_info")]
    GitInfo {
        id: u64,
        path: String,
        branch: String,
        dirty: bool,
        added: u32,
        modified: u32,
        deleted: u32,
        conflicts: u32,
        stash: u32,
        operation: String,
        ahead: u32,
        behind: u32,
        is_git: bool,
        // Repository-relative path -> one of 'M', 'A', 'D', 'U'. Empty unless
        // the request asked for it.
        files: BTreeMap<String, char>,
        files_truncated: bool,
        // Absolute worktree root the paths above are relative to.
        repo_root: String,
    },
    /// Whether `path` is being watched. Sent as the reply to a watch/unwatch
    /// request, and unsolicited with `id: 0` when the daemon withdraws a watch
    /// it had granted — the client must then resume polling that directory.
    #[serde(rename = "watch")]
    Watch {
        id: u64,
        path: String,
        watching: bool,
    },
    #[serde(rename = "error")]
    Error { id: u64, message: String },
}

async fn stdout_writer<W>(mut out: W, mut rx: tokio::sync::mpsc::Receiver<String>) -> io::Result<()>
where
    W: AsyncWrite + Unpin,
{
    while let Some(line) = rx.recv().await {
        out.write_all(line.as_bytes()).await?;
        out.write_all(b"\n").await?;
        out.flush().await?;
    }
    Ok(())
}

type EventTx = tokio::sync::mpsc::Sender<String>;

/// Features a client may ask for by name rather than infer from a version
/// number. The supervisor keeps this dictionary and answers `HasCap()` from it,
/// and `HasCap()` is truthiness-based, so advertising `watch: false` on a
/// platform whose watcher would not start reads as "unavailable" rather than as
/// a missing key — the client keeps polling either way.
fn capabilities(watching: bool) -> BTreeMap<&'static str, bool> {
    BTreeMap::from([("git-status", true), ("watch", watching)])
}

async fn send_event(out: &EventTx, evt: &Event) {
    if let Ok(line) = serde_json::to_string(evt) {
        let _ = out.send(line).await;
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct GitStatus {
    branch: String,
    dirty: bool,
    added: u32,
    modified: u32,
    deleted: u32,
    conflicts: u32,
    stash: u32,
    operation: String,
    ahead: u32,
    behind: u32,
    is_git: bool,
    files: BTreeMap<String, char>,
    files_truncated: bool,
    repo_root: String,
}

fn parse_ab_count(value: Option<&str>, prefix: char) -> u32 {
    value
        .and_then(|value| value.strip_prefix(prefix))
        .and_then(|value| value.parse().ok())
        .unwrap_or(0)
}

fn short_detached_oid(oid: &str) -> String {
    if oid.is_empty() || oid == "(initial)" {
        return String::new();
    }
    format!(":{}", oid.chars().take(7).collect::<String>())
}

fn ordinary_change_mark(xy: &str) -> char {
    if xy.bytes().any(|status| status == b'A') {
        'A'
    } else if xy.bytes().any(|status| status == b'D') {
        'D'
    } else {
        'M'
    }
}

fn count_ordinary_change(status: &mut GitStatus, xy: &str) {
    match ordinary_change_mark(xy) {
        'A' => status.added = status.added.saturating_add(1),
        'D' => status.deleted = status.deleted.saturating_add(1),
        _ => status.modified = status.modified.saturating_add(1),
    }
    status.dirty = true;
}

/// The path field of a porcelain-v2 record, given how many space-separated
/// fields precede it.
///
/// A path may contain spaces, so the remainder of the line is taken whole; a
/// rename record appends the original path after a TAB, and only the current
/// name is of interest here.
fn record_path(record: &str, leading_fields: usize) -> Option<&str> {
    let mut rest = record;
    for _ in 0..leading_fields {
        rest = rest.split_once(' ')?.1;
    }
    let path = rest.split('\t').next().unwrap_or(rest);
    (!path.is_empty()).then_some(path)
}

fn track_path(status: &mut GitStatus, path: Option<&str>, mark: char) {
    let Some(path) = path else { return };
    // Git still quotes a path containing control characters even with
    // core.quotePath=false. Matching one against a buffer name would need a
    // full C-unquote, and marking the wrong file is worse than marking none.
    if path.starts_with('"') {
        return;
    }
    if status.files.len() >= MAX_TRACKED_PATHS {
        status.files_truncated = true;
        return;
    }
    status.files.insert(path.to_string(), mark);
}

/// Parse one `git status --porcelain=v2 --branch [--show-stash]` response.
///
/// Rename/copy records are counted as modified because each record represents
/// one logical worktree entry, untracked entries are added, and unmerged
/// records are reported separately as conflicts.
///
/// With `collect_files` the same records also yield a repository-relative path
/// -> mark map. Every path was already being parsed and thrown away; keeping it
/// is what lets a client say *which* of the open buffers is dirty.
fn parse_git_status(stdout: &str, is_git: bool, collect_files: bool) -> GitStatus {
    if !is_git {
        return GitStatus::default();
    }

    let mut status = GitStatus {
        is_git: true,
        ..GitStatus::default()
    };
    let mut oid = "";
    let mut head = "";

    for line in stdout.lines() {
        if let Some(value) = line.strip_prefix("# branch.oid ") {
            oid = value.trim();
            continue;
        }
        if let Some(value) = line.strip_prefix("# branch.head ") {
            head = value.trim();
            continue;
        }
        if let Some(value) = line.strip_prefix("# branch.ab ") {
            let mut counts = value.split_ascii_whitespace();
            status.ahead = parse_ab_count(counts.next(), '+');
            status.behind = parse_ab_count(counts.next(), '-');
            continue;
        }
        if let Some(value) = line.strip_prefix("# stash ") {
            status.stash = value.trim().parse().unwrap_or(0);
            continue;
        }

        // Field counts before the path: 7 for an ordinary record, 8 for a
        // rename/copy (it carries the similarity score too), 9 for an unmerged
        // one, and none for an untracked path.
        if let Some(record) = line.strip_prefix("1 ") {
            let xy = record.split_ascii_whitespace().next().unwrap_or_default();
            count_ordinary_change(&mut status, xy);
            if collect_files {
                track_path(
                    &mut status,
                    record_path(record, 7),
                    ordinary_change_mark(xy),
                );
            }
        } else if let Some(record) = line.strip_prefix("2 ") {
            status.modified = status.modified.saturating_add(1);
            status.dirty = true;
            if collect_files {
                track_path(&mut status, record_path(record, 8), 'M');
            }
        } else if let Some(record) = line.strip_prefix("u ") {
            status.conflicts = status.conflicts.saturating_add(1);
            status.dirty = true;
            if collect_files {
                track_path(&mut status, record_path(record, 9), 'U');
            }
        } else if let Some(record) = line.strip_prefix("? ") {
            status.added = status.added.saturating_add(1);
            status.dirty = true;
            if collect_files {
                track_path(&mut status, record_path(record, 0), 'A');
            }
        }
    }

    status.branch = if head == "(detached)" {
        short_detached_oid(oid)
    } else {
        head.to_string()
    };
    status
}

fn command_dir(path: &str) -> PathBuf {
    let path = Path::new(path);
    if path.is_file() {
        path.parent()
            .unwrap_or_else(|| Path::new("."))
            .to_path_buf()
    } else if path.as_os_str().is_empty() {
        PathBuf::from(".")
    } else {
        path.to_path_buf()
    }
}

/// Where a repository lives, as seen from one path.
#[derive(Debug, Eq, PartialEq)]
struct RepoPaths {
    /// The worktree-specific Git directory: `<root>/.git` for a normal
    /// repository, the location named by the `gitdir:` marker otherwise.
    git_dir: PathBuf,
    /// The directory holding the `.git` marker. Status paths are relative to
    /// it, and it is the worktree root in both layouts — unlike `git_dir`,
    /// which for a linked worktree points inside the main repository.
    worktree_root: PathBuf,
}

/// Find the repository without spawning another Git process. Normal
/// repositories use a `.git/` directory; linked worktrees and submodules use a
/// `gitdir: ...` marker file instead.
fn discover_repo(path: &str) -> Option<RepoPaths> {
    let start = command_dir(path);
    let start = if start.is_absolute() {
        start
    } else {
        std::env::current_dir().ok()?.join(start)
    };
    // `git -C`/current_dir follows directory symlinks. Walk the same physical
    // path here; lexical ancestors can otherwise pick an outer repository's
    // operation sentinel while `git status` reports the symlink target repo.
    // If the physical path cannot be resolved, omitting the operation is safer
    // than falling back to lexical ancestors: those ancestors may belong to a
    // different repository than the directory Git attempted to enter.
    let start = std::fs::canonicalize(&start).ok()?;
    for dir in start.ancestors() {
        let marker = dir.join(".git");
        if marker.is_dir() {
            return Some(RepoPaths {
                git_dir: marker,
                worktree_root: dir.to_path_buf(),
            });
        }
        if marker.is_file() {
            let contents = std::fs::read_to_string(&marker).ok()?;
            let location = contents.trim().strip_prefix("gitdir:")?.trim();
            let location = PathBuf::from(location);
            return Some(RepoPaths {
                git_dir: if location.is_absolute() {
                    location
                } else {
                    dir.join(location)
                },
                worktree_root: dir.to_path_buf(),
            });
        }
    }
    None
}

/// Repository operations are represented by tiny sentinel files/directories
/// inside the Git directory. Reading them keeps the regular refresh at the
/// existing single `git status` process.
fn detect_git_operation(git_dir: &Path) -> String {
    let rebase_apply = git_dir.join("rebase-apply");
    if git_dir.join("rebase-merge").is_dir() {
        return "REBASE".to_string();
    }
    if rebase_apply.is_dir() {
        return if rebase_apply.join("applying").exists() {
            "AM".to_string()
        } else {
            "REBASE".to_string()
        };
    }
    if git_dir.join("MERGE_HEAD").is_file() {
        return "MERGE".to_string();
    }
    if git_dir.join("CHERRY_PICK_HEAD").is_file() {
        return "CHERRY-PICK".to_string();
    }
    if git_dir.join("REVERT_HEAD").is_file() {
        return "REVERT".to_string();
    }
    if git_dir.join("BISECT_LOG").is_file() {
        return "BISECT".to_string();
    }
    // A multi-commit cherry-pick/revert can be between commits, when the HEAD
    // sentinel is absent but the sequencer still owns more work.
    if let Ok(todo) = std::fs::read_to_string(git_dir.join("sequencer/todo"))
        && let Some(action) = todo.split_ascii_whitespace().next()
    {
        return match action {
            "pick" => "CHERRY-PICK".to_string(),
            "revert" => "REVERT".to_string(),
            _ => String::new(),
        };
    }
    String::new()
}

fn git_status_command(path: &str, show_stash: bool) -> tokio::process::Command {
    let mut command = tokio::process::Command::new("git");
    command
        .args([
            // core.quotePath=false keeps non-ASCII paths raw. Quoted paths
            // would need a C-unquote before they could be matched against a
            // buffer name, and a CJK file name is not an edge case.
            "-c",
            "core.quotePath=false",
            "status",
            "--porcelain=v2",
            "--branch",
            "--untracked-files=normal",
        ])
        .current_dir(command_dir(path))
        .env("GIT_OPTIONAL_LOCKS", "0")
        .kill_on_drop(true);
    if show_stash {
        command.arg("--show-stash");
    }
    for variable in GIT_REPOSITORY_ENV_VARS {
        command.env_remove(variable);
    }
    command
}

/// `--show-stash` first appeared in Git 2.15. An unknown flag makes the whole
/// status query fail, so the flag is enabled only after a version probe. On any
/// probe failure a modern Git is assumed.
fn git_version_supports_show_stash(version_text: &str) -> bool {
    let mut numbers = version_text
        .split(|ch: char| !ch.is_ascii_digit())
        .filter(|part| !part.is_empty())
        .map(|part| part.parse::<u32>().unwrap_or(0));
    match (numbers.next(), numbers.next()) {
        (Some(major), Some(minor)) => (major, minor) >= (2, 15),
        _ => true,
    }
}

static SHOW_STASH_SUPPORTED: OnceCell<bool> = OnceCell::const_new();

async fn show_stash_supported() -> bool {
    *SHOW_STASH_SUPPORTED
        .get_or_init(|| async {
            let mut command = tokio::process::Command::new("git");
            command.arg("--version").kill_on_drop(true);
            match tokio::time::timeout(GIT_TIMEOUT, command.output()).await {
                Ok(Ok(output)) if output.status.success() => {
                    git_version_supports_show_stash(&String::from_utf8_lossy(&output.stdout))
                }
                _ => true,
            }
        })
        .await
}

/// What a non-zero `git status` exit means.
///
/// The exit status alone cannot tell "this is not a repository" from "this
/// invocation failed": a concurrent `git gc` rewriting refs, a briefly
/// unavailable mount, a safe.directory complaint or an OOM-killed child all
/// land here too. Reporting `is_git: false` for those wipes a known-good
/// segment — during a rebase, exactly when the operation indicator matters
/// most — so only a path that is genuinely outside any repository is reported
/// as such, and everything else becomes an error the client can ignore while
/// keeping what it already had.
fn interpret_status_failure(
    in_repository: bool,
    path: &str,
    stderr: &str,
) -> Result<GitStatus, String> {
    if !in_repository {
        return Ok(GitStatus::default());
    }
    let detail: String = stderr
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or("no error output")
        .chars()
        .take(200)
        .collect();
    Err(format!("git status failed inside {path}: {detail}"))
}

async fn query_git_status(path: &str, want_files: bool) -> Result<GitStatus, String> {
    let mut command = git_status_command(path, show_stash_supported().await);
    let output = tokio::time::timeout(GIT_TIMEOUT, command.output())
        .await
        .map_err(|_| format!("git status timed out after 5 seconds for {path}"))?
        .map_err(|error| format!("failed to run git status for {path}: {error}"))?;

    if !output.status.success() {
        return interpret_status_failure(
            discover_repo(path).is_some(),
            path,
            &String::from_utf8_lossy(&output.stderr),
        );
    }

    let mut status = parse_git_status(&String::from_utf8_lossy(&output.stdout), true, want_files);
    if let Some(repo) = discover_repo(path) {
        status.operation = detect_git_operation(&repo.git_dir);
        // Reported unconditionally: the client needs it to resolve a buffer
        // path against the paths above, and it costs nothing beyond the walk
        // the operation probe already does.
        status.repo_root = repo.worktree_root.to_string_lossy().into_owned();
    }
    Ok(status)
}

/// The one place a `GitStatus` becomes a wire event, so a solicited reply and a
/// watch push cannot drift into reporting different fields.
fn git_info_event(id: u64, path: String, status: GitStatus) -> Event {
    Event::GitInfo {
        id,
        path,
        branch: status.branch,
        dirty: status.dirty,
        added: status.added,
        modified: status.modified,
        deleted: status.deleted,
        conflicts: status.conflicts,
        stash: status.stash,
        operation: status.operation,
        ahead: status.ahead,
        behind: status.behind,
        is_git: status.is_git,
        files: status.files,
        files_truncated: status.files_truncated,
        repo_root: status.repo_root,
    }
}

async fn handle_git_info(
    id: u64,
    path: String,
    want_files: bool,
    tx: EventTx,
    _permit: OwnedSemaphorePermit,
) {
    match query_git_status(&path, want_files).await {
        Ok(status) => send_event(&tx, &git_info_event(id, path, status)).await,
        Err(message) => send_event(&tx, &Event::Error { id, message }).await,
    }
}

// ---------------------------------------------------------------------------
// Watching
//
// Polling is the client asking "did anything change?" several times a second
// forever; watching is the daemon answering only when something did. The client
// keeps the poll for every directory that is not watched, so every refusal
// below — an unwatchable platform, a tree too large, more repositories than the
// descriptor budget allows — degrades to exactly the behaviour that existed
// before this file learned to watch anything.
// ---------------------------------------------------------------------------

/// One watched client directory: the worktree root notify actually watches
/// (several client directories in one repository share it) and whether that
/// client asked for per-file marks.
#[derive(Clone, Debug)]
struct WatchEntry {
    root: PathBuf,
    want_files: bool,
}

/// Shared with the notify callback thread and the debounce task: the callback
/// maps an event path back to a root through it, the debounce task turns a root
/// back into the client directories that must be re-queried.
type WatchDirs = Arc<Mutex<HashMap<String, WatchEntry>>>;

/// Which watched root owns an event path. Deepest match wins, because a
/// submodule or a nested repository sits inside its parent's tree and its own
/// status is the one that changed.
fn owning_root(dirs: &HashMap<String, WatchEntry>, path: &Path) -> Option<PathBuf> {
    dirs.values()
        .map(|entry| &entry.root)
        .filter(|root| path.starts_with(root))
        .max_by_key(|root| root.components().count())
        .cloned()
}

/// Count directories under `root`, stopping once the answer is known to exceed
/// `limit`. Symlinked directories are not followed: notify does not recurse into
/// them either, and a link pointing back up the tree would not terminate.
fn count_dirs_bounded(root: &Path, limit: usize) -> usize {
    let mut stack = vec![root.to_path_buf()];
    let mut seen = 0usize;
    while let Some(dir) = stack.pop() {
        seen += 1;
        if seen > limit {
            return seen;
        }
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            if entry.file_type().is_ok_and(|kind| kind.is_dir()) {
                stack.push(entry.path());
            }
        }
    }
    seen
}

struct WatchService {
    watcher: RecommendedWatcher,
    dirs: WatchDirs,
    /// Watched client directories, oldest request first. The cap is on watch
    /// descriptors, so the eviction order is by age of the request.
    order: VecDeque<String>,
    /// Distinct roots handed to notify, with how many client directories still
    /// need each. Two buffers in the same repository must not cost two
    /// recursive watches, and unwatching one must not blind the other.
    roots: HashMap<PathBuf, usize>,
}

impl WatchService {
    /// `None` when the platform watcher cannot be created — a container with no
    /// inotify quota left, a filesystem that supports no notifications. The
    /// caller must then leave the `watch` capability unadvertised.
    fn start(out: EventTx) -> Option<WatchService> {
        let dirs: WatchDirs = Arc::new(Mutex::new(HashMap::new()));
        let (raw_tx, raw_rx) = mpsc::unbounded_channel::<PathBuf>();
        let callback_dirs = Arc::clone(&dirs);
        let watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
            // The callback runs on notify's own thread; an unbounded channel is
            // what lets it hand work to the runtime without blocking it.
            let Ok(event) = event else {
                return;
            };
            let Ok(map) = callback_dirs.lock() else {
                return;
            };
            for path in &event.paths {
                if let Some(root) = owning_root(&map, path) {
                    // A send failure means the daemon is shutting down.
                    let _ = raw_tx.send(root);
                }
            }
        })
        .ok()?;
        tokio::spawn(debounce_watch_events(raw_rx, Arc::clone(&dirs), out));
        Some(WatchService {
            watcher,
            dirs,
            order: VecDeque::new(),
            roots: HashMap::new(),
        })
    }

    fn is_watched(&self, path: &str) -> bool {
        self.dirs.lock().is_ok_and(|map| map.contains_key(path))
    }

    /// Grant a watch, returning whether it was granted plus the directories
    /// evicted to make room. Refusal is not an error — the client polls.
    fn watch(&mut self, path: &str, want_files: bool) -> (bool, Vec<String>) {
        if self.is_watched(path) {
            self.set_want_files(path, want_files);
            return (true, Vec::new());
        }
        let Some(repo) = discover_repo(path) else {
            // Nothing to watch for: outside a repository the status never
            // changes, so polling it is already almost free.
            return (false, Vec::new());
        };
        let root = repo.worktree_root;
        let mut withdrawn = Vec::new();
        while self.order.len() >= MAX_WATCHED_DIRS {
            let Some(oldest) = self.order.front().cloned() else {
                break;
            };
            self.drop_dir(&oldest);
            withdrawn.push(oldest);
        }
        if !self.roots.contains_key(&root)
            && (count_dirs_bounded(&root, MAX_WATCH_TREE_DIRS) > MAX_WATCH_TREE_DIRS
                || self.watcher.watch(&root, RecursiveMode::Recursive).is_err())
        {
            return (false, withdrawn);
        }
        let Ok(mut map) = self.dirs.lock() else {
            return (false, withdrawn);
        };
        map.insert(
            path.to_string(),
            WatchEntry {
                root: root.clone(),
                want_files,
            },
        );
        drop(map);
        *self.roots.entry(root).or_insert(0) += 1;
        self.order.push_back(path.to_string());
        (true, withdrawn)
    }

    fn set_want_files(&self, path: &str, want_files: bool) {
        if let Ok(mut map) = self.dirs.lock()
            && let Some(entry) = map.get_mut(path)
        {
            entry.want_files = want_files;
        }
    }

    /// Forget one client directory, releasing the notify watch once no other
    /// directory in the same repository still needs it.
    fn drop_dir(&mut self, path: &str) -> bool {
        let removed = match self.dirs.lock() {
            Ok(mut map) => map.remove(path),
            Err(_) => return false,
        };
        let Some(entry) = removed else {
            return false;
        };
        self.order.retain(|watched| watched != path);
        if let Some(remaining) = self.roots.get_mut(&entry.root) {
            *remaining -= 1;
            if *remaining == 0 {
                self.roots.remove(&entry.root);
                let _ = self.watcher.unwatch(&entry.root);
            }
        }
        true
    }
}

/// Coalesce raw filesystem events per repository root and re-query Git once the
/// tree has been quiet for `WATCH_QUIET_WINDOW`, or once `WATCH_HARD_DEADLINE`
/// has passed for a tree that never goes quiet.
async fn debounce_watch_events(
    mut rx: mpsc::UnboundedReceiver<PathBuf>,
    dirs: WatchDirs,
    out: EventTx,
) {
    // root -> (earliest time it may fire, latest time it may wait)
    let mut pending: HashMap<PathBuf, (Instant, Instant)> = HashMap::new();
    // Only a *changed* status is worth a line on the wire: `git status` runs
    // after every burst, and a build touching files it does not track would
    // otherwise push an identical payload every second.
    let mut last: HashMap<String, GitStatus> = HashMap::new();

    loop {
        let wake = pending
            .values()
            .map(|(quiet, hard)| (*quiet).min(*hard))
            .min();
        tokio::select! {
            received = rx.recv() => match received {
                Some(root) => {
                    let now = Instant::now();
                    let slot = pending
                        .entry(root)
                        .or_insert((now, now + WATCH_HARD_DEADLINE));
                    slot.0 = now + WATCH_QUIET_WINDOW;
                }
                // The service was dropped: the daemon is shutting down.
                None => return,
            },
            _ = sleep_until(wake.unwrap_or_else(Instant::now)), if wake.is_some() => {}
        }

        let now = Instant::now();
        let ready: Vec<PathBuf> = pending
            .iter()
            .filter(|(_, (quiet, hard))| *quiet <= now || *hard <= now)
            .map(|(root, _)| root.clone())
            .collect();
        for root in ready {
            pending.remove(&root);
            flush_watched_root(&root, &dirs, &out, &mut last).await;
        }
    }
}

async fn flush_watched_root(
    root: &Path,
    dirs: &WatchDirs,
    out: &EventTx,
    last: &mut HashMap<String, GitStatus>,
) {
    // The lock is taken and released around the awaits, never held across one:
    // the notify callback thread must never wait on a `git status`.
    let targets: Vec<(String, bool)> = match dirs.lock() {
        Ok(map) => map
            .iter()
            .filter(|(_, entry)| entry.root == root)
            .map(|(path, entry)| (path.clone(), entry.want_files))
            .collect(),
        Err(_) => return,
    };
    for (path, want_files) in targets {
        match query_git_status(&path, want_files).await {
            Ok(status) => {
                if last.get(&path) == Some(&status) {
                    continue;
                }
                last.insert(path.clone(), status.clone());
                send_event(out, &git_info_event(0, path, status)).await;
            }
            Err(message) => send_event(out, &Event::Error { id: 0, message }).await,
        }
    }
    let live: Vec<String> = match dirs.lock() {
        Ok(map) => map.keys().cloned().collect(),
        Err(_) => return,
    };
    last.retain(|path, _| live.contains(path));
}

fn validate_request_path(path: &str) -> Result<(), String> {
    if path.trim().is_empty() {
        return Err("git_info path must not be empty".to_string());
    }
    if path.len() > MAX_REQUEST_PATH_BYTES {
        return Err(format!(
            "git_info path exceeds {MAX_REQUEST_PATH_BYTES} bytes"
        ));
    }
    if path.contains('\0') {
        return Err("git_info path must not contain NUL".to_string());
    }
    Ok(())
}

async fn report_request_completion(result: Result<(), JoinError>, tx: &EventTx) {
    if let Err(error) = result {
        send_event(
            tx,
            &Event::Error {
                id: 0,
                message: format!("git request task failed: {error}"),
            },
        )
        .await;
    }
}

fn finish_request_line(mut bytes: Vec<u8>, too_long: bool) -> Result<String, String> {
    if too_long {
        return Err(format!(
            "request line exceeds {MAX_REQUEST_LINE_BYTES} bytes"
        ));
    }
    if bytes.last() == Some(&b'\r') {
        bytes.pop();
    }
    String::from_utf8(bytes).map_err(|_| "request line is not valid UTF-8".to_string())
}

async fn read_request_line<R>(
    reader: &mut BufReader<R>,
) -> io::Result<Option<Result<String, String>>>
where
    R: AsyncRead + Unpin,
{
    let mut bytes = Vec::new();
    let mut too_long = false;

    loop {
        let available = reader.fill_buf().await?;
        if available.is_empty() {
            return if bytes.is_empty() && !too_long {
                Ok(None)
            } else {
                Ok(Some(finish_request_line(bytes, too_long)))
            };
        }

        let newline = available.iter().position(|byte| *byte == b'\n');
        let content_len = newline.unwrap_or(available.len());
        let consumed = newline.map_or(available.len(), |position| position + 1);

        if !too_long {
            if bytes.len().saturating_add(content_len) > MAX_REQUEST_LINE_BYTES {
                too_long = true;
                bytes.clear();
            } else {
                bytes.extend_from_slice(&available[..content_len]);
            }
        }
        reader.consume(consumed);

        if newline.is_some() {
            return Ok(Some(finish_request_line(bytes, too_long)));
        }
    }
}

async fn run<R, W>(input: R, output: W) -> io::Result<()>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin + Send + 'static,
{
    let mut input = BufReader::new(input);

    let (out_tx, out_rx) = tokio::sync::mpsc::channel::<String>(1024);
    let writer = tokio::spawn(stdout_writer(output, out_rx));
    let git_limiter = Arc::new(Semaphore::new(MAX_CONCURRENT_GIT_REQUESTS));
    let mut requests = JoinSet::new();
    // Started eagerly so the handshake can say truthfully whether this daemon
    // can watch at all; the watcher itself costs one file descriptor and no
    // watch descriptors until a directory is actually requested.
    let mut watch_service = WatchService::start(out_tx.clone());

    while let Some(line) = read_request_line(&mut input).await? {
        while let Some(result) = requests.try_join_next() {
            report_request_completion(result, &out_tx).await;
        }

        let line = match line {
            Ok(line) => line,
            Err(message) => {
                send_event(&out_tx, &Event::Error { id: 0, message }).await;
                continue;
            }
        };

        if line.trim().is_empty() {
            continue;
        }
        let req = match serde_json::from_str::<Request>(&line) {
            Ok(r) => r,
            Err(e) => {
                send_event(
                    &out_tx,
                    &Event::Error {
                        id: 0,
                        message: format!("invalid request: {e}"),
                    },
                )
                .await;
                continue;
            }
        };

        match req {
            Request::Version { id } => {
                send_event(
                    &out_tx,
                    &Event::Version {
                        id,
                        version: env!("CARGO_PKG_VERSION"),
                        protocol: PROTOCOL_VERSION,
                        capabilities: capabilities(watch_service.is_some()),
                    },
                )
                .await;
            }
            Request::GitInfo {
                id,
                path,
                want_files,
            } => {
                if let Err(message) = validate_request_path(&path) {
                    send_event(&out_tx, &Event::Error { id, message }).await;
                    continue;
                }
                let permit = match Arc::clone(&git_limiter).acquire_owned().await {
                    Ok(permit) => permit,
                    Err(error) => {
                        send_event(
                            &out_tx,
                            &Event::Error {
                                id,
                                message: format!("git request limiter unavailable: {error}"),
                            },
                        )
                        .await;
                        continue;
                    }
                };
                let tx = out_tx.clone();
                requests.spawn(async move {
                    handle_git_info(id, path, want_files, tx, permit).await;
                });
            }
            Request::Watch {
                id,
                path,
                want_files,
            } => {
                if let Err(message) = validate_request_path(&path) {
                    send_event(&out_tx, &Event::Error { id, message }).await;
                    continue;
                }
                let (watching, withdrawn) = match watch_service.as_mut() {
                    Some(service) => service.watch(&path, want_files),
                    None => (false, Vec::new()),
                };
                // Withdrawals go out before the grant that caused them, so a
                // client never sees itself watching more directories than the
                // daemon admits to.
                for evicted in withdrawn {
                    send_event(
                        &out_tx,
                        &Event::Watch {
                            id: 0,
                            path: evicted,
                            watching: false,
                        },
                    )
                    .await;
                }
                send_event(&out_tx, &Event::Watch { id, path, watching }).await;
            }
            Request::Unwatch { id, path } => {
                if let Some(service) = watch_service.as_mut() {
                    service.drop_dir(&path);
                }
                send_event(
                    &out_tx,
                    &Event::Watch {
                        id,
                        path,
                        watching: false,
                    },
                )
                .await;
            }
        }
    }

    while let Some(result) = requests.join_next().await {
        report_request_completion(result, &out_tx).await;
    }
    // Dropping the service drops the notify callback that owns the raw-event
    // sender, which ends the debounce task, which releases the last clone of
    // the event channel. Without this the writer below would wait for a sender
    // that never goes away and the daemon would never exit.
    drop(watch_service);
    drop(out_tx);

    writer
        .await
        .map_err(|error| io::Error::other(format!("stdout writer task failed: {error}")))?
}

const USAGE: &str = "\
Usage: simpleline-daemon [OPTION]

With no arguments the daemon serves newline-delimited JSON requests on stdin
and writes replies to stdout.  That is how the Vim plugin starts it; there is
nothing useful to do with it interactively.

Options:
  -V, --version    print the version and exit
  -h, --help       print this help and exit
      --self-test  run one request through the daemon in-process and exit
";

/// Drives a real request through [`run`] over in-memory pipes.
///
/// The installer needs to know that the binary it just built actually works,
/// and a version string only proves the file is not corrupt.  This exercises
/// the parse → dispatch → reply path that every request takes.
async fn self_test() -> Result<(), String> {
    use tokio::io::AsyncReadExt;

    let request = format!("{}\n", serde_json::json!({"id": 1, "type": "version"}));

    // `run` spawns its writer task, so the sink has to be owned and 'static —
    // a borrowed Vec will not do.  A duplex pipe gives an owned write half;
    // run drops it on the way out, which is what ends the read below.
    let (mut client, server) = tokio::io::duplex(64 * 1024);
    run(request.as_bytes(), server)
        .await
        .map_err(|error| format!("daemon loop failed: {error}"))?;

    let mut reply = String::new();
    client
        .read_to_string(&mut reply)
        .await
        .map_err(|error| format!("could not read the reply: {error}"))?;
    let first = reply
        .lines()
        .next()
        .ok_or_else(|| "daemon produced no reply".to_string())?;
    let parsed: serde_json::Value =
        serde_json::from_str(first).map_err(|error| format!("reply was not JSON: {error}"))?;

    match parsed.get("protocol").and_then(serde_json::Value::as_u64) {
        Some(version) if version == u64::from(PROTOCOL_VERSION) => Ok(()),
        Some(version) => Err(format!(
            "daemon announced protocol {version}, this build is {PROTOCOL_VERSION}"
        )),
        None => Err(format!("reply carried no protocol version: {first}")),
    }
}

#[tokio::main(flavor = "multi_thread")]
async fn main() -> std::process::ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        None => match run(tokio::io::stdin(), tokio::io::stdout()).await {
            Ok(()) => std::process::ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("simpleline-daemon: {error}");
                std::process::ExitCode::FAILURE
            }
        },
        Some("--version" | "-V") => {
            println!("simpleline-daemon {}", env!("CARGO_PKG_VERSION"));
            std::process::ExitCode::SUCCESS
        }
        Some("--help" | "-h") => {
            println!("simpleline-daemon {}\n\n{USAGE}", env!("CARGO_PKG_VERSION"));
            std::process::ExitCode::SUCCESS
        }
        Some("--self-test") => match self_test().await {
            Ok(()) => {
                println!("ok");
                std::process::ExitCode::SUCCESS
            }
            Err(message) => {
                eprintln!("self-test failed: {message}");
                std::process::ExitCode::FAILURE
            }
        },
        Some(other) => {
            eprintln!("unknown argument: {other}\n\n{USAGE}");
            std::process::ExitCode::from(2)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        Event, GIT_REPOSITORY_ENV_VARS, GitStatus, MAX_REQUEST_LINE_BYTES, MAX_REQUEST_PATH_BYTES,
        MAX_TRACKED_PATHS, MAX_WATCH_TREE_DIRS, PROTOCOL_VERSION, Request, WatchEntry,
        capabilities, count_dirs_bounded, detect_git_operation, discover_repo, git_status_command,
        git_version_supports_show_stash, interpret_status_failure, owning_root, parse_git_status,
        read_request_line, run, validate_request_path,
    };
    use std::collections::{BTreeMap, HashMap};
    use std::path::{Path, PathBuf};
    use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};

    #[test]
    fn parses_normal_branch_and_change_counts() {
        let output = "\
# branch.oid 0123456789abcdef0123456789abcdef01234567
# branch.head main
# branch.upstream origin/main
# branch.ab +0 -0
1 A. N... 000000 100644 100644 0000000 1111111 added.txt
1 .M N... 100644 100644 100644 1111111 2222222 modified.txt
1 D. N... 100644 000000 000000 1111111 0000000 deleted.txt
";

        assert_eq!(
            parse_git_status(output, true, false),
            GitStatus {
                branch: "main".to_string(),
                dirty: true,
                added: 1,
                modified: 1,
                deleted: 1,
                conflicts: 0,
                stash: 0,
                operation: String::new(),
                ahead: 0,
                behind: 0,
                is_git: true,
                ..GitStatus::default()
            }
        );
    }

    #[test]
    fn parses_detached_head_as_short_hash() {
        let output = "\
# branch.oid 0123456789abcdef0123456789abcdef01234567
# branch.head (detached)
";

        let status = parse_git_status(output, true, false);
        assert_eq!(status.branch, ":0123456");
        assert!(status.is_git);
        assert!(!status.dirty);
    }

    #[test]
    fn parses_ahead_and_behind() {
        let output = "\
# branch.oid 0123456789abcdef0123456789abcdef01234567
# branch.head topic
# branch.upstream origin/topic
# branch.ab +12 -3
";

        let status = parse_git_status(output, true, false);
        assert_eq!(status.ahead, 12);
        assert_eq!(status.behind, 3);
    }

    #[test]
    fn counts_rename_as_modified() {
        let output = "\
# branch.oid 0123456789abcdef0123456789abcdef01234567
# branch.head main
2 R. N... 100644 100644 100644 1111111 2222222 R100 new.txt\told.txt
";

        let status = parse_git_status(output, true, false);
        assert_eq!(status.modified, 1);
        assert!(status.dirty);
    }

    #[test]
    fn counts_conflict_separately_from_modified() {
        let output = "\
# branch.oid 0123456789abcdef0123456789abcdef01234567
# branch.head main
u UU N... 100644 100644 100644 100644 1111111 2222222 3333333 conflict.txt
";

        let status = parse_git_status(output, true, false);
        assert_eq!(status.conflicts, 1);
        assert_eq!(status.modified, 0);
        assert!(status.dirty);
    }

    #[test]
    fn parses_stash_header() {
        let output = "\
# branch.oid 0123456789abcdef0123456789abcdef01234567
# branch.head main
# stash 3
";

        let status = parse_git_status(output, true, false);
        assert_eq!(status.stash, 3);
        assert!(!status.dirty);
    }

    #[test]
    fn detects_show_stash_support_from_git_version() {
        assert!(git_version_supports_show_stash("git version 2.15.0"));
        assert!(git_version_supports_show_stash("git version 2.43.5"));
        assert!(git_version_supports_show_stash("git version 3.0.0"));
        assert!(!git_version_supports_show_stash("git version 2.14.9"));
        assert!(!git_version_supports_show_stash("git version 1.9.1"));
        // Unparseable output assumes a modern Git.
        assert!(git_version_supports_show_stash("who knows"));
    }

    #[test]
    fn counts_untracked_as_added() {
        let output = "\
# branch.oid 0123456789abcdef0123456789abcdef01234567
# branch.head main
? untracked file.txt
";

        let status = parse_git_status(output, true, false);
        assert_eq!(status.added, 1);
        assert!(status.dirty);
    }

    #[test]
    fn parses_clean_repository() {
        let output = "\
# branch.oid 0123456789abcdef0123456789abcdef01234567
# branch.head main
# branch.ab +0 -0
";

        assert_eq!(
            parse_git_status(output, true, false),
            GitStatus {
                branch: "main".to_string(),
                is_git: true,
                ..GitStatus::default()
            }
        );
    }

    #[test]
    fn parses_non_git_directory() {
        assert_eq!(parse_git_status("", false, false), GitStatus::default());
    }

    // Every record type carries its path at a different offset, and a path may
    // contain spaces — so the field count, not whitespace splitting, is what
    // finds it.  Getting this wrong marks the wrong buffer, which is worse
    // than marking none.
    #[test]
    fn collects_one_mark_per_changed_path() {
        let output = "\
# branch.oid 0123456789abcdef0123456789abcdef01234567
# branch.head main
1 A. N... 000000 100644 100644 0000000 1111111 added.txt
1 .M N... 100644 100644 100644 1111111 2222222 sub/dir/mod file.txt
1 D. N... 100644 000000 000000 1111111 0000000 gone.txt
2 R. N... 100644 100644 100644 1111111 2222222 R100 new.txt\told.txt
u UU N... 100644 100644 100644 100644 1111111 2222222 3333333 conflict.txt
? untracked file.txt
";

        let status = parse_git_status(output, true, true);
        assert_eq!(
            status.files,
            BTreeMap::from([
                ("added.txt".to_string(), 'A'),
                ("sub/dir/mod file.txt".to_string(), 'M'),
                ("gone.txt".to_string(), 'D'),
                // The current name, not the one it was renamed from.
                ("new.txt".to_string(), 'M'),
                ("conflict.txt".to_string(), 'U'),
                ("untracked file.txt".to_string(), 'A'),
            ])
        );
        assert!(!status.files_truncated);
        // The counters are unchanged by collection.
        assert_eq!(status.added, 2);
        assert_eq!(status.modified, 2);
        assert_eq!(status.deleted, 1);
        assert_eq!(status.conflicts, 1);
    }

    #[test]
    fn skips_path_collection_unless_asked() {
        let output = "\
# branch.oid 0123456789abcdef0123456789abcdef01234567
# branch.head main
1 .M N... 100644 100644 100644 1111111 2222222 modified.txt
";

        let status = parse_git_status(output, true, false);
        assert!(status.files.is_empty());
        assert_eq!(status.modified, 1);
    }

    #[test]
    fn caps_the_path_map_and_reports_the_cut() {
        let mut output = String::from(
            "\
# branch.oid 0123456789abcdef0123456789abcdef01234567
# branch.head main
",
        );
        for index in 0..(MAX_TRACKED_PATHS + 25) {
            output.push_str(&format!(
                "1 .M N... 100644 100644 100644 1111111 2222222 file{index}.txt\n"
            ));
        }

        let status = parse_git_status(&output, true, true);
        assert_eq!(status.files.len(), MAX_TRACKED_PATHS);
        assert!(status.files_truncated);
        // The counters still describe the whole tree, only the map is cut.
        assert_eq!(status.modified as usize, MAX_TRACKED_PATHS + 25);
    }

    #[test]
    fn drops_paths_git_still_quotes() {
        let output = "\
# branch.oid 0123456789abcdef0123456789abcdef01234567
# branch.head main
1 .M N... 100644 100644 100644 1111111 2222222 \"new\\nline.txt\"
1 .M N... 100644 100644 100644 1111111 2222222 plain.txt
";

        let status = parse_git_status(output, true, true);
        assert_eq!(
            status.files,
            BTreeMap::from([("plain.txt".to_string(), 'M')])
        );
        assert_eq!(status.modified, 2);
    }

    #[test]
    fn keeps_non_ascii_paths_unquoted() {
        // core.quotePath=false is what makes this possible; without it Git
        // would emit "sub/b \321\201.txt" and the path would be dropped.
        let command = git_status_command(".", false);
        let args: Vec<_> = command.as_std().get_args().collect();
        let quote_path = args
            .windows(2)
            .any(|pair| pair[0] == "-c" && pair[1] == "core.quotePath=false");
        assert!(quote_path, "got {args:?}");
    }

    #[test]
    fn tells_a_failed_query_apart_from_a_missing_repository() {
        // Outside a repository the empty status is the truth.
        assert_eq!(
            interpret_status_failure(false, "/work/plain", "fatal: not a git repository"),
            Ok(GitStatus::default())
        );

        // Inside one, a failure is only a failure: the client has to keep the
        // branch and operation it already had rather than watch them vanish.
        let error = interpret_status_failure(
            true,
            "/work/repo",
            "\nfatal: unable to read index\nsecond line\n",
        )
        .unwrap_err();
        assert!(error.contains("fatal: unable to read index"), "{error}");
        assert!(!error.contains("second line"), "{error}");

        let quiet = interpret_status_failure(true, "/work/repo", "").unwrap_err();
        assert!(quiet.contains("no error output"), "{quiet}");

        let long = interpret_status_failure(true, "/work/repo", &"x".repeat(500)).unwrap_err();
        assert!(long.len() < 300, "{long}");
    }

    #[test]
    fn reports_the_worktree_root_for_a_linked_worktree() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "simpleline-worktree-root-{}-{unique}",
            std::process::id()
        ));
        let worktree = root.join("worktree");
        let nested = worktree.join("src/nested");
        let git_dir = root.join("metadata");
        std::fs::create_dir_all(&nested).unwrap();
        std::fs::create_dir_all(&git_dir).unwrap();
        std::fs::write(worktree.join(".git"), "gitdir: ../metadata\n").unwrap();

        // The Git directory of a linked worktree lives inside the main
        // repository, so it says nothing about where status paths are rooted;
        // the directory holding the marker does.
        let repo = discover_repo(nested.to_str().unwrap()).unwrap();
        assert_eq!(
            std::fs::canonicalize(&repo.worktree_root).unwrap(),
            std::fs::canonicalize(&worktree).unwrap()
        );
        assert_eq!(
            std::fs::canonicalize(&repo.git_dir).unwrap(),
            std::fs::canonicalize(&git_dir).unwrap()
        );

        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn discovers_linked_git_dirs_and_repository_operations() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "simpleline-operation-{}-{unique}",
            std::process::id()
        ));
        let worktree = root.join("worktree");
        let nested = worktree.join("src/nested");
        let git_dir = root.join("metadata");
        std::fs::create_dir_all(&nested).unwrap();
        std::fs::create_dir_all(&git_dir).unwrap();
        std::fs::write(worktree.join(".git"), "gitdir: ../metadata\n").unwrap();

        let discovered = discover_repo(nested.to_str().unwrap()).unwrap().git_dir;
        assert_eq!(
            std::fs::canonicalize(discovered).unwrap(),
            std::fs::canonicalize(&git_dir).unwrap()
        );

        std::fs::create_dir(git_dir.join("rebase-merge")).unwrap();
        assert_eq!(detect_git_operation(&git_dir), "REBASE");
        std::fs::remove_dir(git_dir.join("rebase-merge")).unwrap();

        std::fs::create_dir_all(git_dir.join("rebase-apply")).unwrap();
        std::fs::write(git_dir.join("rebase-apply/applying"), "").unwrap();
        assert_eq!(detect_git_operation(&git_dir), "AM");
        std::fs::remove_dir_all(git_dir.join("rebase-apply")).unwrap();

        for (sentinel, expected) in [
            ("MERGE_HEAD", "MERGE"),
            ("CHERRY_PICK_HEAD", "CHERRY-PICK"),
            ("REVERT_HEAD", "REVERT"),
            ("BISECT_LOG", "BISECT"),
        ] {
            let path = git_dir.join(sentinel);
            std::fs::write(&path, "state").unwrap();
            assert_eq!(detect_git_operation(&git_dir), expected);
            std::fs::remove_file(path).unwrap();
        }

        std::fs::create_dir(git_dir.join("sequencer")).unwrap();
        std::fs::write(git_dir.join("sequencer/todo"), "pick deadbeef subject\n").unwrap();
        assert_eq!(detect_git_operation(&git_dir), "CHERRY-PICK");

        std::fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn operation_discovery_follows_the_status_workdir_symlink() {
        use std::os::unix::fs::symlink;

        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "simpleline-operation-symlink-{}-{unique}",
            std::process::id()
        ));
        let outer = root.join("outer");
        let target = root.join("target-worktree");
        std::fs::create_dir_all(outer.join(".git")).unwrap();
        std::fs::create_dir_all(target.join(".git")).unwrap();
        std::fs::create_dir_all(target.join("src")).unwrap();
        std::fs::write(outer.join(".git/MERGE_HEAD"), "outer").unwrap();
        std::fs::write(target.join(".git/CHERRY_PICK_HEAD"), "target").unwrap();
        symlink(&target, outer.join("linked")).unwrap();

        let discovered = discover_repo(outer.join("linked/src").to_str().unwrap())
            .unwrap()
            .git_dir;
        assert_eq!(
            std::fs::canonicalize(&discovered).unwrap(),
            std::fs::canonicalize(target.join(".git")).unwrap()
        );
        assert_eq!(detect_git_operation(&discovered), "CHERRY-PICK");

        // Never fall back to the lexical outer repository when the symlink's
        // physical target cannot be resolved. Git cannot enter this directory,
        // so reporting the outer MERGE would be actively misleading.
        symlink(root.join("missing-target"), outer.join("dangling")).unwrap();
        assert_eq!(
            discover_repo(outer.join("dangling/src").to_str().unwrap()),
            None
        );

        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn git_info_event_serializes_request_path() {
        let json = serde_json::to_value(Event::GitInfo {
            id: 42,
            path: "/work/project".to_string(),
            branch: "main".to_string(),
            dirty: false,
            added: 0,
            modified: 0,
            deleted: 0,
            conflicts: 2,
            stash: 1,
            operation: "MERGE".to_string(),
            ahead: 0,
            behind: 0,
            is_git: true,
            files: BTreeMap::from([("src/main.rs".to_string(), 'M')]),
            files_truncated: true,
            repo_root: "/work/project".to_string(),
        })
        .unwrap();

        assert_eq!(json["type"], "git_info");
        assert_eq!(json["id"], 42);
        assert_eq!(json["path"], "/work/project");
        assert_eq!(json["conflicts"], 2);
        assert_eq!(json["stash"], 1);
        assert_eq!(json["operation"], "MERGE");
        assert_eq!(json["files"]["src/main.rs"], "M");
        assert_eq!(json["files_truncated"], true);
        assert_eq!(json["repo_root"], "/work/project");
    }

    #[test]
    fn version_event_reports_package_and_protocol() {
        let json = serde_json::to_value(Event::Version {
            id: 7,
            version: env!("CARGO_PKG_VERSION"),
            protocol: PROTOCOL_VERSION,
            capabilities: capabilities(true),
        })
        .unwrap();

        assert_eq!(json["type"], "version");
        assert_eq!(json["id"], 7);
        assert_eq!(json["version"], env!("CARGO_PKG_VERSION"));
        assert_eq!(json["protocol"], PROTOCOL_VERSION);
        // The supervisor reads capabilities as a dictionary and answers
        // HasCap() from it; a list would be discarded silently.
        assert_eq!(json["capabilities"]["git-status"], true);
        assert_eq!(json["capabilities"]["watch"], true);
    }

    // HasCap() is truthiness-based, so a platform whose watcher will not start
    // has to advertise the key as false rather than omit it — omitting it would
    // read the same to the client, but only by accident.
    #[test]
    fn unavailable_watcher_advertises_the_capability_as_false() {
        let json = serde_json::to_value(Event::Version {
            id: 1,
            version: env!("CARGO_PKG_VERSION"),
            protocol: PROTOCOL_VERSION,
            capabilities: capabilities(false),
        })
        .unwrap();

        assert_eq!(json["capabilities"]["watch"], false);
        assert_eq!(json["capabilities"]["git-status"], true);
    }

    #[test]
    fn rejects_empty_nul_and_oversized_paths() {
        assert!(validate_request_path("").is_err());
        assert!(validate_request_path("  ").is_err());
        assert!(validate_request_path("bad\0path").is_err());
        assert!(validate_request_path(&"x".repeat(4097)).is_err());
        assert!(validate_request_path(&"x".repeat(4096)).is_ok());
    }

    #[test]
    fn show_stash_flag_is_optional() {
        let with_flag = git_status_command(".", true);
        assert!(
            with_flag
                .as_std()
                .get_args()
                .any(|arg| arg == std::ffi::OsStr::new("--show-stash"))
        );
        let without_flag = git_status_command(".", false);
        assert!(
            !without_flag
                .as_std()
                .get_args()
                .any(|arg| arg == std::ffi::OsStr::new("--show-stash"))
        );
    }

    #[test]
    fn clears_repository_override_environment() {
        let command = git_status_command(".", true);
        let environment = command.as_std().get_envs().collect::<Vec<_>>();
        for variable in GIT_REPOSITORY_ENV_VARS {
            assert!(
                environment.iter().any(|(key, value)| {
                    *key == std::ffi::OsStr::new(variable) && value.is_none()
                })
            );
        }
    }

    #[tokio::test]
    async fn drains_accepted_request_after_eof() {
        let path = std::env::current_dir().unwrap();
        let request = serde_json::json!({
            "type": "git_info",
            "id": 77,
            "path": path,
        });
        let (mut request_writer, request_reader) = tokio::io::duplex(4096);
        let (response_writer, mut response_reader) = tokio::io::duplex(4096);
        let runner = tokio::spawn(run(request_reader, response_writer));

        request_writer
            .write_all(format!("{request}\n").as_bytes())
            .await
            .unwrap();
        request_writer.shutdown().await.unwrap();

        let mut response = String::new();
        response_reader.read_to_string(&mut response).await.unwrap();
        runner.await.unwrap().unwrap();

        let event: serde_json::Value = serde_json::from_str(response.trim()).unwrap();
        assert_eq!(event["type"], "git_info");
        assert_eq!(event["id"], 77);
        assert_eq!(event["path"], path.to_string_lossy().as_ref());
    }

    #[tokio::test]
    async fn rejects_oversized_line_and_continues_with_version_request() {
        let (mut request_writer, request_reader) = tokio::io::duplex(16_384);
        let (response_writer, mut response_reader) = tokio::io::duplex(4096);
        let runner = tokio::spawn(run(request_reader, response_writer));

        request_writer
            .write_all(&vec![b'x'; MAX_REQUEST_LINE_BYTES + 1])
            .await
            .unwrap();
        request_writer
            .write_all(b"\n{\"type\":\"version\",\"id\":88}\n")
            .await
            .unwrap();
        request_writer.shutdown().await.unwrap();

        let mut response = String::new();
        response_reader.read_to_string(&mut response).await.unwrap();
        runner.await.unwrap().unwrap();

        let events = response
            .lines()
            .map(|line| serde_json::from_str::<serde_json::Value>(line).unwrap())
            .collect::<Vec<_>>();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0]["type"], "error");
        assert_eq!(events[0]["id"], 0);
        assert_eq!(events[1]["type"], "version");
        assert_eq!(events[1]["id"], 88);
        assert_eq!(events[1]["protocol"], PROTOCOL_VERSION);
    }

    #[tokio::test]
    async fn accepts_maximum_path_after_json_escaping() {
        let path = "\u{1}".repeat(MAX_REQUEST_PATH_BYTES);
        let request = format!(
            "{}\n",
            serde_json::json!({"type": "git_info", "id": 42, "path": path})
        );
        assert!(request.len() > 8192);
        assert!(request.len() <= MAX_REQUEST_LINE_BYTES + 1);

        let mut reader = BufReader::new(request.as_bytes());
        let line = read_request_line(&mut reader)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        match serde_json::from_str::<Request>(&line).unwrap() {
            Request::GitInfo {
                id,
                path,
                want_files,
            } => {
                assert_eq!(id, 42);
                assert_eq!(path.len(), MAX_REQUEST_PATH_BYTES);
                assert!(validate_request_path(&path).is_ok());
                // Absent in the request above: a client that predates per-file
                // status must keep parsing as it always did.
                assert!(!want_files);
            }
            other => panic!("expected git_info request, got {other:?}"),
        }
    }

    // ------------------------------------------------------------- watching --

    fn scratch_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "simpleline-{name}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn entry(root: &str) -> WatchEntry {
        WatchEntry {
            root: PathBuf::from(root),
            want_files: false,
        }
    }

    /// A submodule lives inside its parent's tree, so both roots match one
    /// event path. The change belongs to the inner repository — attributing it
    /// to the outer one would re-query the wrong `git status` and leave the
    /// submodule's own segment frozen.
    #[test]
    fn the_deepest_watched_root_owns_an_event_path() {
        let dirs = HashMap::from([
            ("/work/outer".to_string(), entry("/work/outer")),
            ("/work/outer/sub".to_string(), entry("/work/outer/sub")),
        ]);

        assert_eq!(
            owning_root(&dirs, Path::new("/work/outer/sub/src/lib.rs")),
            Some(PathBuf::from("/work/outer/sub"))
        );
        assert_eq!(
            owning_root(&dirs, Path::new("/work/outer/README.md")),
            Some(PathBuf::from("/work/outer"))
        );
        assert_eq!(owning_root(&dirs, Path::new("/elsewhere/file")), None);
    }

    #[test]
    fn directory_counting_stops_once_the_limit_is_known_to_be_passed() {
        let root = scratch_dir("count");
        for index in 0..5 {
            std::fs::create_dir_all(root.join(format!("d{index}/nested"))).unwrap();
        }

        // 1 root + 5 + 5 nested.
        assert_eq!(count_dirs_bounded(&root, MAX_WATCH_TREE_DIRS), 11);
        // Over the limit the exact count is never computed: the answer is only
        // ever compared against the limit, and walking a monorepo to produce a
        // number nobody reads is the cost this bound exists to avoid.
        assert!(count_dirs_bounded(&root, 3) > 3);

        std::fs::remove_dir_all(&root).unwrap();
    }

    async fn next_event(
        reader: &mut BufReader<tokio::io::DuplexStream>,
    ) -> Option<serde_json::Value> {
        let mut line = String::new();
        let read = tokio::time::timeout(
            std::time::Duration::from_secs(10),
            reader.read_line(&mut line),
        )
        .await
        .ok()?
        .ok()?;
        (read > 0).then(|| serde_json::from_str(line.trim()).unwrap())
    }

    /// Outside a repository there is no status to report and nothing to notice,
    /// so the watch is refused and the client keeps polling — the behaviour it
    /// had before this daemon could watch anything.
    #[tokio::test]
    async fn refuses_to_watch_a_path_outside_any_repository() {
        let dir = scratch_dir("nowatch");
        let (mut request_writer, request_reader) = tokio::io::duplex(4096);
        let (response_writer, response_reader) = tokio::io::duplex(65_536);
        let runner = tokio::spawn(run(request_reader, response_writer));
        let mut reader = BufReader::new(response_reader);

        let request = serde_json::json!({"type": "watch", "id": 9, "path": dir});
        request_writer
            .write_all(format!("{request}\n").as_bytes())
            .await
            .unwrap();

        let event = next_event(&mut reader).await.unwrap();
        assert_eq!(event["type"], "watch");
        assert_eq!(event["id"], 9);
        assert_eq!(event["watching"], false);

        request_writer.shutdown().await.unwrap();
        runner.await.unwrap().unwrap();
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// The whole feature in one assertion: after a granted watch, a change in
    /// the worktree produces a `git_info` with `id: 0` that no request asked
    /// for. Without it the client would have to keep polling to find out.
    #[tokio::test]
    async fn a_granted_watch_pushes_an_unsolicited_update() {
        let dir = scratch_dir("watch");
        let init = std::process::Command::new("git")
            .args(["init", "-q"])
            .current_dir(&dir)
            .status()
            .expect("git is required to run the daemon at all");
        assert!(init.success());

        let (mut request_writer, request_reader) = tokio::io::duplex(4096);
        let (response_writer, response_reader) = tokio::io::duplex(65_536);
        let runner = tokio::spawn(run(request_reader, response_writer));
        let mut reader = BufReader::new(response_reader);

        let request = serde_json::json!({
            "type": "watch", "id": 4, "path": dir, "want_files": true,
        });
        request_writer
            .write_all(format!("{request}\n").as_bytes())
            .await
            .unwrap();

        let ack = next_event(&mut reader).await.unwrap();
        assert_eq!(ack["type"], "watch");
        assert_eq!(ack["id"], 4);
        assert_eq!(ack["watching"], true, "a repository is watchable");

        std::fs::write(dir.join("new.txt"), "hello\n").unwrap();

        let push = next_event(&mut reader)
            .await
            .expect("a watched worktree reports its own change");
        assert_eq!(push["type"], "git_info");
        assert_eq!(
            push["id"], 0,
            "an unsolicited event carries the reserved id so a client can tell \
             it apart from an answer it is waiting for"
        );
        assert_eq!(push["added"], 1);
        assert_eq!(push["dirty"], true);
        // want_files travelled with the watch request, not with a git_info one.
        assert_eq!(push["files"]["new.txt"], "A");

        request_writer.shutdown().await.unwrap();
        runner.await.unwrap().unwrap();
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// An unwatch is acknowledged even for a directory that was never watched,
    /// so a client resyncing after a restart cannot deadlock waiting for a
    /// reply it will never get.
    #[tokio::test]
    async fn unwatch_is_always_acknowledged() {
        let (mut request_writer, request_reader) = tokio::io::duplex(4096);
        let (response_writer, response_reader) = tokio::io::duplex(65_536);
        let runner = tokio::spawn(run(request_reader, response_writer));
        let mut reader = BufReader::new(response_reader);

        let request = serde_json::json!({"type": "unwatch", "id": 12, "path": "/nowhere"});
        request_writer
            .write_all(format!("{request}\n").as_bytes())
            .await
            .unwrap();

        let event = next_event(&mut reader).await.unwrap();
        assert_eq!(event["type"], "watch");
        assert_eq!(event["id"], 12);
        assert_eq!(event["watching"], false);

        request_writer.shutdown().await.unwrap();
        runner.await.unwrap().unwrap();
    }
}
