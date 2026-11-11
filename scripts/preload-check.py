#!/usr/bin/env python3
"""Measure warm starts, Back and Skip next on a running Gamepad Party host.

Connects to the host as an overlay (as the phone app does) and plays every
game on the shelf once, the way the couch would:

  1. Queue it next and wait until its warm session is ready (preload).
  2. Start it (Y "Play next") and time the request until it runs.
  3. Back to the lobby (open_overlay), time the pause, then watch for a
     few seconds that the game stays paused (no pause/resume flapping).
  4. Skip next (X on the queue cabinet: remove the first upcoming entry) and
     time until the next game is warm again.

Every step reports whether the game was really warm when it was asked for.
A start of a game that was not ready is a COLD start. The host's own log
(`start requested` / `game started` lines) gives the same verdict for
presses made by people.

Host-side only: the time to the game's first visible frame is in the game's
own log ("shown with its first frame"). Pass --log with daemon.log to have
those lines matched to each start.

  python scripts/preload-check.py                       # every shelf game
  python scripts/preload-check.py --games sideways,spellstorm --out report.json

No Python? The same check in Rust:
  cargo run --release -p gamenight-certify --bin preload-check -- --log daemon.log

Needs `pip install websockets`. Plays real games on the TV: run it when
nobody is in the middle of one, leave the controllers alone and keep other
windows (a chat app, a terminal) off the TV's desktop: a Back or Y press or a
window taking the front during the run shows up as flapping or DISTURBED.
"""

import argparse
import asyncio
import json
import sys
import time

import websockets

DEFAULT_ADDR = "127.0.0.1:7912"


class Host:
    def __init__(self, ws):
        self.ws = ws
        self.party = {}
        self.changes = []  # (monotonic time, party)
        self.errors = []
        self.closed = False
        self.reader = asyncio.create_task(self.read())

    async def read(self):
        try:
            async for raw in self.ws:
                msg = json.loads(raw)
                party = msg.get("party")
                if msg.get("type") in ("welcome", "party_state") and isinstance(party, dict):
                    self.party = party
                    self.changes.append((time.monotonic(), party))
                elif msg.get("type") == "error":
                    self.errors.append(str(msg.get("message")))
        except websockets.ConnectionClosed:
            pass
        self.closed = True

    async def send(self, msg):
        try:
            await self.ws.send(json.dumps(msg))
        except websockets.ConnectionClosed:
            self.closed = True
            raise HostGone()

    async def wait(self, test, timeout):
        """Seconds until test(party) holds, or None on timeout."""
        start = time.monotonic()
        while time.monotonic() - start < timeout:
            if self.closed:
                raise HostGone()
            if self.party and test(self.party):
                return time.monotonic() - start
            await asyncio.sleep(0.02)
        return None


class HostGone(Exception):
    """The host closed the connection (Gamepad Party was closed)."""


def session(party, key):
    s = party.get(key)
    return s if isinstance(s, dict) else None


def is_ready(game):
    return lambda p: (w := session(p, "warm_session")) is not None and w["game"] == game and w["phase"] == "ready"


def is_running(game):
    return lambda p: (a := session(p, "active_session")) is not None and a["game"] == game and a["phase"] == "running"


def is_paused(game):
    return lambda p: (a := session(p, "active_session")) is not None and a["game"] == game and a["phase"] == "paused" and p.get("overlay_open")


def warm_state(party, game):
    w = session(party, "warm_session")
    if w is None:
        return "cold: nothing warm"
    if w["game"] != game:
        return f"cold: {w['game']} was warm"
    if w["phase"] == "ready":
        return "warm"
    progress = w.get("progress")
    return f"still loading ({w['phase']}{f', {progress}%' if progress is not None else ''})"


def upcoming(party):
    playlist = party.get("playlist", {})
    current = playlist.get("current")
    start = 0 if current is None else current + 1
    return list(enumerate(playlist.get("entries", [])))[start:]


