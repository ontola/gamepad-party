//! Runtime-owned controller input for lobbies that use the lobby API
//! (`Role::Lobby`). No client publishes physical input itself.
use super::*;
use gamenight_protocol::{
    BackChord, BackChordAction, BackChordButton, BackMenu, ControllerState, PartySnapshot, PlayerId,
};
use gilrs::{Axis, Button};
use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

/// A rumble for one pad, applied by the sampler thread that owns the pads.
struct Rumble {
    controller: String,
    weak: u16,
    strong: u16,
    ms: u32,
}

/// The longest single rumble; games send short pulses while an effect lasts.
const MAX_RUMBLE_MS: u32 = 5000;

static RUMBLE: std::sync::Mutex<Option<std::sync::mpsc::Sender<Rumble>>> =
    std::sync::Mutex::new(None);

/// Vibrate the pad behind `controller` (an `ordinal:N` token). Does nothing
/// when runtime input is off or the pad has no motors.
pub(super) fn rumble(controller: &str, weak: u16, strong: u16, ms: u32) {
    if let Some(tx) = RUMBLE.lock().unwrap().as_ref() {
        let _ = tx.send(Rumble {
            controller: controller.to_owned(),
            weak,
            strong,
            ms: ms.min(MAX_RUMBLE_MS),
        });
    }
}

/// Replace what `request`'s pad is playing. Dropping the old effect stops it.
fn apply_rumble(
    pads: &mut gilrs::Gilrs,
    playing: &mut HashMap<String, gilrs::ff::Effect>,
    request: Rumble,
) {
    use gilrs::ff::{BaseEffect, BaseEffectType, EffectBuilder, Repeat, Replay, Ticks};
    playing.remove(&request.controller);
    if request.ms == 0 || (request.weak == 0 && request.strong == 0) {
        return;
    }
    let Some(id) = pads
        .gamepads()
        .find(|(id, pad)| {
            format!("ordinal:{}", usize::from(*id)) == request.controller && pad.is_ff_supported()
        })
        .map(|(id, _)| id)
    else {
        return;
    };
    let length = Ticks::from_ms(request.ms);
    let motor = |kind| BaseEffect {
        kind,
        scheduling: Replay {
            play_for: length,
            ..Default::default()
        },
        envelope: Default::default(),
    };
    let effect = EffectBuilder::new()
        .add_effect(motor(BaseEffectType::Weak {
            magnitude: request.weak,
        }))
        .add_effect(motor(BaseEffectType::Strong {
            magnitude: request.strong,
        }))
        .repeat(Repeat::For(length))
        .gamepads(&[id])
        .finish(pads);
    match effect.and_then(|effect| effect.play().map(|_| effect)) {
        Ok(effect) => {
            playing.insert(request.controller, effect);
        }
        Err(error) => debug!(%error, "rumble not played"),
    }
}

