//! Measure warm starts, Back and Skip next on a running Gamepad Party host.
//!
//! The Rust twin of `scripts/preload-check.py`, for machines without Python:
//!
//!   cargo run --release -p gamenight-certify --bin preload-check -- --log %LOCALAPPDATA%\...\daemon.log
//!
//! Connects as an overlay (as the phone app does) and plays every shelf game
//! once: queue it next and wait until it is warm, start it (Y), Back to the
//! lobby and watch for pause/resume flapping, then skip the next entry (X)
//! and time until the following game is warm. A start of a game that was not
//! ready, or slower than `--instant`, is a COLD start. Exits 1 on any cold
//! start or flapping. Plays real games on the TV: run it when nobody plays.

use std::time::{Duration, Instant};

use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::sync::watch;
use tokio_tungstenite::tungstenite::Message;

struct Args {
    addr: String,
    games: Option<Vec<String>>,
    exclude: Vec<String>,
    preload_timeout: f64,
    start_timeout: f64,
    instant: f64,
    play: f64,
    settle: f64,
    no_skip: bool,
    log: Option<String>,
    out: Option<String>,
}

fn parse_args() -> Args {
    let mut args = Args {
        addr: "127.0.0.1:7912".into(),
        games: None,
        exclude: vec!["lobby".into(), "game-room".into(), "warp-game-room".into()],
        preload_timeout: 120.0,
        start_timeout: 30.0,
        instant: 0.5,
        play: 5.0,
        settle: 4.0,
        no_skip: false,
        log: None,
        out: None,
    };
    let mut it = std::env::args().skip(1);
    while let Some(flag) = it.next() {
        let mut value = || {
            it.next()
                .unwrap_or_else(|| die(&format!("{flag} needs a value")))
        };
        let num = |v: String| {
            v.parse::<f64>()
                .unwrap_or_else(|_| die(&format!("not a number: {v}")))
        };
        match flag.as_str() {
            "--addr" => args.addr = value(),
            "--games" => args.games = Some(value().split(',').map(String::from).collect()),
            "--exclude" => args.exclude = value().split(',').map(String::from).collect(),
            "--preload-timeout" => args.preload_timeout = num(value()),
            "--start-timeout" => args.start_timeout = num(value()),
            "--instant" => args.instant = num(value()),
            "--play" => args.play = num(value()),
            "--settle" => args.settle = num(value()),
            "--no-skip" => args.no_skip = true,
            "--log" => args.log = Some(value()),
            "--out" => args.out = Some(value()),
            "-h" | "--help" => {
                println!("preload-check [--addr 127.0.0.1:7912] [--games a,b] [--exclude ids] [--preload-timeout 120] [--start-timeout 30] [--instant 0.5] [--play 5] [--settle 4] [--no-skip] [--log daemon.log] [--out report.json]");
                std::process::exit(0);
            }
            other => die(&format!("unknown flag {other}")),
        }
    }
    args
}

fn die(msg: &str) -> ! {
    eprintln!("preload-check: {msg}");
    std::process::exit(2)
}

type Sink = futures_util::stream::SplitSink<
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>,
    Message,
>;

struct Host {
    sink: Sink,
    party: watch::Receiver<Value>,
    /// Every party snapshot with its arrival time, for flap counting.
    changes: std::sync::Arc<std::sync::Mutex<Vec<Value>>>,
}

impl Host {
    async fn send(&mut self, msg: Value) {
        if let Err(e) = self.sink.send(Message::Text(msg.to_string())).await {
            die(&format!("send failed: {e}"));
        }
    }

    fn party(&self) -> Value {
        self.party.borrow().clone()
    }

    /// Seconds until `test(party)` holds, or None on timeout.
    async fn wait(&self, test: impl Fn(&Value) -> bool, timeout: f64) -> Option<f64> {
        let start = Instant::now();
        while start.elapsed().as_secs_f64() < timeout {
            let p = self.party();
            if p.is_object() && test(&p) {
                return Some(start.elapsed().as_secs_f64());
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        None
    }
}

fn session<'a>(p: &'a Value, key: &str) -> Option<&'a Value> {
    p.get(key).filter(|s| s.is_object())
}

