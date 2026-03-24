use serde::{Deserialize, Serialize};
use std::path::Path;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
enum Request {
    #[serde(rename = "git_info")]
    GitInfo { id: u64, path: String },
}

#[derive(Debug, Serialize)]
#[serde(tag = "type")]
enum Event {
    #[serde(rename = "git_info")]
    GitInfo {
        id: u64,
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

async fn stdout_writer(mut rx: tokio::sync::mpsc::Receiver<String>) {
    let mut out = tokio::io::stdout();
    while let Some(line) = rx.recv().await {
        if out.write_all(line.as_bytes()).await.is_err() {
            break;
        }
        if out.write_all(b"\n").await.is_err() {
            break;
        }
        let _ = out.flush().await;
    }
}

type EventTx = tokio::sync::mpsc::Sender<String>;

async fn send_event(out: &EventTx, evt: &Event) {
    if let Ok(line) = serde_json::to_string(evt) {
        let _ = out.send(line).await;
    }
}

/// Find the git toplevel for the given path.
async fn git_toplevel(path: &str) -> Option<String> {
    let dir = if Path::new(path).is_file() {
        Path::new(path)
            .parent()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|| ".".to_string())
    } else {
        path.to_string()
    };
    let output = tokio::process::Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .current_dir(&dir)
        .output()
        .await
        .ok()?;
    if output.status.success() {
        Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
    } else {
        None
    }
}

/// Get the current branch name.
async fn git_branch(dir: &str) -> String {
    // Try symbolic-ref first (normal branch)
    if let Ok(output) = tokio::process::Command::new("git")
        .args(["symbolic-ref", "--short", "HEAD"])
        .current_dir(dir)
        .output()
        .await
    {
        if output.status.success() {
            let branch = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !branch.is_empty() {
                return branch;
            }
        }
    }
    // Detached HEAD: show short commit hash
    if let Ok(output) = tokio::process::Command::new("git")
        .args(["rev-parse", "--short", "HEAD"])
        .current_dir(dir)
        .output()
        .await
    {
        if output.status.success() {
            let hash = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !hash.is_empty() {
                return format!(":{}", hash);
            }
        }
    }
    String::new()
}

/// Get ahead/behind counts relative to upstream.
async fn git_ahead_behind(dir: &str) -> (u32, u32) {
    let output = tokio::process::Command::new("git")
        .args(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"])
        .current_dir(dir)
        .output()
        .await;
    match output {
        Ok(o) if o.status.success() => {
            let s = String::from_utf8_lossy(&o.stdout);
            let parts: Vec<&str> = s.trim().split('\t').collect();
            if parts.len() == 2 {
                let ahead = parts[0].parse().unwrap_or(0);
                let behind = parts[1].parse().unwrap_or(0);
                return (ahead, behind);
            }
            (0, 0)
        }
        _ => (0, 0),
    }
}

/// Parse `git status --porcelain=v1` output for file status counts.
async fn git_status_counts(dir: &str) -> (bool, u32, u32, u32) {
    let output = tokio::process::Command::new("git")
        .args(["status", "--porcelain=v1"])
        .current_dir(dir)
        .output()
        .await;
    match output {
        Ok(o) if o.status.success() => {
            let text = String::from_utf8_lossy(&o.stdout);
            let mut added: u32 = 0;
            let mut modified: u32 = 0;
            let mut deleted: u32 = 0;
            let mut dirty = false;
            for line in text.lines() {
                if line.len() < 2 {
                    continue;
                }
                dirty = true;
                let xy: Vec<u8> = line.bytes().take(2).collect();
                let x = xy[0];
                let y = xy[1];
                // New/Added
                if x == b'A' || x == b'?' || y == b'?' {
                    added += 1;
                }
                // Modified
                else if x == b'M' || y == b'M' || x == b'R' || y == b'R' {
                    modified += 1;
                }
                // Deleted
                else if x == b'D' || y == b'D' {
                    deleted += 1;
                } else {
                    modified += 1;
                }
            }
            (dirty, added, modified, deleted)
        }
        _ => (false, 0, 0, 0),
    }
}

async fn handle_git_info(id: u64, path: String, tx: EventTx) {
    let toplevel = git_toplevel(&path).await;
    match toplevel {
        Some(dir) => {
            // Run branch, status, and ahead/behind concurrently.
            let (branch, (dirty, added, modified, deleted), (ahead, behind)) =
                tokio::join!(
                    git_branch(&dir),
                    git_status_counts(&dir),
                    git_ahead_behind(&dir)
                );
            send_event(
                &tx,
                &Event::GitInfo {
                    id,
                    branch,
                    dirty,
                    added,
                    modified,
                    deleted,
                    ahead,
                    behind,
                    is_git: true,
                },
            )
            .await;
        }
        None => {
            send_event(
                &tx,
                &Event::GitInfo {
                    id,
                    branch: String::new(),
                    dirty: false,
                    added: 0,
                    modified: 0,
                    deleted: 0,
                    ahead: 0,
                    behind: 0,
                    is_git: false,
                },
            )
            .await;
        }
    }
}

#[tokio::main(flavor = "multi_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let stdin = BufReader::new(tokio::io::stdin());
    let mut lines = stdin.lines();

    let (out_tx, out_rx) = tokio::sync::mpsc::channel::<String>(1024);
    tokio::spawn(stdout_writer(out_rx));

    while let Some(line) = lines.next_line().await? {
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
            Request::GitInfo { id, path } => {
                let tx = out_tx.clone();
                tokio::spawn(async move {
                    handle_git_info(id, path, tx).await;
                });
            }
        }
    }

    Ok(())
}