pub(super) fn spawn(shared: Arc<Mutex<Shared>>) {
    // Protocol/scene tests inject their own seats and input. Connected physical
    // pads must not alter those fixtures. Normal launches never set this flag.
    if std::env::var_os("GAMENIGHT_TEST_NO_CONTROLLERS").is_some() {
        return;
    }
    // Bounded: a busy runtime drops samples rather than queueing stale input.
    let (tx, mut rx) = mpsc::channel(2);
    // Frame delivery must not wait for catalog snapshot serialization under
    // Shared's mutex. The sampler owns this fast path; the router owns party
    // commands. Sender refreshes are tiny and never hold the party lock here.
    let targets = Arc::new(std::sync::RwLock::new(Vec::<Tx>::new()));
    let (rumble_tx, rumble_rx) = std::sync::mpsc::channel::<Rumble>();
    *RUMBLE.lock().unwrap() = Some(rumble_tx);
    let sample_targets = targets.clone();
    let result = std::thread::Builder::new()
        .name("lobby-input".into())
        .spawn(move || {
            let mut pads = match gilrs::Gilrs::new() {
                Ok(pads) => pads,
                Err(error) => {
                    warn!(%error, "runtime controller input unavailable");
                    return;
                }
            };
            let mut known = Vec::new();
            let mut filter = FrameFilter::default();
            let mut playing = HashMap::new();
            loop {
                while pads.next_event().is_some() {}
                while let Ok(request) = rumble_rx.try_recv() {
                    apply_rumble(&mut pads, &mut playing, request);
                }
                let controllers: Vec<_> = pads
                    .gamepads()
                    .map(|(id, pad)| {
                        let mut axes = [0i16; 6];
                        for (i, axis) in [
                            Axis::LeftStickX,
                            Axis::LeftStickY,
                            Axis::RightStickX,
                            Axis::RightStickY,
                        ]
                        .iter()
                        .enumerate()
                        {
                            axes[i] = (pad.value(*axis).clamp(-1.0, 1.0) * 32767.0) as i16;
                        }
                        axes[1] = -axes[1];
                        axes[3] = -axes[3];
                        for (i, button) in [Button::LeftTrigger2, Button::RightTrigger2]
                            .iter()
                            .enumerate()
                        {
                            axes[i + 4] =
                                (pad.button_data(*button).map(|b| b.value()).unwrap_or(0.0)
                                    * 32767.0) as i16;
                        }
                        let buttons = [
                            Button::South,
                            Button::East,
                            Button::West,
                            Button::North,
                            Button::LeftTrigger,
                            Button::RightTrigger,
                            Button::Select,
                            Button::Start,
                            Button::LeftThumb,
                            Button::RightThumb,
                            Button::DPadUp,
                            Button::DPadDown,
                            Button::DPadLeft,
                            Button::DPadRight,
                        ]
                        .iter()
                        .enumerate()
                        .fold(0, |bits, (i, b)| {
                            bits | if pad.is_pressed(*b) { 1 << i } else { 0 }
                        });
                        ControllerState {
                            controller: format!("ordinal:{}", usize::from(id)),
                            axes,
                            buttons,
                        }
                    })
                    .collect();
                let ids: Vec<_> = controllers.iter().map(|c| c.controller.clone()).collect();
                if ids != known {
                    info!(controllers = ?ids, "runtime controller devices changed");
                    known = ids;
                }
                pads.inc();
                if tx.is_closed() {
                    break;
                }
                let outgoing = filter.apply(controllers.clone());
                let recipients = sample_targets.read().unwrap().clone();
                publish(&recipients, outgoing);
                let _ = tx.try_send(controllers);
                std::thread::sleep(Duration::from_millis(16));
            }
        });
    if let Err(error) = result {
        warn!(%error, "could not spawn runtime input");
        return;
    }
    tokio::spawn(async move {
        let mut router = InputRouter::default();
        while let Some(controllers) = rx.recv().await {
            let mut s = shared.lock().await;
            router.route(&mut s, controllers);
            *targets.write().unwrap() = s.games.values().cloned().collect();
        }
    });
}

fn publish(targets: &[Tx], controllers: Vec<ControllerState>) {
    let frame = ServerMessage::ControllerFrame { controllers }.to_json();
    for tx in targets {
        let _ = tx.send(frame.clone());
    }
}

#[derive(Default)]
struct FrameFilter {
    seen: HashSet<String>,
    held_on_connect: HashSet<String>,
}

impl FrameFilter {
    fn apply(&mut self, mut controllers: Vec<ControllerState>) -> Vec<ControllerState> {
        for controller in &mut controllers {
            if self.seen.insert(controller.controller.clone()) && controller.buttons & 1 != 0 {
                self.held_on_connect.insert(controller.controller.clone());
            }
            if controller.buttons & 1 == 0 {
                self.held_on_connect.remove(&controller.controller);
            }
            // Back belongs to the runtime, and so does RB while Back is
            // held: Back+RB skips to the next game, and the lobby or game
            // must not also act on that RB.
            if controller.buttons & BACK != 0 {
                controller.buttons &= !CHORD_BUTTONS;
            }
            controller.buttons &= !BACK;
            if self.held_on_connect.contains(&controller.controller) {
                controller.buttons &= !1;
            }
        }
        self.seen
            .retain(|id| controllers.iter().any(|c| &c.controller == id));
        self.held_on_connect.retain(|id| self.seen.contains(id));
        controllers
    }
}

/// Back (Select/View) in the runtime button bits.
const BACK: u32 = 1 << 6;
/// Right bumper (RB/R1) in the runtime button bits.
const RB: u32 = 1 << 5;
/// Left bumper (LB/L1).
const LB: u32 = 1 << 4;
/// B (East).
const B_BUTTON: u32 = 1 << 1;

/// A: the press that joins an unseated controller (Joep: only A joins;
/// any other button or stick just jiggles that controller on the table).
const JOIN_BUTTONS: u32 = 1;

#[derive(Default)]
struct InputRouter {
    previous: HashMap<String, u32>,
    consumed_join: HashSet<String>,
    activity: HashMap<String, Instant>,
    /// Back+RB skips sent, for tests.
    skips: usize,
    /// Controllers holding Back right now.
    holds: HashMap<String, BackHold>,
}

/// One controller's Back press, from press to release.
struct BackHold {
    since: Instant,
    /// The room was already up when Back went down: a tap closes it on
    /// release, a hold shows the chords instead.
    room_was_open: bool,
    /// Any chord button went down during this hold: release does nothing.
    chorded: bool,
    /// A chord did its thing (skip, previous, leave): hide the menu.
    acted: bool,
    /// B went down once; the next B removes the player.
    leave_armed: bool,
}