fn has(p: &Value, key: &str, game: &str, phase: &str) -> bool {
    session(p, key).is_some_and(|s| s["game"] == game && s["phase"] == phase)
}

fn warm_state(p: &Value, game: &str) -> String {
    let Some(w) = session(p, "warm_session") else {
        return "cold: nothing warm".into();
    };
    if w["game"] != game {
        return format!("cold: {} was warm", w["game"].as_str().unwrap_or("?"));
    }
    if w["phase"] == "ready" {
        return "warm".into();
    }
    let phase = w["phase"].as_str().unwrap_or("?");
    match w.get("progress").and_then(Value::as_f64) {
        Some(pr) => format!("still loading ({phase}, {pr}%)"),
        None => format!("still loading ({phase})"),
    }
}

fn upcoming(p: &Value) -> Vec<(usize, Value)> {
    let playlist = &p["playlist"];
    let start = playlist["current"].as_u64().map_or(0, |c| c as usize + 1);
    let entries = playlist["entries"].as_array().cloned().unwrap_or_default();
    entries.into_iter().enumerate().skip(start).collect()
}

async fn check_game(host: &mut Host, game: &str, a: &Args) -> Value {
    let mut row = json!({ "game": game });
    // 1. Preload.
    host.send(json!({"type": "queue_next", "game": game})).await;
    row["preload_s"] = json!(
        host.wait(|p| has(p, "warm_session", game, "ready"), a.preload_timeout)
            .await
    );
    // 2. Y: start it.
    let at_press = warm_state(&host.party(), game);
    row["at_press"] = json!(at_press);
    host.send(json!({"type": "next"})).await;
    let start_s = host
        .wait(
            |p| has(p, "active_session", game, "running"),
            a.start_timeout,
        )
        .await;
    row["start_s"] = json!(start_s);
    row["cold"] = json!(at_press != "warm" || start_s.is_none_or(|s| s > a.instant));
    if start_s.is_none() {
        return row;
    }
    tokio::time::sleep(Duration::from_secs_f64(a.play)).await;
    // 3. Back, then watch for flapping.
    let mark = host.changes.lock().unwrap().len();
    host.send(json!({"type": "open_overlay"})).await;
    row["back_s"] = json!(
        host.wait(
            |p| has(p, "active_session", game, "paused") && p["overlay_open"] == true,
            a.start_timeout
        )
        .await
    );
    tokio::time::sleep(Duration::from_secs_f64(a.settle)).await;
    let phases: Vec<Value> = host.changes.lock().unwrap()[mark..]
        .iter()
        .map(|p| session(p, "active_session").map_or(Value::Null, |s| s["phase"].clone()))
        .collect();
    let flaps = phases
        .windows(2)
        .filter(|w| w[0] != w[1] && w[1] == "running")
        .count();
    row["back_flaps"] = json!(flaps);
    // 4. X: skip next, time until the next game is warm.
    let entries = upcoming(&host.party());
    if let (Some((index, entry)), false) = (entries.first(), a.no_skip) {
        let expected = host.party()["playlist"].clone();
        host.send(json!({"type": "remove_playlist_entry", "expected": expected, "index": index}))
            .await;
        row["skipped"] = entry["game"].clone();
        tokio::time::sleep(Duration::from_millis(200)).await;
        if let Some((_, next)) = upcoming(&host.party()).first() {
            let after = next["game"].as_str().unwrap_or("").to_string();
            row["after_skip"] = json!(after);
            row["skip_ready_s"] = json!(
                host.wait(
                    |p| has(p, "warm_session", &after, "ready"),
                    a.preload_timeout
                )
                .await
            );
        }
    }
    row
}

fn fmt(v: &Value) -> String {
    v.as_f64().map_or("-".into(), |s| format!("{s:.2}"))
}

