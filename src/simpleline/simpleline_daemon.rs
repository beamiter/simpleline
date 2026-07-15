use serde::{Deserialize, Serialize};
use std::{
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};
use tokio::io::{self, AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio::task::{JoinError, JoinSet};

const GIT_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_CONCURRENT_GIT_REQUESTS: usize = 4;
const MAX_REQUEST_PATH_BYTES: usize = 4096;
// A valid path may expand sixfold when JSON escapes ASCII control bytes. Keep
// enough headroom for the request envelope and a maximum-width u64 request ID.
const MAX_REQUEST_LINE_BYTES: usize = MAX_REQUEST_PATH_BYTES * 6 + 1024;
const PROTOCOL_VERSION: u32 = 1;
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
    GitInfo { id: u64, path: String },
}

#[derive(Debug, Serialize)]
#[serde(tag = "type")]
enum Event {
    #[serde(rename = "version")]
    Version {
        id: u64,
        version: &'static str,
        protocol: u32,
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
        ahead: u32,
        behind: u32,
        is_git: bool,
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

async fn send_event(out: &EventTx, evt: &Event) {
    if let Ok(line) = serde_json::to_string(evt) {
        let _ = out.send(line).await;
    }
}

#[derive(Debug, Default, Eq, PartialEq)]
struct GitStatus {
    branch: String,
    dirty: bool,
    added: u32,
    modified: u32,
    deleted: u32,
    ahead: u32,
    behind: u32,
    is_git: bool,
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

fn count_ordinary_change(status: &mut GitStatus, xy: &str) {
    if xy.bytes().any(|status| status == b'A') {
        status.added = status.added.saturating_add(1);
    } else if xy.bytes().any(|status| status == b'D') {
        status.deleted = status.deleted.saturating_add(1);
    } else {
        status.modified = status.modified.saturating_add(1);
    }
    status.dirty = true;
}

/// Parse one `git status --porcelain=v2 --branch` response.
///
/// Rename/copy and unmerged records are counted as modified because each record
/// represents one logical worktree entry, while untracked entries are added.
fn parse_git_status(stdout: &str, is_git: bool) -> GitStatus {
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

        if let Some(record) = line.strip_prefix("1 ") {
            let xy = record.split_ascii_whitespace().next().unwrap_or_default();
            count_ordinary_change(&mut status, xy);
        } else if line.starts_with("2 ") || line.starts_with("u ") {
            status.modified = status.modified.saturating_add(1);
            status.dirty = true;
        } else if line.starts_with("? ") {
            status.added = status.added.saturating_add(1);
            status.dirty = true;
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

fn git_status_command(path: &str) -> tokio::process::Command {
    let mut command = tokio::process::Command::new("git");
    command
        .args([
            "status",
            "--porcelain=v2",
            "--branch",
            "--untracked-files=normal",
        ])
        .current_dir(command_dir(path))
        .env("GIT_OPTIONAL_LOCKS", "0")
        .kill_on_drop(true);
    for variable in GIT_REPOSITORY_ENV_VARS {
        command.env_remove(variable);
    }
    command
}

async fn query_git_status(path: &str) -> Result<GitStatus, String> {
    let mut command = git_status_command(path);
    let output = tokio::time::timeout(GIT_TIMEOUT, command.output())
        .await
        .map_err(|_| format!("git status timed out after 5 seconds for {path}"))?
        .map_err(|error| format!("failed to run git status for {path}: {error}"))?;

    if !output.status.success() {
        return Ok(GitStatus::default());
    }

    Ok(parse_git_status(
        &String::from_utf8_lossy(&output.stdout),
        true,
    ))
}

async fn handle_git_info(id: u64, path: String, tx: EventTx, _permit: OwnedSemaphorePermit) {
    match query_git_status(&path).await {
        Ok(status) => {
            send_event(
                &tx,
                &Event::GitInfo {
                    id,
                    path,
                    branch: status.branch,
                    dirty: status.dirty,
                    added: status.added,
                    modified: status.modified,
                    deleted: status.deleted,
                    ahead: status.ahead,
                    behind: status.behind,
                    is_git: status.is_git,
                },
            )
            .await;
        }
        Err(message) => send_event(&tx, &Event::Error { id, message }).await,
    }
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
                    },
                )
                .await;
            }
            Request::GitInfo { id, path } => {
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
                    handle_git_info(id, path, tx, permit).await;
                });
            }
        }
    }

    while let Some(result) = requests.join_next().await {
        report_request_completion(result, &out_tx).await;
    }
    drop(out_tx);

    writer
        .await
        .map_err(|error| io::Error::other(format!("stdout writer task failed: {error}")))?
}