/// Holding Back this long shows the chord menu; releasing sooner is a tap.
const BACK_HOLD: Duration = Duration::from_millis(300);

/// Buttons that are chords while Back is held, never game or lobby input.
const CHORD_BUTTONS: u32 = RB | LB | B_BUTTON;

/// Back and its chords.
///
/// Back acts on its release, never its press: in a game the room comes
/// when Back is let go without a chord, so Back+RB and the other chords go
/// straight on without showing the room first. In the room a tap closes
/// it, a hold (BACK_HOLD) shows the chord menu instead. While Back is held,
/// RB skips to the next game, LB goes back to the previous one and B
/// (twice) takes the player on that controller out of the party. RB then
/// Back, in that order, skips too. A game's own echo of the same Back
/// (`request_overlay`) waits for the runtime (see `pending_game_overlay`).
fn back_chords(
    s: &mut Shared,
    holds: &mut HashMap<String, BackHold>,
    previous: &HashMap<String, u32>,
    skips: &mut usize,
    controllers: &[ControllerState],
) {
    holds.retain(|id, _| controllers.iter().any(|c| &c.controller == id));
    // A game's own Back handler asked for the room. When a controller's
    // Back is behind it, that Back is ours (the room comes on release);
    // otherwise (Escape, a menu's Back to lobby) the room comes now.
    if let Some(at) = s.pending_game_overlay {
        if controllers.iter().any(|c| c.buttons & BACK != 0) || !holds.is_empty() {
            s.pending_game_overlay = None;
        } else if at.elapsed() >= GAME_OVERLAY_WAIT {
            s.pending_game_overlay = None;
            info!("a game asked for the lobby; opening it");
            s.dispatch(Command::OverlayOpened, None);
        }
    }
    // Several people may press Back together. It is one party action.
    let mut toggled = false;
    for c in controllers {
        let before = previous.get(&c.controller).copied().unwrap_or(0);
        let pressed = c.buttons & !before;
        let released = before & !c.buttons;
        if pressed & BACK != 0 {
            let mut hold = BackHold {
                since: Instant::now(),
                room_was_open: true,
                chorded: false,
                acted: false,
                leave_armed: false,
            };
            if c.buttons & RB != 0 {
                hold.chorded = true;
                hold.acted = true;
                skip_to_next(s, skips);
            } else if !toggled {
                toggled = true;
                // Nothing happens yet: the release decides (a tap toggles
                // the room, a chord does its thing instead).
                hold.room_was_open = s.night.snapshot().overlay_open;
            } else {
                // Someone else's Back went down first: theirs toggles.
                hold.chorded = true;
            }
            holds.insert(c.controller.clone(), hold);
            continue;
        }
        let Some(hold) = holds.get_mut(&c.controller) else {
            continue;
        };
        if c.buttons & BACK != 0 {
            if pressed & CHORD_BUTTONS != 0 {
                hold.chorded = true;
            }
            if pressed & RB != 0 {
                hold.acted = true;
                hold.leave_armed = false;
                skip_to_next(s, skips);
            } else if pressed & LB != 0 {
                if s.play_previous() {
                    hold.acted = true;
                    hold.leave_armed = false;
                }
            } else if pressed & B_BUTTON != 0 {
                if let Some(player) = seated_player(&s.night.snapshot(), &c.controller) {
                    if hold.leave_armed {
                        hold.acted = true;
                        hold.leave_armed = false;
                        info!(player = %player.0, "Back+B pressed twice on a controller; the player leaves");
                        s.dispatch(Command::LeaveParty { player_id: player }, None);
                    } else {
                        hold.leave_armed = true;
                    }
                }
            }
        } else if released & BACK != 0 {
            let hold = holds.remove(&c.controller).expect("checked");
            if hold.chorded {
                // A chord was the point of this Back.
            } else if !hold.room_was_open {
                // In a game the room comes on Back's release, so Back+RB
                // and the other chords never show it first.
                info!("Back released on a controller; opening the lobby");
                s.dispatch(Command::OverlayOpened, None);
            } else if hold.since.elapsed() < BACK_HOLD {
                info!("Back tapped on a controller; closing the lobby");
                s.dispatch(Command::OverlayClosed, None);
            }
        }
    }
    s.back_holding = !holds.is_empty();
    // The menu shows where it can be seen: in the room.
    let visible = lobby_on_screen(&s.night.snapshot());
    let menu = controllers.iter().filter(|_| visible).find_map(|c| {
        let hold = holds.get(&c.controller)?;
        let shown = hold.leave_armed || (!hold.acted && hold.since.elapsed() >= BACK_HOLD);
        shown.then(|| back_menu(&s.night.snapshot(), &c.controller, hold.leave_armed))
    });
    if menu != s.back_menu {
        s.back_menu = menu;
        s.apply_effects(vec![Effect::StateChanged], None);
    }
}

