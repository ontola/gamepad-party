# Share your game

This page is the whole path from a local multiplayer game on your machine to a
game that groups can play in Splitscreen Club. Follow the steps in order. Each
step ends with **Done when**: do not move on before that is true. The other
pages are reference for one step; this page links to them where you need them.

People and AI agents can follow it the same way. Every step runs from the
command line. An agent can read all docs at once in
[llms-full.txt](/docs/llms-full.txt).

## What you need

- A game for 1 to 8 players on one screen, played with controllers.
- A Windows build of it. Hosts run on Windows today; you can add `mac` and
  `linux` builds next to it.
- An email address, for the [developer portal](/developers).

You do not need Splitscreen Club support in your game to start. You can send a
game first and add support later, or ask us to help (step 1).

## 1. Tell us about the game

Sign in to the [developer portal](/developers) with your email and choose
**Add your game**. A title, a one-line pitch and a player count are enough.

From here you have two equal options:

- **Do it yourself** (or with your AI tools): continue with step 2.
- **Let us help**: ask in the game's **Help** tab. We agree on repository
  access and AI use first, prepare the changes in a pull request, and you
  review and merge it. Your repository can stay private.

**Done when** the game is in the portal with its id, such as `my-game`. Use
that id everywhere below.

## 2. Connect your engine

Splitscreen Club starts your game as a separate program and talks to it over
a local connection: it tells the game who plays on which seat, sends each
seat's controller, and says when to prepare, start, pause, resume and stop.
Your engine's SDK does that work. Pick your engine:

| Engine | Guide | You add |
| --- | --- | --- |
| Warp (Luau) | [Warp / Luau](/docs/warp) | nothing: the `warp` runtime does it. The quickest start for a new game |
| Godot 4 | [Godot](/docs/godot), or start from the [template](/docs/playbook) | the `sdk/godot` addon |
| Unity | [Unity](/docs/unity) | the `sdk/unity` package |
| Unreal Engine 5 | [Unreal](/docs/unreal) | the `sdk/unreal/GameNight` plugin |
| Bevy | [Bevy](/docs/bevy) | the `gamenight-bevy` crate |
| LÖVE / Lua | [LÖVE](/docs/love) | your game as a module of the shared runner |
| Rust, no engine | [Rust](/docs/rust) | the `gamenight-sdk` crate |
| C / C++ | [C / C++](/docs/c) | the `sdk/c/gamenight.h` header |
| Anything else | [Other engines](/docs/other-engines) | your own adapter for the [protocol](/docs/protocol) |

[Engine support](/docs/engines) says per engine what the SDK does and what
you still write yourself.

Whatever the engine, the game must do five things. They are what players notice:

1. **Start in the game.** No title screen or player setup: the room already
   picked the game and the players.
2. **Read each seat's own controller** from the SDK, never a joystick
   index. See [Controllers & players](/docs/controllers).
3. **Prepare hidden, show on Start.** Load while hidden and silent, report
   ready, take the screen when the host says Start. See
   [Game lifecycle](/docs/lifecycle).
4. **Pause and resume the same state.** Back (Select) takes everyone to
   the room; your game freezes, also its audio and timers, until it is
   resumed. Never use Back for anything else. Start opens your own menu.
5. **Keep playing rounds.** Show a result briefly and start the next round.
   Players leave with Back, not through a game over screen.

Add players' [faces and colours](/docs/faces) and [settings](/docs/settings)
once this works.

**Done when** your game starts inside Splitscreen Club, every seat moves its
own player, and Back and Resume work.

## 3. Test it

Run the certifier against your built game. It plays the host: it seats
players, sends controller input and runs the whole lifecycle several times.

```sh
git clone https://github.com/ontola/gamepad-party
cd gamepad-party
cargo run --release -p gamenight-certify -- my-game --players 2 --report report.json -- path/to/MyGame.exe
```

Everything after `--` is the command that starts your game. Then play it once
with real controllers: two people, unplug a pad, press Back and Resume a few
times, switch to another game and back. The certifier cannot see your screen
or your pads. More checks: [Test your integration](/docs/testing).

**Done when** the certifier reports no failures and the real-controller round
went right.

## 4. Upload a preview build

A preview is private: only you and your testers see it. In the portal, open
your game, then **API keys**, and create a key. Store it as
`GAMENIGHT_API_TOKEN` (in your shell, or as a CI secret). Then upload a ZIP of
the exported game:

```sh
curl -O https://splitscreen.club/developers/gamenight-publish.py
python3 gamenight-publish.py push --game my-game --platform windows --file dist/my-game-windows.zip --entrypoint MyGame.exe --version 0.1.0
```

`--entrypoint` is the executable's path inside the ZIP. Every upload needs a
new `--version`. To upload from GitHub Actions on every push instead, see
[Connect GitHub Actions](/docs/publishing#connect-github-actions).

**Done when** the portal's **Builds** tab shows the build as ready.

## 5. Fill the store page

Put two things in your repository:

- `gamenight.json`, the facts about the game:

  ```json
  {
    "$schema": "https://raw.githubusercontent.com/ontola/gamepad-party/main/catalog/schema.json",
    "id": "my-game",
    "title": "My Game",
    "tagline": "One line that says why it is fun with friends.",
    "developer": "Your name",
    "players": { "min": 1, "max": 4 },
    "match_minutes": 5,
    "price": "free",
    "tags": ["party", "co-op"],
    "integration": { "level": "integrated", "protocol": 1 }
  }
  ```

- `assets/gamenight/` with `cover.png` (portrait 360x480), `icon.png`
  (128x128) and `gameplay.png` (16:9).
- `preview.json`, the recipe for five seconds of real gameplay. `python3
  gamenight-publish.py clip --publish` renders and uploads it (see the
  [store clip guide](/docs/store-clip#keep-the-recipe-not-the-video)).

Then, in that folder:

```sh
python3 gamenight-publish.py store
```

Edit these files and run `store` again to change the page. Do not copy the
text or media anywhere else.

**Done when** the portal's **Store page** tab shows your title, clip and art.

## 6. Playtest, review, publish

1. **Playtest.** In the **Playtest** tab, create an invite link and send it
   to friends. When you or a tester joins a Splitscreen Club table with a
   phone, the table gets your preview. Afterwards every phone asks how it went;
   the answers appear in the tab.
2. **Send for review.** In the **Review** tab. We play the exact build and
   check that you may distribute it.
3. **Publish.** Once approved, choose **Publish to players**. Every host
   picks it up from the catalog; nothing needs to change in any Splitscreen
   Club repository.

Later versions: upload a new build (step 4) and publish it. Rolling back is
choosing an older build. Details, the API and pricing:
[Publish a game](/docs/publishing).

**Done when** your game is on the shelf in Splitscreen Club rooms.

## For AI agents

- Read this page first, then only the guide for your engine from step 2.
  [llms-full.txt](/docs/llms-full.txt) has every page as Markdown in one file;
  [llms.txt](/docs/llms.txt) lists them.
- Work through the steps in order and check each **Done when** yourself,
  with commands and screenshots, before you report a step as finished.
- Where [Engine support](/docs/engines) says "You" or "No", write that part
  against the [protocol](/docs/protocol). Do not invent SDK functions.
- Never put the `GAMENIGHT_API_TOKEN` in the repository, a log or a pull
  request. Publishing to players (step 6) is for the game's owner to approve.
