# Warp / Luau

[Warp](https://github.com/ontola/warp-game-engine) is the open-source (MIT)
game engine that Splitscreen Club's own games are made in, such as Neon
Siege, Dead Miles and Relay Keepers. Support for Splitscreen Club is built
in. With the `warp` executable a game is only Luau scripts, synth sound
patches and glTF models: there is nothing to compile, and a file you save
reloads in the running game. That makes it the shortest path for a new game,
and a good fit for making one with an AI agent.

## What the runtime does for you

When Splitscreen Club starts a Warp game, the runtime handles the whole
[lifecycle](/docs/lifecycle) without any code from you:

- The window stays hidden while the game prepares, and goes fullscreen on Start.
- Every seat in the room becomes a player in your game, with the name and
  colour from their profile. AI seats become bots.
- Each player's controller arrives as `input[id]` in your `tick`.
- Back goes to the room and pauses the game, Resume continues it, and players
  who join or leave mid-game do so without a restart.
- Start opens a menu with your game's title, Resume and New round.

You call `game.finish()` when a match is over, `game.log(text)` to write a
line in the room log, and `players.rumble(id, strength, seconds)` to buzz a
controller.

Not yet available from Luau: match settings in the app, phone buttons and
phone screens, and online play.

## Get the warp executable

There is no download yet: build it from source with
[Rust](https://rustup.rs).

```sh
git clone https://github.com/ontola/warp-game-engine
cd warp-game-engine
cargo build --release -p warp --bin warp
```

The executable is `target/release/warp` (`warp.exe` on Windows). Build on
Windows to get the `warp.exe` that you ship.

## Make a game

```sh
warp new my-game            # a small working starter game
warp run my-game            # play it, windowed with --windowed
warp check my-game          # load and run 120 ticks without a GPU: the fastest check
```

A game is a folder:

```text
my-game/
  game.toml           title, players, bots, sky (all optional)
  main.luau           the game: init, tick(dt, input), and more hooks
  sounds/*.luau       synth patches: sounds/pickup.luau is the sound "pickup"
  assets/             glTF models (.glb, .gltf)
  scripts/*.json      headless playtests
  types.d.luau        the whole API, for reading and editor completion
  gamenight.json      the store facts, as for any game
```

Set `id` in `game.toml` to your game's id from the [developer portal](/developers).
The full Luau API, `game.toml` keys and the rules for deterministic games are
in the engine's
[warp executable guide](https://github.com/ontola/warp-game-engine/blob/main/engine/docs/warp-cli.md).
Read `types.d.luau` in your game folder for every function.

## Work with an AI agent

`warp run my-game --live` serves the running game over MCP. An agent can
then read its state, run Luau in it, edit files (the game reloads and keeps
its state), take screenshots and play sounds, while you play. See
[live control](https://github.com/ontola/warp-game-engine/blob/main/engine/docs/live-control.md).

Without a screen, `warp script my-game my-game/scripts/smoke.json --out out`
plays a scripted test, saves frames and sound, and fails when a check fails.
Add `KERN_ADAPTER=software` on a machine without a GPU.

## Test and package

1. Play it inside Splitscreen Club, or run the certifier as in
   [Share your game](/docs/share#3-test-it), with the game's command after `--`:

   ```sh
   cargo run --release -p gamenight-certify -- my-game --players 2 -- path/to/warp my-game
   ```

2. Package on Windows: the package is `warp.exe` next to a `game/` folder
   with your game. The engine has a script for it:

   ```powershell
   ./engine/crates/warp/tools/package-windows.ps1 -Game my-game -Executable target/release/warp.exe -OutDirectory build/my-game
   ./build/my-game/warp.exe check build/my-game/game --ticks 600
   Compress-Archive -Path build/my-game/* -DestinationPath build/my-game-windows.zip
   ```

3. Upload it with `--entrypoint warp.exe` and fill the store page, as in
   [Share your game](/docs/share#4-upload-a-preview-build) steps 4 to 6.

## In the browser

Splitscreen Club also runs in a browser at
[splitscreen.club/play](https://splitscreen.club/play/), on one download of
the engine. Only Warp Luau games can run there, because they are scripts on
the same engine. The browser shelf is curated for now: published games are
not added to it automatically.

## A game in Rust on Warp

For more than Luau allows, write the game as a Rust crate on the engine and
use its `splitscreen-club` crate for the connection, as Growing Guns,
Spellstorm and Sideways do. Start with
[Making a game on Warp](https://github.com/ontola/warp-game-engine/blob/main/engine/docs/making-a-game.md).