#[tokio::main(flavor = "multi_thread")]
async fn main() -> io::Result<()> {
    run(tokio::io::stdin(), tokio::io::stdout()).await
}

#[cfg(test)]
mod tests {
    use super::{
        git_status_command, parse_git_status, read_request_line, run, validate_request_path, Event,
        GitStatus, Request, GIT_REPOSITORY_ENV_VARS, MAX_REQUEST_LINE_BYTES,
        MAX_REQUEST_PATH_BYTES, PROTOCOL_VERSION,
    };
    use tokio::io::{AsyncReadExt, AsyncWriteExt, BufReader};

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
            parse_git_status(output, true),
            GitStatus {
                branch: "main".to_string(),
                dirty: true,
                added: 1,
                modified: 1,
                deleted: 1,
                ahead: 0,
                behind: 0,
                is_git: true,
            }
        );
    }

    #[test]
    fn parses_detached_head_as_short_hash() {
        let output = "\
# branch.oid 0123456789abcdef0123456789abcdef01234567
# branch.head (detached)
";

        let status = parse_git_status(output, true);
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

        let status = parse_git_status(output, true);
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

        let status = parse_git_status(output, true);
        assert_eq!(status.modified, 1);
        assert!(status.dirty);
    }

    #[test]
    fn counts_conflict_as_modified() {
        let output = "\
# branch.oid 0123456789abcdef0123456789abcdef01234567
# branch.head main
u UU N... 100644 100644 100644 100644 1111111 2222222 3333333 conflict.txt
";

        let status = parse_git_status(output, true);
        assert_eq!(status.modified, 1);
        assert!(status.dirty);
    }

    #[test]
    fn counts_untracked_as_added() {
        let output = "\
# branch.oid 0123456789abcdef0123456789abcdef01234567
# branch.head main
? untracked file.txt
";

        let status = parse_git_status(output, true);
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
            parse_git_status(output, true),
            GitStatus {
                branch: "main".to_string(),
                is_git: true,
                ..GitStatus::default()
            }
        );
    }

    #[test]
    fn parses_non_git_directory() {
        assert_eq!(parse_git_status("", false), GitStatus::default());
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
            ahead: 0,
            behind: 0,
            is_git: true,
        })
        .unwrap();

        assert_eq!(json["type"], "git_info");
        assert_eq!(json["id"], 42);
        assert_eq!(json["path"], "/work/project");
    }

    #[test]
    fn version_event_reports_package_and_protocol() {
        let json = serde_json::to_value(Event::Version {
            id: 7,
            version: env!("CARGO_PKG_VERSION"),
            protocol: PROTOCOL_VERSION,
        })
        .unwrap();

        assert_eq!(json["type"], "version");
        assert_eq!(json["id"], 7);
        assert_eq!(json["version"], env!("CARGO_PKG_VERSION"));
        assert_eq!(json["protocol"], PROTOCOL_VERSION);
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
    fn clears_repository_override_environment() {
        let command = git_status_command(".");
        let environment = command.as_std().get_envs().collect::<Vec<_>>();
        for variable in GIT_REPOSITORY_ENV_VARS {
            assert!(environment
                .iter()
                .any(|(key, value)| { *key == std::ffi::OsStr::new(variable) && value.is_none() }));
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
            Request::GitInfo { id, path } => {
                assert_eq!(id, 42);
                assert_eq!(path.len(), MAX_REQUEST_PATH_BYTES);
                assert!(validate_request_path(&path).is_ok());
            }
            Request::Version { .. } => panic!("expected git_info request"),
        }
    }
}