/// The room has the screen: the overlay is up, or nothing is playing.
fn lobby_on_screen(party: &PartySnapshot) -> bool {
    party.overlay_open || party.active_session.is_none()
}

/// How long a game's `request_overlay` waits for the runtime to see the
/// Back press behind it (a poll is 16 ms; games often report first).
const GAME_OVERLAY_WAIT: Duration = Duration::from_millis(120);

impl Shared {
    /// Start the game played before the current one (Back+LB, the Game
    /// Room TV's `previous`). False when there is none.
    pub(crate) fn play_previous(&mut self) -> bool {
        let Some(game) = previous_game(&self.night.snapshot()) else {
            return false;
        };
        info!(%game, "back to the previous game");
        self.skipped_by_combo = Some(Instant::now());
        self.dispatch(Command::QueueNext { game }, None);
        self.dispatch(Command::Next, None);
        true
    }
}

fn skip_to_next(s: &mut Shared, skips: &mut usize) {
    info!("Back+RB pressed on a controller; skipping to the next game");
    s.overlay_opened_by_request = None;
    *skips += 1;
    s.skipped_by_combo = Some(Instant::now());
    s.dispatch(Command::Next, None);
}

/// The game played before the one on now (or, in the room, the last one).
fn previous_game(party: &PartySnapshot) -> Option<GameId> {
    let game = party.history.last()?.clone();
    let active = party.active_session.as_ref().map(|a| &a.game);
    (active != Some(&game) && party.library.iter().any(|m| m.id == game)).then_some(game)
}

fn seated_player(party: &PartySnapshot, controller: &str) -> Option<PlayerId> {
    party
        .seats
        .iter()
        .find(|seat| seat.controller.as_deref() == Some(controller))
        .and_then(|seat| seat.occupant.player_id())
}

fn title(party: &PartySnapshot, game: &GameId) -> String {
    party
        .library
        .iter()
        .find(|m| &m.id == game)
        .map(|m| m.title.clone())
        .unwrap_or_else(|| game.0.clone())
}

fn back_menu(party: &PartySnapshot, controller: &str, confirm_leave: bool) -> BackMenu {
    let mut chords = Vec::new();
    let next = party
        .next_game_index
        .and_then(|i| party.playlist.entries.get(i))
        .map(|e| e.title.clone())
        .or_else(|| party.warming.as_ref().map(|e| e.title.clone()));
    if let Some(next) = next {
        chords.push(BackChord {
            button: BackChordButton::Rb,
            action: BackChordAction::Next,
            label: format!("Next: {next}"),
        });
    }
    if let Some(game) = previous_game(party) {
        chords.push(BackChord {
            button: BackChordButton::Lb,
            action: BackChordAction::Previous,
            label: format!("Previous: {}", title(party, &game)),
        });
    }
    let player = seated_player(party, controller);
    if player.is_some() {
        chords.push(BackChord {
            button: BackChordButton::B,
            action: BackChordAction::Leave,
            label: if confirm_leave {
                "Press B again to leave".into()
            } else {
                "Leave the party".into()
            },
        });
    }
    BackMenu {
        controller: controller.to_string(),
        player,
        chords,
        confirm_leave,
    }
}