async def check_game(host, game, args):
    row = {"game": game}
    # 1. Preload. The host refuses games that cannot seat everyone.
    errors = len(host.errors)
    await host.send({"type": "queue_next", "game": game})
    refused = lambda p: len(host.errors) > errors
    row["preload_s"] = await host.wait(lambda p: is_ready(game)(p) or refused(p), args.preload_timeout)
    if refused(None):
        row["skipped_game"] = host.errors[errors]
        row["preload_s"] = None
        return row
    # 2. Y: start it.
    row["at_press"] = warm_state(host.party, game)
    await host.send({"type": "next"})
    row["start_s"] = await host.wait(is_running(game), args.start_timeout)
    row["cold"] = row["at_press"] != "warm" or row["start_s"] is None or row["start_s"] > args.instant
    if row["start_s"] is None:
        return row
    await asyncio.sleep(args.play)
    # 3. Back, then watch for flapping.
    mark = len(host.changes)
    await host.send({"type": "open_overlay"})
    row["back_s"] = await host.wait(is_paused(game), args.start_timeout)
    await asyncio.sleep(args.settle)
    actives = [session(p, "active_session") for _, p in host.changes[mark:]]
    # Someone else started another game in the meantime: not this game's flap.
    row["disturbed"] = any(a is not None and a["game"] != game for a in actives)
    phases = [a and a["game"] == game and a["phase"] for a in actives]
    row["back_flaps"] = sum(1 for a, b in zip(phases, phases[1:]) if a != b and b == "running")
    # 4. X: skip next, time until the next game is warm.
    entries = upcoming(host.party)
    if entries and not args.no_skip:
        index, entry = entries[0]
        await host.send({"type": "remove_playlist_entry", "expected": host.party["playlist"], "index": index})
        row["skipped"] = entry["game"]
        await asyncio.sleep(0.2)
        nxt = upcoming(host.party)
        if nxt:
            row["after_skip"] = nxt[0][1]["game"]
            row["skip_ready_s"] = await host.wait(is_ready(row["after_skip"]), args.preload_timeout)
    return row


def first_frames(log_path):
    """`HH:MM:SS.mmm` of each 'shown with its first frame' line, by process."""
    frames = []
    try:
        for line in open(log_path, encoding="utf-8", errors="replace"):
            if "shown with its first frame" in line or "game started" in line:
                frames.append(line.rstrip())
    except OSError:
        pass
    return frames


def fmt(value):
    return "-" if value is None else f"{value:.2f}"


async def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--addr", default=DEFAULT_ADDR)
    parser.add_argument("--games", help="Comma-separated game ids (default: the whole shelf but the lobby)")
    parser.add_argument("--preload-timeout", type=float, default=120)
    parser.add_argument("--start-timeout", type=float, default=30)
    parser.add_argument("--instant", type=float, default=0.5, help="A start slower than this counts as cold (s)")
    parser.add_argument("--play", type=float, default=5, help="Seconds to let each game run")
    parser.add_argument("--settle", type=float, default=4, help="Seconds to watch for flapping after Back")
    parser.add_argument("--no-skip", action="store_true")
    parser.add_argument("--exclude", default="lobby,game-room,warp-game-room", help="Shelf ids that are lobbies, not games")
    parser.add_argument("--log", help="daemon.log, to list the first-frame lines at the end")
    parser.add_argument("--out", help="Write the rows as JSON")
    args = parser.parse_args()

    async with websockets.connect(f"ws://{args.addr}", max_size=None) as ws:
        await ws.send(json.dumps({"type": "hello", "role": "overlay"}))
        host = Host(ws)
        if await host.wait(lambda p: True, 10) is None:
            sys.exit("no welcome from the host")
        lobby = set(args.exclude.split(","))
        shelf = [g["id"] for g in host.party.get("library", []) if g.get("id") not in lobby and g.get("listing") != "demo"]
        games = args.games.split(",") if args.games else shelf
        rows = []
        for game in games:
            print(f"{game}: ", end="", flush=True)
            try:
                row = await check_game(host, game, args)
            except HostGone:
                print("the host went away (Gamepad Party closed); stopping")
                break
            rows.append(row)
            if args.out:  # per row, so a host that quits keeps what was measured
                with open(args.out, "w", encoding="utf-8") as f:
                    json.dump(rows, f, indent=2)
            if row.get("skipped_game"):
                print(f"skipped: {row['skipped_game']}")
                continue
            parts = [f"preload {fmt(row.get('preload_s'))} s", f"at Y {row['at_press']}",
                     f"start {fmt(row.get('start_s'))} s" + (" COLD" if row.get("cold") else ""),
                     f"back {fmt(row.get('back_s'))} s"]
            if row.get("back_flaps"):
                parts.append(f"BACK FLAPPED x{row['back_flaps']}")
            if row.get("disturbed"):
                parts.append("DISTURBED (another game started: someone used a controller?)")
            if row.get("skipped"):
                parts.append(f"skip {row['skipped']} -> {row.get('after_skip')} warm in {fmt(row.get('skip_ready_s'))} s")
            print(", ".join(parts))
        host.reader.cancel()
    cold = [r["game"] for r in rows if r.get("cold")]
    flapped = [r["game"] for r in rows if r.get("back_flaps")]
    print(f"\n{len(rows)} games, {len(cold)} cold starts{': ' + ', '.join(cold) if cold else ''}, "
          f"{len(flapped)} with Back flapping{': ' + ', '.join(flapped) if flapped else ''}")
    if args.log:
        print("\nFirst frames and starts from the log:")
        for line in first_frames(args.log)[-4 * len(rows):]:
            print("  " + line)
    sys.exit(1 if cold or flapped else 0)


if __name__ == "__main__":
    asyncio.run(main())
