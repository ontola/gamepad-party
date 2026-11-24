# Five-second gameplay previews

Every playable Splitscreen Club store entry needs an engaging five-second gameplay
montage. Its job is to show how much fun the game contains before someone scrolls
past. Technical validity alone is not acceptance.

Upload the clip on the developer portal's Store page before publishing. Use MP4
or WebM, up to 32 MiB. The server measures its length (4.9–5.1 seconds to allow
frame rounding). Screenshots and YouTube links are optional. Private preview
builds and drafts can be saved before the clip is ready.

## Plan the five seconds

Before recording, write a short shot list with the action, players, weapon/item,
setting or arena, and intended payoff for each cut. Use **4–6 quick cuts**, usually
about **0.6–1.3 seconds per shot**. Aim for four or more clearly different action
beats. Cut into action already starting and leave enough time to see its result.
Use straight cuts; transitions, logos and menus must not consume the five seconds.

Show as much meaningful variety as remains readable:

- **Weapons and abilities:** show several distinct attacks, tools or abilities
  when available. For an arsenal game, aim for at least three visibly different
  weapons; changing the gun without showing what it does does not count.
- **Players and characters:** show multiple identifiable players/characters,
  their interactions and multiplayer chaos. Use different colors or silhouettes;
  include different player counts or layouts when those are selling points.
- **Settings:** switch arenas, environments, modes or gameplay configurations
  where available. Aim for at least two visibly different settings.
- **Items and surprises:** show a pickup, power-up, throwable, hazard or another
  usable object affecting play when the game has them.
- **Signature mechanics:** include what makes this game distinctive—grappling,
  physics, destruction, racing, teamwork, scoring, transformations, etc.
- **Payoffs:** show impacts, escapes, explosions, goals or other satisfying
  outcomes. Open with an immediate hook and finish with a strong beat that loops
  cleanly back to the opening.

Adapt categories to the actual game. A sports game can show tackles, passes,
shots, saves and team sizes instead of weapons. Do not invent features to fill a
checklist. If a category does not exist, spend its time on another real mechanic.
Avoid repeated shots that all communicate the same thing.

## Make the action legible

Frame the relevant players and effects large enough to recognize in a store card
and on a phone. Mix close action with a useful wider shot; a distant whole-map view
with tiny characters is not a substitute for showing gameplay. Keep subjects in
frame through the payoff. Remove setup, countdowns, idle traversal, pauses and
empty aftermath. Do not simply take the first five seconds of a match or publish
one uninterrupted wide shot because it is easy to capture.

Watch the entire montage at its actual five-second speed, at desktop-card and
phone sizes. Inspect every cut: the viewer should immediately understand what is
new and see the action land. Shorten or replace dull shots, and lengthen confusing
ones. Do not accelerate gameplay to force too much into the time budget.

## Capture real gameplay

Use the listed release's simulation and renderer. Never use generated gameplay,
animated cover art or fabricated effects. Deterministic bots or staged starting
positions, legitimate loadouts and real input sequences are useful for getting
clear moments. Keep mechanics, damage, physics and effects faithful to the game.
Record any staging in the capture notes; do not present it as a live competitive
match. Work in a scratch copy without affecting active player sessions.

Retain a reproducible capture harness and edit decision list: source version/commit
and package hash, seed, staging, each source in/out frame, shot length, and what each
shot demonstrates. Record hashes for the encoded clip and its poster.

## Keep the recipe, not the video

The clip is built, not kept: put a `preview.json` recipe next to your
`gamenight.json` and commit that. Never commit the clip itself. When the game
looks better, run the recipe again. Every cut is a command from your own game
that writes numbered PNG frames into `{dir}` (a headless capture, a scripted
run with a fixed seed), followed by how many frames to use:

```json
{
  "render": "1920x1080",
  "env": {"MYGAME_NO_HUD": "1"},
  "cuts": [
    {"name": "arena", "note": "four players, first clash",
     "run": ["./mygame", "--capture", "{dir}", "--size", "{w}x{h}", "--seed", "3", "--frames", "{frames}"],
     "skip": 20, "frames": 60},
    {"name": "boss", "note": "the boss slam lands",
     "run": ["./mygame", "--capture", "{dir}", "--level", "boss", "--frames", "{frames}"],
     "frames": 90}
  ],
  "poster": {"cut": "boss", "frame": 40}
}
```

The cuts' `frames` add up to exactly 150. `{frames}` is `skip` plus `frames`,
and `{w}` and `{h}` are the render size. `cwd` (relative to the recipe) sets
where a command runs.

```sh
python3 gamenight-publish.py clip                        # render, cut, encode, check
python3 gamenight-publish.py clip --render-size 480x270  # a quick draft
python3 gamenight-publish.py clip --reuse --only boss    # redo one cut
GAMENIGHT_API_TOKEN=gn_pub_... python3 gamenight-publish.py clip --reuse --publish
```

`clip` works in `build/preview/` (keep it out of git). It encodes to the
delivery format below and runs the checks below. It writes `provenance.json`
with the commit, the recipe hash, every cut and the hashes of the clip and its
poster. Nothing leaves your machine until you add `--publish`. That uploads the
clip and the poster to the store's media storage through the API and makes them
the store page's gameplay video, using the publishing key of your game. Render
on a real GPU; a software renderer is fine for drafts only. A CI job that runs
`gamenight-publish.py store` must not have a `preview.mp4` lying around to
upload, or it puts the old clip back.

## Delivery and acceptance

- Exactly **5 seconds / 150 frames**, **960×540**, **30 FPS**.
- Silent H.264 MP4: `libx264`, CRF 24, preset slow, YUV420P, limited video range,
  `+faststart`. Use an actual gameplay frame as the JPEG poster.
- Decode the full clip successfully; verify frame count, duration, dimensions and
  at least 100 distinct frame hashes. These checks do not replace visual review.
- Publish to a new immutable versioned path; retain `SHA256SUMS.txt` and provenance.
- Add a video media item with `preview: true`, `duration: 5` and an HTTPS poster.
  Retain useful existing screenshots. The clip must lead the game's media.
- Verify MP4 MIME type, HTTP byte ranges, muted looping playback in the catalog
  card and details, and manual playback with reduced motion. Check desktop and
  phone. Closing or changing games must unload the previous video.
- Run the catalog preview-coverage/model tests and cloud tests before deploying.

**Review gate:** Does the clip visibly cover different players, weapons/abilities,
settings, items and signature mechanics wherever the game supports them? Are there
several quick, readable cuts with satisfying outcomes? Would someone understand
why this game is fun without reading its description? If not, revise the edit.

The hosted service's `deploy/cloud/previews/README.md` contains engine-specific
capture commands and publishing steps. Its `PREVIEWS.json` records shipped clips.
