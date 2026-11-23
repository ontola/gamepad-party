# Homepage intro video

`web/intro.webm` (VP9) and `web/intro.mp4` (H.264), 1920×1080 without sound,
and their poster `web/intro.jpg` play under the homepage hero and are linked
from the repository README. The video is rendered from `compose.html`: each
frame is `render(t)` in Chromium, captured by `render.cjs` and encoded with
FFmpeg.

The core message is that the next game loads in the background, so nobody
waits. Scenes: intro, Warp Game Room lobby with background loading, instant
switching, zero friction (controllers stay linked), phone companion, play in
your browser, open protocol, free and open source, make your own game, outro.

## Footage

All game footage is real gameplay captured on a machine with a GPU (the
Mancave). Never use cloud (software-rendered) captures here. Put the clips in
`footage/` (not committed) as `<name>.mp4`, at 1920×1080 or 960×540:

- `lobby.mp4`: the Warp Game Room with four players and an up-next game loading.
- `growing-guns.mp4`, `spellstorm.mp4`, `spaceracer.mp4`, `dead-miles.mp4`,
  `ballkickers.mp4`, `sideways.mp4`, `neon-siege.mp4`: 5 to 12 seconds of
  action each. Without `sideways.mp4` the switching scene shows Neon Siege.
- `stills/browser-loading.png`: the browser host's loading screen
  (`/play/`), 2560×1440.

`./prep.sh` turns the clips into numbered frames `f/<name>/NNN.jpg` and
`f/counts.js`. Fonts and the icon come from `web/` (Outfit, Bungee for the
wordmark, Ark pixel for kickers). Faces are the demo faces embedded in
`compose.html`.

## Render

```sh
./prep.sh
node render.cjs stills 1.6,12,33,49   # check single frames in shots/
node render.cjs video master.mp4
ffmpeg -i master.mp4 -c:v libvpx-vp9 -crf 38 -b:v 0 -row-mt 1 -an ../../../web/intro.webm
ffmpeg -i master.mp4 -c:v libx264 -preset slow -crf 25 -pix_fmt yuv420p -movflags +faststart -an ../../../web/intro.mp4
ffmpeg -ss 1.6 -i master.mp4 -frames:v 1 -q:v 3 ../../../web/intro.jpg
```

The hosted site serves the files with byte ranges from `/web/` (routes in
gamenight-internal `crates/gamenight-cloud/src/website.rs`, imported with
`deploy/cloud/import-web.py`).
