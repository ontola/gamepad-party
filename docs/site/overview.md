# Bring your game to the couch

Splitscreen Club puts local multiplayer games in one room. Players pick a game, keep their controller and profile, and return to the room with Back. Your game keeps its engine and runs in its own process.

**To share a game, follow [Share your game](/docs/share).** It is the whole path in six steps, from connecting your engine to the store, with a command and a "done when" for each step. The rest of these docs is reference for one of those steps.

## Pick your engine

Starting a new game? The [Game playbook](/docs/playbook) gets you from an idea to the store with a Godot template, headless tests and one-command publishing.

| Engine | Starting point | What is included |
| --- | --- | --- |
| [LÖVE / Lua](/docs/love) | Shared party runner | Lifecycle, controller mapping, window handling and faces |
| [Bevy](/docs/bevy) | Bevy plugin and demo game | Lifecycle, controllers per seat, window and audio handling, settings, faces and phone screens |
| [Rust](/docs/rust) | Rust SDK | Typed protocol events; your engine handles input consumption and rendering |
| [Godot 4](/docs/godot) | Godot addon | Lifecycle, controllers per seat, window handling, settings, faces and phone screens |
| [C / C++](/docs/c) | Single-header adapter | TCP transport and lifecycle; no controller stream or face decoder yet |
| [Unity](/docs/unity) | Unity package and the Orb Rush demo | Lifecycle, controllers per seat, window handling, settings, faces, phone screens and saves; new, not yet tested on hardware |
| [Unreal Engine 5](/docs/unreal) | Unreal plugin and the Dash Derby demo | Lifecycle, controllers per seat, window handling, world pause, settings, faces, phone screens and saves; new, not yet built in CI |
| [Other engines](/docs/other-engines) | Wire protocol | Implement the connection and engine adapter yourself |

These are implementation starting points, not certifications. [Engine support](/docs/engines) compares every engine feature by feature and lists the open work.

## What a good integration does

Prepare a playable frame while hidden and silent. Show it when the host says Start. Pause simulation and audio when players return to the lobby, then resume the same state. Keep processing host messages throughout.

Controllers follow player seats. Faces, names and colours follow player IDs. Your game owns the rounds and score screens; finishing a round does not end the Splitscreen Club session.

Read [Game lifecycle](/docs/lifecycle), then [Controllers & players](/docs/controllers). Add [faces and colours](/docs/faces) once play is reliable.

## Have a game already?

[Add your game in the developer portal](/developers). Sign in with your email; a title, a short pitch and a player count are enough to start. We can help with integration, or you can follow [Share your game](/docs/share) yourself.

## For AI agents

Read [Share your game](/docs/share) first. [llms.txt](/docs/llms.txt) lists every page and [llms-full.txt](/docs/llms-full.txt) has all of them as Markdown in one file.

## How these docs stay current

These pages are built from Markdown in the public repository. Code excerpts are read from source, not pasted copies. CI checks generated pages, internal links and watched implementation files. The Rust example compiles against the SDK; the C example compiles against the header. The Bevy demo is built with Bevy and passes the conformance harness in CI. The Unity demo's rules play against a fake host without Unity, and its Unity code compiles against Unity's reference assemblies. The Unreal plugin's protocol core passes its unit tests and the conformance harness in CI; its Unreal code is not compiled there yet.

An implementation change makes the docs check fail until someone reviews and regenerates the affected pages. This catches drift; it cannot prove every explanation is correct. Godot snippets are source-checked, not runtime-certified. Physical controller and window tests still matter.
