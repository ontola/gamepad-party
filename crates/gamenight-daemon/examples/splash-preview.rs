//! Renders the desktop loading screen to PNGs, exactly as the launcher draws it.
//! `cargo run --release -p gamenight-daemon --example splash-preview -- <out dir>`
use gamenight_daemon::splash::{Kind, Splash, State};

fn main() {
    let dir = std::path::PathBuf::from(std::env::args().nth(1).unwrap_or_else(|| ".".into()));
    let shots = [
        (
            "welcome-1080p",
            1920,
            1080,
            Kind::Welcome,
            Some(0.1),
            "Starting Splitscreen Club\u{2026}",
        ),
        (
            "welcome-4k",
            3840,
            2160,
            Kind::Welcome,
            Some(0.55),
            "Opening the lobby\u{2026}",
        ),
        (
            "welcome-1080p-late",
            1920,
            1080,
            Kind::Welcome,
            Some(0.82),
            "Setting up the room\u{2026}",
        ),
        (
            "cover-1080p",
            1920,
            1080,
            Kind::Cover,
            None,
            "Updating Splitscreen Club\u{2026}",
        ),
    ];
    for (name, w, h, kind, progress, text) in shots {
        let splash = Splash::new(w, h, [0, 0, w, h], kind);
        let mut px = vec![0u32; (w * h) as usize];
        splash.draw_all(
            &mut px,
            &State {
                progress,
                text: text.into(),
                time: 1.2,
            },
        );
        let rgba: Vec<u8> = px
            .iter()
            .flat_map(|p| [(p >> 16) as u8, (p >> 8) as u8, *p as u8, 255])
            .collect();
        let path = dir.join(format!("{name}.png"));
        image::save_buffer(&path, &rgba, w as u32, h as u32, image::ColorType::Rgba8).unwrap();
        println!("{}", path.display());
    }
}
