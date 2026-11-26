//! The host PC's keyboard as one more controller.
//!
//! The runtime samples every physical controller itself (see `lobby_input`),
//! and before this the Windows host only knew gamepads: the keyboard did
//! nothing in the room or in games (Joep, 2026-11-26), while the browser host
//! lets Enter join. Now, while a window of the host is in front (the room or
//! a game it launched), the keyboard is the controller `local:keyboard`,
//! with the same keys as the Warp shell and the browser host
//! (`app::key_label`): WASD the left stick, Space A, Backspace B, R X, F Y,
//! Q LB, E RB, Tab Back, Enter Start, the arrows the D-pad. Enter also
//! joins, as in the browser. Rooms show keycaps for it because its token
//! contains ":keyboard".
//!
//! Only Windows can tell whose window is in front; elsewhere the keyboard
//! stays off, as before.
use gamenight_protocol::ControllerState;

/// The keyboard's controller token. Contains ":keyboard" like the browser
/// host's `web:keyboard`, so rooms and catalogs treat it as a keyboard.
pub(crate) const TOKEN: &str = "local:keyboard";

/// Whether `controller` is the host's keyboard.
pub(crate) fn is_keyboard(controller: &str) -> bool {
    controller == TOKEN
}

/// The keys the keyboard controller reads, by what they do.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) struct Keys {
    pub w: bool,
    pub a: bool,
    pub s: bool,
    pub d: bool,
    pub space: bool,
    pub backspace: bool,
    pub r: bool,
    pub f: bool,
    pub q: bool,
    pub e: bool,
    pub tab: bool,
    pub enter: bool,
    pub c: bool,
    pub up: bool,
    pub down: bool,
    pub left: bool,
    pub right: bool,
    /// Alt or the Windows key: Alt+Tab, Win+Tab and friends switch
    /// windows, never press Back.
    pub system: bool,
}

/// The keys as a controller frame, in the runtime's bits (A B X Y LB RB
/// Back Start LS RS Up Down Left Right) and axes (y up).
#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) fn frame(keys: Keys) -> ControllerState {
    let mut buttons = 0u32;
    if !keys.system {
        for (on, bit) in [
            (keys.space, 0),
            (keys.backspace, 1),
            (keys.r, 2),
            (keys.f, 3),
            (keys.q, 4),
            (keys.e, 5),
            (keys.tab, 6),
            (keys.enter, 7),
            (keys.c, 9),
            (keys.up, 10),
            (keys.down, 11),
            (keys.left, 12),
            (keys.right, 13),
        ] {
            if on {
                buttons |= 1 << bit;
            }
        }
    }
    let axis = |plus: bool, minus: bool| (plus as i16 - minus as i16) * 32767;
    ControllerState {
        controller: TOKEN.into(),
        axes: [axis(keys.d, keys.a), axis(keys.w, keys.s), 0, 0, 0, 0],
        buttons,
    }
}

/// Samples the keyboard while the host's own windows are in front.
#[cfg(windows)]
pub(crate) struct Sampler {
    me: u32,
    dir: Option<std::path::PathBuf>,
    /// The window in front and whether it is ours, refreshed only when the
    /// window changes (walking the process tree every frame is wasteful).
    last: Option<(usize, bool)>,
}

#[cfg(windows)]
impl Sampler {
    pub(crate) fn new() -> Self {
        let dir = std::env::current_exe()
            .ok()
            .and_then(|exe| exe.canonicalize().ok())
            .and_then(|exe| exe.parent().map(|p| p.to_path_buf()));
        Self {
            me: std::process::id(),
            dir,
            last: None,
        }
    }

    /// The keyboard's frame, or None while another app is in front.
    pub(crate) fn sample(&mut self) -> Option<ControllerState> {
        use windows_sys::Win32::UI::{
            Input::KeyboardAndMouse::*, WindowsAndMessaging::GetForegroundWindow,
        };
        let window = unsafe { GetForegroundWindow() } as usize;
        if window == 0 {
            return None;
        }
        let ours = match self.last {
            Some((w, ours)) if w == window => ours,
            _ => {
                let ours = self.owns_foreground();
                self.last = Some((window, ours));
                ours
            }
        };
        if !ours {
            return None;
        }
        let down = |vk: u16| unsafe { GetAsyncKeyState(vk as i32) } as u16 & 0x8000 != 0;
        let key = |c: u8| down(c as u16);
        Some(frame(Keys {
            w: key(b'W'),
            a: key(b'A'),
            s: key(b'S'),
            d: key(b'D'),
            space: down(VK_SPACE),
            backspace: down(VK_BACK),
            r: key(b'R'),
            f: key(b'F'),
            q: key(b'Q'),
            e: key(b'E'),
            tab: down(VK_TAB),
            enter: down(VK_RETURN),
            c: key(b'C'),
            up: down(VK_UP),
            down: down(VK_DOWN),
            left: down(VK_LEFT),
            right: down(VK_RIGHT),
            system: down(VK_MENU) || down(VK_LWIN) || down(VK_RWIN),
        }))
    }

    /// The window in front belongs to the host: this process, a process it
    /// started (the room, a game), or a program shipped next to it.
    fn owns_foreground(&self) -> bool {
        let Some((pid, path)) = crate::foreground_process() else {
            return false;
        };
        if crate::process_ancestry(pid).contains(&self.me) {
            return true;
        }
        let path = path.canonicalize().ok();
        self.dir
            .as_ref()
            .is_some_and(|dir| path.as_ref().is_some_and(|p| p.starts_with(dir)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_are_the_warp_shell_keys() {
        let f = frame(Keys {
            space: true,
            enter: true,
            w: true,
            a: true,
            ..Keys::default()
        });
        assert_eq!(f.controller, "local:keyboard");
        assert!(
            f.controller.contains(":keyboard"),
            "rooms show keycaps for it"
        );
        assert_eq!(f.buttons, 1 | 1 << 7, "Space is A, Enter is Start");
        assert_eq!(f.axes[0], -32767, "A is left");
        assert_eq!(f.axes[1], 32767, "W is up");
        assert_eq!(frame(Keys::default()).buttons, 0);
    }

    #[test]
    fn alt_tab_never_presses_back() {
        let f = frame(Keys {
            tab: true,
            system: true,
            ..Keys::default()
        });
        assert_eq!(f.buttons, 0);
        assert_eq!(
            frame(Keys {
                tab: true,
                ..Keys::default()
            })
            .buttons,
            1 << 6
        );
    }
}