#[tokio::main]
async fn main() {
    let a = parse_args();
    let (ws, _) = tokio_tungstenite::connect_async(format!("ws://{}", a.addr))
        .await
        .unwrap_or_else(|e| die(&format!("cannot reach the host at {}: {e}", a.addr)));
    let (mut sink, mut stream) = ws.split();
    sink.send(Message::Text(
        json!({"type": "hello", "role": "overlay"}).to_string(),
    ))
    .await
    .unwrap_or_else(|e| die(&format!("hello failed: {e}")));
    let (tx, rx) = watch::channel(Value::Null);
    let changes = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let log = changes.clone();
    let reader = tokio::spawn(async move {
        while let Some(Ok(msg)) = stream.next().await {
            let Message::Text(text) = msg else { continue };
            let Ok(msg) = serde_json::from_str::<Value>(&text) else {
                continue;
            };
            match msg["type"].as_str() {
                Some("welcome" | "party_state") if msg["party"].is_object() => {
                    log.lock().unwrap().push(msg["party"].clone());
                    let _ = tx.send(msg["party"].clone());
                }
                Some("error") => eprintln!("  host error: {}", msg["message"]),
                _ => {}
            }
        }
    });
    let mut host = Host {
        sink,
        party: rx,
        changes,
    };
    if host.wait(|_| true, 10.0).await.is_none() {
        die("no welcome from the host");
    }
    let shelf: Vec<String> = host.party()["library"]
        .as_array()
        .cloned()
        .unwrap_or_default()
        .iter()
        .filter(|g| g["listing"] != "demo")
        .filter_map(|g| g["id"].as_str().map(String::from))
        .filter(|id| !a.exclude.contains(id))
        .collect();
    let games = a.games.clone().unwrap_or(shelf);
    let mut rows = Vec::new();
    for game in &games {
        print!("{game}: ");
        use std::io::Write;
        let _ = std::io::stdout().flush();
        let row = check_game(&mut host, game, &a).await;
        let mut parts = vec![
            format!("preload {} s", fmt(&row["preload_s"])),
            format!("at Y {}", row["at_press"].as_str().unwrap_or("")),
            format!(
                "start {} s{}",
                fmt(&row["start_s"]),
                if row["cold"] == true { " COLD" } else { "" }
            ),
            format!("back {} s", fmt(&row["back_s"])),
        ];
        if row["back_flaps"].as_u64().unwrap_or(0) > 0 {
            parts.push(format!("BACK FLAPPED x{}", row["back_flaps"]));
        }
        if let Some(skipped) = row["skipped"].as_str() {
            parts.push(format!(
                "skip {skipped} -> {} warm in {} s",
                row["after_skip"].as_str().unwrap_or("-"),
                fmt(&row["skip_ready_s"])
            ));
        }
        println!("{}", parts.join(", "));
        rows.push(row);
    }
    reader.abort();
    let cold: Vec<&str> = rows
        .iter()
        .filter(|r| r["cold"] == true)
        .filter_map(|r| r["game"].as_str())
        .collect();
    let flapped: Vec<&str> = rows
        .iter()
        .filter(|r| r["back_flaps"].as_u64().unwrap_or(0) > 0)
        .filter_map(|r| r["game"].as_str())
        .collect();
    let list = |v: &[&str]| {
        if v.is_empty() {
            String::new()
        } else {
            format!(": {}", v.join(", "))
        }
    };
    println!(
        "\n{} games, {} cold starts{}, {} with Back flapping{}",
        rows.len(),
        cold.len(),
        list(&cold),
        flapped.len(),
        list(&flapped)
    );
    if let Some(path) = &a.log {
        println!("\nFirst frames and starts from the log:");
        let text = std::fs::read(path)
            .map(|b| String::from_utf8_lossy(&b).into_owned())
            .unwrap_or_default();
        let lines: Vec<&str> = text
            .lines()
            .filter(|l| l.contains("shown with its first frame") || l.contains("game started"))
            .collect();
        for line in &lines[lines.len().saturating_sub(4 * rows.len())..] {
            println!("  {line}");
        }
    }
    if let Some(path) = &a.out {
        let body = serde_json::to_string_pretty(&rows).unwrap();
        std::fs::write(path, body).unwrap_or_else(|e| die(&format!("cannot write {path}: {e}")));
    }
    std::process::exit(if cold.is_empty() && flapped.is_empty() {
        0
    } else {
        1
    });
}