impl InputRouter {
    fn route(&mut self, s: &mut Shared, mut controllers: Vec<ControllerState>) {
        let Self {
            previous,
            consumed_join,
            activity,
            skips,
            holds,
        } = self;
        back_chords(s, holds, previous, skips, &controllers);
        for controller in &mut controllers {
            // Chord buttons under a held Back are no game or join input.
            let chords = if controller.buttons & BACK != 0 {
                CHORD_BUTTONS
            } else {
                0
            };
            let held = controller.buttons;
            let pressed =
                held & !previous.get(&controller.controller).copied().unwrap_or(0) & !chords;
            previous.insert(controller.controller.clone(), held);
            let snapshot = s.night.snapshot();
            let lobby_active = snapshot.overlay_open || snapshot.active_session.is_none();
            // The runtime consumes Back; SDKs must not echo the same
            // press and bounce a just-resumed game into the lobby again.
            controller.buttons &= !(BACK | chords);
            if lobby_active
                && pressed & JOIN_BUTTONS != 0
                && snapshot
                    .seats
                    .iter()
                    .any(|seat| seat.occupant.is_empty() || seat.controller.is_none())
                && !snapshot.seats.iter().any(|seat| {
                    seat.controller.as_deref() == Some(&controller.controller)
                        && seat.occupant.player_id().is_some()
                })
            {
                // A is the join action, never a stick or D-pad: a drifting
                // stick rejoined a player who had just left. Claim
                // their first unbound seat before creating another player.
                let unbound = snapshot
                    .seats
                    .iter()
                    .find(|seat| seat.controller.is_none() && seat.occupant.player_id().is_some())
                    .and_then(|seat| seat.occupant.player_id());
                let player = unbound.or_else(|| {
                    let before: HashSet<_> = snapshot.players.iter().map(|p| p.id).collect();
                    s.dispatch(
                        Command::JoinParty {
                            name: format!("Player {}", before.len() + 1),
                            seat: None,
                            color: None,
                            avatar: None,
                            library: Vec::new(),
                        },
                        None,
                    );
                    s.night
                        .snapshot()
                        .players
                        .iter()
                        .find(|p| !before.contains(&p.id))
                        .map(|p| p.id)
                });
                if let Some(player) = player {
                    s.dispatch(
                        Command::BindController {
                            player_id: player,
                            controller: controller.controller.clone(),
                        },
                        None,
                    );
                }
                consumed_join.insert(controller.controller.clone());
            }
            // In a running game nobody sees the table: A from a controller
            // nobody plays with joins the party, straight into the game when
            // it takes players live (`participation` with `instant_join`),
            // else from the next game. Games show the hint themselves.
            if !lobby_active
                && pressed & JOIN_BUTTONS != 0
                && seated_player(&snapshot, &controller.controller).is_none()
            {
                s.dispatch(
                    Command::ControllerJoin {
                        controller: controller.controller.clone(),
                    },
                    None,
                );
                if seated_player(&s.night.snapshot(), &controller.controller).is_some() {
                    info!(controller = %controller.controller, "controller joined during a game");
                    consumed_join.insert(controller.controller.clone());
                }
            }
            if held & 1 == 0 {
                consumed_join.remove(&controller.controller);
            }
            if consumed_join.contains(&controller.controller) {
                controller.buttons &= !1;
            }
            if (held != 0 || controller.axes.iter().any(|a| a.unsigned_abs() > 8000))
                && activity
                    .get(&controller.controller)
                    .is_none_or(|at| at.elapsed() >= Duration::from_secs(1))
            {
                activity.insert(controller.controller.clone(), Instant::now());
                s.dispatch(
                    Command::ControllerInput {
                        game: None,
                        session: None,
                        controller: controller.controller.clone(),
                    },
                    None,
                );
            }
        }
        previous.retain(|id, _| controllers.iter().any(|c| &c.controller == id));
        // Tests exercise the filtered router result. In production frames
        // are published directly by the sampler, independently of this lock.
        #[cfg(test)]
        publish(&s.games.values().cloned().collect::<Vec<_>>(), controllers);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fast_frames_preserve_axes_and_gate_only_reserved_buttons() {
        let mut filter = FrameFilter::default();
        let mut input = frame(1 | (1 << 6) | 4);
        input[0].axes = [-32767, 16384, -10000, 0, 127, 32767];
        let output = filter.apply(input.clone());
        assert_eq!(output[0].axes, input[0].axes);
        assert_eq!(output[0].buttons, 4);
        filter.apply(frame(0));
        assert_eq!(filter.apply(frame(1))[0].buttons, 1);
        filter.apply(vec![]);
        assert_eq!(filter.apply(frame(1))[0].buttons, 0);
    }

    #[tokio::test]
    async fn game_frames_keep_flowing_while_party_lock_is_busy() {
        let shared = Arc::new(Mutex::new(Shared::new(
            Vec::new(),
            "127.0.0.1:0".into(),
            None,
        )));
        let (tx, mut rx) = mpsc::unbounded_channel();
        let _busy = shared.lock().await;
        let worker = std::thread::spawn(move || {
            for i in 0..20 {
                let mut state = frame(0);
                state[0].axes[0] = i * 100;
                publish(std::slice::from_ref(&tx), state);
                std::thread::sleep(Duration::from_millis(5));
            }
        });
        for i in 0..20 {
            let json = tokio::time::timeout(Duration::from_millis(100), rx.recv())
                .await
                .unwrap()
                .unwrap();
            let msg: ServerMessage = serde_json::from_str(&json).unwrap();
            assert!(
                matches!(msg, ServerMessage::ControllerFrame {controllers} if controllers[0].axes[0] == i*100)
            );
        }
        worker.join().unwrap();
    }

    #[tokio::test]
    async fn only_a_button_press_joins_and_a_drifting_stick_never_rejoins() {
        let mut s = Shared::new(Vec::new(), "127.0.0.1:0".into(), None);
        let mut router = InputRouter::default();
        router.route(&mut s, frame(0));
        let mut drift = frame(1 << 12); // D-pad left
        drift[0].axes[0] = -20000;
        router.route(&mut s, drift.clone());
        assert!(
            s.night.snapshot().players.is_empty(),
            "connecting or moving is no join"
        );
        router.route(&mut s, frame(1));
        let party = s.night.snapshot();
        assert_eq!(party.players.len(), 1);
        assert_eq!(party.seats[0].controller.as_deref(), Some("ordinal:7"));
        assert!(party.players[0].avatar.is_some());
        s.dispatch(
            Command::LeaveParty {
                player_id: party.players[0].id,
            },
            None,
        );
        // The press that chose Leave is still held, then the stick drifts.
        router.route(&mut s, frame(1));
        router.route(&mut s, frame(0));
        router.route(&mut s, drift);
        router.route(&mut s, vec![]);
        router.route(&mut s, frame(0));
        assert!(s.night.snapshot().players.is_empty());
        router.route(&mut s, frame(128));
        router.route(&mut s, frame(2));
        assert!(
            s.night.snapshot().players.is_empty(),
            "Start or B is no join"
        );
        router.route(&mut s, frame(0));
        router.route(&mut s, frame(1));
        assert_eq!(s.night.snapshot().players.len(), 1, "A joins again");
    }

    #[tokio::test]
    async fn in_a_running_game_only_a_seats_a_spare_controller() {
        let mut s = Shared::new(Vec::new(), "127.0.0.1:0".into(), None);
        let game = GameId::new("arena");
        s.dispatch(Command::GameConnected { game: game.clone() }, None);
        s.dispatch(
            Command::SetPlaylist {
                entries: vec![gamenight_protocol::PlaylistEntry {
                    game: game.clone(),
                    title: "Arena".into(),
                }],
            },
            None,
        );
        let session = s.night.snapshot().warm_session.unwrap().id;
        s.dispatch(Command::SessionReady { session }, None);
        assert!(s.night.snapshot().active_session.is_some());
        let mut router = InputRouter::default();
        router.route(&mut s, frame(0));
        let mut stick = frame(2);
        stick[0].axes[0] = 30000;
        router.route(&mut s, stick);
        router.route(&mut s, frame(128));
        assert!(
            s.night.snapshot().players.is_empty(),
            "B, Start or a stick only show the hint"
        );
        router.route(&mut s, frame(1));
        let party = s.night.snapshot();
        assert_eq!(party.players.len(), 1, "A joins");
        assert_eq!(
            party.active_session.unwrap().id,
            session,
            "the game goes on"
        );
        assert!(party
            .seats
            .iter()
            .any(|seat| seat.controller.as_deref() == Some("ordinal:7")));
    }

    fn frame(buttons: u32) -> Vec<ControllerState> {
        vec![ControllerState {
            controller: "ordinal:7".into(),
            axes: [0; 6],
            buttons,
        }]
    }

    #[tokio::test]
    async fn join_claims_existing_profile_and_consumes_only_the_join_press() {
        let mut s = Shared::new(Vec::new(), "127.0.0.1:0".into(), None);
        s.dispatch(
            Command::JoinParty {
                name: "Nora".into(),
                seat: None,
                color: None,
                avatar: None,
                library: Vec::new(),
            },
            None,
        );
        let id = s.night.snapshot().players[0].id;
        let (tx, mut rx) = mpsc::unbounded_channel();
        s.games.insert(GameId::new("test-game"), tx);
        let mut router = InputRouter::default();
        router.route(&mut s, frame(1));
        let party = s.night.snapshot();
        assert_eq!(party.players.len(), 1);
        assert_eq!(party.players[0].id, id);
        assert_eq!(party.seats[0].controller.as_deref(), Some("ordinal:7"));
        // Only a controller frame is delivered to this unprepared test game.
        let message: ServerMessage = serde_json::from_str(&rx.recv().await.unwrap()).unwrap();
        assert!(
            matches!(message, ServerMessage::ControllerFrame { controllers } if controllers[0].buttons == 0)
        );
        router.route(&mut s, frame(0));
        rx.recv().await.unwrap();
        router.route(&mut s, frame(1));
        let message: ServerMessage = serde_json::from_str(&rx.recv().await.unwrap()).unwrap();
        assert!(
            matches!(message, ServerMessage::ControllerFrame { controllers } if controllers[0].buttons == 1)
        );
        assert_eq!(s.night.snapshot().players.len(), 1);
    }

    #[tokio::test]
    async fn held_back_toggles_once_and_is_not_forwarded() {
        let mut s = Shared::new(Vec::new(), "127.0.0.1:0".into(), None);
        let (tx, mut rx) = mpsc::unbounded_channel();
        s.games.insert(GameId::new("test-game"), tx);
        let mut router = InputRouter::default();
        for _ in 0..3 {
            router.route(&mut s, frame(1 << 6));
            assert!(!s.night.snapshot().overlay_open, "nothing on the press");
            let message: ServerMessage = serde_json::from_str(&rx.recv().await.unwrap()).unwrap();
            assert!(
                matches!(message, ServerMessage::ControllerFrame { controllers } if controllers[0].buttons == 0)
            );
        }
        router.route(&mut s, frame(0));
        assert!(s.night.snapshot().overlay_open, "the room comes on release");
        router.route(&mut s, frame(1 << 6));
        assert!(
            s.night.snapshot().overlay_open,
            "in the room Back acts on release"
        );
        router.route(&mut s, frame(0));
        assert!(!s.night.snapshot().overlay_open, "a tap closes the room");
    }

    #[tokio::test]
    async fn a_games_own_back_echo_waits_for_the_release() {
        let mut s = Shared::new(Vec::new(), "127.0.0.1:0".into(), None);
        s.runtime_input = true;
        let (game, _rx) = mpsc::unbounded_channel();
        let mut router = InputRouter::default();
        router.route(&mut s, frame(0));
        // The game's own Back handler reports first, then our poll sees it.
        s.dispatch(Command::OverlayOpened, Some(&game));
        router.route(&mut s, frame(BACK));
        assert!(!s.night.snapshot().overlay_open, "not on the press");
        s.dispatch(Command::OverlayOpened, Some(&game));
        router.route(&mut s, frame(BACK | RB));
        router.route(&mut s, frame(0));
        assert!(!s.night.snapshot().overlay_open, "a chord: no room at all");
        assert_eq!(router.skips, 1);
        // Escape (no controller Back behind it) opens after a moment.
        s.dispatch(Command::OverlayOpened, Some(&game));
        router.route(&mut s, frame(0));
        assert!(!s.night.snapshot().overlay_open);
        std::thread::sleep(GAME_OVERLAY_WAIT + Duration::from_millis(10));
        router.route(&mut s, frame(0));
        assert!(s.night.snapshot().overlay_open);
    }

    #[tokio::test]
    async fn simultaneous_back_presses_are_one_party_action() {
        let mut s = Shared::new(Vec::new(), "127.0.0.1:0".into(), None);
        let mut router = InputRouter::default();
        let mut controllers = frame(1 << 6);
        controllers.push(ControllerState {
            controller: "ordinal:3".into(),
            axes: [0; 6],
            buttons: 1 << 6,
        });
        router.route(&mut s, controllers);
        let mut released = frame(0);
        released.push(ControllerState {
            controller: "ordinal:3".into(),
            axes: [0; 6],
            buttons: 0,
        });
        router.route(&mut s, released);
        assert!(
            s.night.snapshot().overlay_open,
            "opened once, not toggled twice"
        );
    }

    #[tokio::test]
    async fn back_then_rb_skips_once_and_back_alone_still_toggles() {
        let mut s = Shared::new(Vec::new(), "127.0.0.1:0".into(), None);
        let (tx, mut rx) = mpsc::unbounded_channel();
        s.games.insert(GameId::new("test-game"), tx);
        let mut router = InputRouter::default();
        router.route(&mut s, frame(0));
        rx.recv().await.unwrap();
        router.route(&mut s, frame(BACK));
        rx.recv().await.unwrap();
        assert!(
            !s.night.snapshot().overlay_open,
            "Back waits for its release"
        );
        assert_eq!(router.skips, 0);
        for _ in 0..3 {
            router.route(&mut s, frame(BACK | RB));
            let message: ServerMessage = serde_json::from_str(&rx.recv().await.unwrap()).unwrap();
            assert!(
                matches!(message, ServerMessage::ControllerFrame { controllers } if controllers[0].buttons == 0),
                "RB under Back is the combo, not input"
            );
        }
        assert_eq!(router.skips, 1, "a held combo skips once");
        router.route(&mut s, frame(0));
        rx.recv().await.unwrap();
        assert!(!s.night.snapshot().overlay_open, "after a chord no room");
        router.route(&mut s, frame(RB));
        let message: ServerMessage = serde_json::from_str(&rx.recv().await.unwrap()).unwrap();
        assert!(
            matches!(message, ServerMessage::ControllerFrame { controllers } if controllers[0].buttons == RB),
            "RB alone reaches the game"
        );
        assert_eq!(router.skips, 1);
    }

    #[tokio::test]
    async fn rb_then_back_skips_without_opening_the_lobby() {
        let mut s = Shared::new(Vec::new(), "127.0.0.1:0".into(), None);
        let mut router = InputRouter::default();
        router.route(&mut s, frame(RB));
        router.route(&mut s, frame(RB | BACK));
        assert_eq!(router.skips, 1);
        assert!(!s.night.snapshot().overlay_open);
        router.route(&mut s, frame(0));
        assert!(!s.night.snapshot().overlay_open);
        router.route(&mut s, frame(BACK));
        router.route(&mut s, frame(0));
        assert!(
            s.night.snapshot().overlay_open,
            "Back alone still opens the lobby"
        );
        assert_eq!(router.skips, 1);
    }

    #[test]
    fn sampled_frames_hide_rb_only_while_back_is_held() {
        let mut filter = FrameFilter::default();
        assert_eq!(filter.apply(frame(BACK | RB | 4))[0].buttons, 4);
        assert_eq!(filter.apply(frame(RB | 4))[0].buttons, RB | 4);
    }

    #[tokio::test]
    async fn the_left_game_echoing_back_does_not_reopen_the_lobby_after_a_skip() {
        let mut s = Shared::new(Vec::new(), "127.0.0.1:0".into(), None);
        let (game, _rx) = mpsc::unbounded_channel();
        let mut router = InputRouter::default();
        router.route(&mut s, frame(RB));
        router.route(&mut s, frame(RB | BACK));
        s.dispatch(Command::OverlayOpened, Some(&game));
        assert!(!s.night.snapshot().overlay_open);
    }

    fn join(s: &mut Shared, router: &mut InputRouter) -> PlayerId {
        router.route(s, frame(0));
        router.route(s, frame(1));
        router.route(s, frame(0));
        s.night.snapshot().players[0].id
    }

    #[tokio::test]
    async fn holding_back_in_the_room_shows_the_chords_and_keeps_the_room() {
        let mut s = Shared::new(Vec::new(), "127.0.0.1:0".into(), None);
        let mut router = InputRouter::default();
        let player = join(&mut s, &mut router);
        s.dispatch(Command::OverlayOpened, None);
        router.route(&mut s, frame(BACK));
        assert!(s.back_menu.is_none(), "not before the hold time");
        std::thread::sleep(BACK_HOLD + Duration::from_millis(20));
        router.route(&mut s, frame(BACK));
        let menu = s.snapshot().back_menu.expect("menu while Back is held");
        assert_eq!(menu.controller, "ordinal:7");
        assert_eq!(menu.player, Some(player));
        assert!(!menu.confirm_leave);
        let buttons: Vec<_> = menu.chords.iter().map(|c| c.button).collect();
        assert_eq!(
            buttons,
            vec![BackChordButton::B],
            "only chords that work now: nothing queued, nothing played before"
        );
        router.route(&mut s, frame(0));
        assert!(s.back_menu.is_none());
        assert!(s.night.snapshot().overlay_open, "a hold is no tap");
        assert_eq!(s.night.snapshot().players.len(), 1);
    }

    #[tokio::test]
    async fn back_b_twice_removes_the_player_and_once_does_not() {
        let mut s = Shared::new(Vec::new(), "127.0.0.1:0".into(), None);
        let mut router = InputRouter::default();
        join(&mut s, &mut router);
        s.dispatch(Command::OverlayOpened, None);
        // Once, then let go of Back: disarmed, nobody leaves.
        router.route(&mut s, frame(BACK));
        router.route(&mut s, frame(BACK | B_BUTTON));
        assert!(s.back_menu.as_ref().is_some_and(|m| m.confirm_leave));
        router.route(&mut s, frame(0));
        assert!(s.back_menu.is_none());
        assert_eq!(s.night.snapshot().players.len(), 1);
        assert!(s.night.snapshot().overlay_open, "a chorded press is no tap");
        // Twice under one Back hold: gone.
        router.route(&mut s, frame(BACK));
        router.route(&mut s, frame(BACK | B_BUTTON));
        router.route(&mut s, frame(BACK));
        router.route(&mut s, frame(BACK | B_BUTTON));
        assert!(s.night.snapshot().players.is_empty());
        assert!(s.back_menu.is_none());
        router.route(&mut s, frame(0));
        assert!(
            s.night.snapshot().players.is_empty(),
            "the B under Back never joins again"
        );
    }

    #[tokio::test]
    async fn chord_buttons_under_back_never_reach_the_lobby() {
        let mut s = Shared::new(Vec::new(), "127.0.0.1:0".into(), None);
        let (tx, mut rx) = mpsc::unbounded_channel();
        s.games.insert(GameId::new("test-game"), tx);
        let mut router = InputRouter::default();
        router.route(&mut s, frame(BACK | LB | B_BUTTON | (1 << 12)));
        let message: ServerMessage = serde_json::from_str(&rx.recv().await.unwrap()).unwrap();
        assert!(
            matches!(message, ServerMessage::ControllerFrame { controllers } if controllers[0].buttons == 1 << 12)
        );
        assert!(
            s.night.snapshot().players.is_empty(),
            "B under Back is no join"
        );
    }
}
