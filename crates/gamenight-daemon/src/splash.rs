//! The desktop host's loading screen, drawn in software so it looks the same
//! as the browser host's (`warp-game-engine/lobbies/game-room/examples/browser/
//! index.html`, `#warp-progress`) and follows the club's design guide
//! (`lobbies/game-room/DESIGN.md`): `bg` with an amber and a lilac glow, the
//! app icon over the Bungee wordmark, one round amber progress bar with the
//! step in muted Outfit under it, and the "Grab a controller" card in the
//! bottom-left corner.
//!
//! Pure Rust (no GDI text), so the Windows launcher only blits the pixels and
//! `examples/splash-preview.rs` renders the very same screen to a PNG.
//! Pixels are `0xAARRGGBB` words, which is a top-down 32-bit DIB on Windows.

use ab_glyph::{Font, FontRef, ScaleFont};

const BUNGEE: &[u8] = include_bytes!("../../../web/fonts/Bungee-Regular.ttf");
const OUTFIT_600: &[u8] = include_bytes!("../../../mobile/assets/fonts/Outfit-600.ttf");
const OUTFIT_800: &[u8] = include_bytes!("../../../mobile/assets/fonts/Outfit-800.ttf");
/// The app icon; its 256 px entry is a PNG with rounded, transparent corners.
const ICON: &[u8] = include_bytes!("../branding/gamenight.ico");

// DESIGN.md colour tokens.
const BG: [f32; 3] = rgb(0x0d1020);
const TEXT: [f32; 3] = rgb(0xeef0fc);
const MUTED: [f32; 3] = rgb(0xa8adc4);
const AMBER: [f32; 3] = rgb(0xffb454);
const LILAC: [f32; 3] = rgb(0xa78bfa);

const fn rgb(hex: u32) -> [f32; 3] {
    [
        ((hex >> 16) & 0xff) as f32 / 255.0,
        ((hex >> 8) & 0xff) as f32 / 255.0,
        (hex & 0xff) as f32 / 255.0,
    ]
}

/// What the screen is for.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    /// Starting the host: progress bar, step and the controller card.
    Welcome,
    /// Updating or switching lobbies over a running party: one line, no bar.
    Cover,
}

/// A pixel rectangle `[left, top, right, bottom)`.
pub type Rect = [i32; 4];

/// The changing part of the screen.
#[derive(Clone, Debug, Default)]
pub struct State {
    /// 0..1, or `None` for no bar.
    pub progress: Option<f32>,
    pub text: String,
    /// Seconds since the screen opened (the icon and controller bob).
    pub time: f32,
}

pub struct Splash {
    width: i32,
    height: i32,
    kind: Kind,
    /// The design's 1080p pixel in screen pixels.
    s: f32,
    /// Background with everything that never moves.
    still: Vec<u32>,
    icon: Sprite,
    pad: Sprite,
    icon_at: (i32, i32),
    pad_at: (i32, i32),
    /// The bar's track and the step line under it.
    track: Rect,
    step: Rect,
    /// Everything the moving parts can touch, redrawn every frame.
    dirty: Vec<Rect>,
}

/// Premultiplied RGBA, `w` × `h`.
struct Sprite {
    w: i32,
    h: i32,
    px: Vec<[f32; 4]>,
}

fn fonts() -> (FontRef<'static>, FontRef<'static>, FontRef<'static>) {
    (
        FontRef::try_from_slice(BUNGEE).expect("Bungee"),
        FontRef::try_from_slice(OUTFIT_600).expect("Outfit 600"),
        FontRef::try_from_slice(OUTFIT_800).expect("Outfit 800"),
    )
}

impl Splash {
    /// A `width` × `height` surface whose main screen is `screen` (inside the
    /// surface: the cover spans every monitor, the brand sits on the main one).
    pub fn new(width: i32, height: i32, screen: Rect, kind: Kind) -> Splash {
        let (sw, sh) = (screen[2] - screen[0], screen[3] - screen[1]);
        let s = (sh as f32 / 1080.0).min(sw as f32 / 1920.0).max(0.35);
        let mut still = vec![0u32; (width.max(1) * height.max(1)) as usize];
        let mut canvas = Canvas {
            px: &mut still,
            w: width,
            h: height,
            clip: [0, 0, width, height],
        };
        canvas.background(screen);
        let (bungee, outfit, outfit_bold) = fonts();

        // The column, centred on the main screen (browser: gap 18 under the
        // icon, 28 between brand and loader, 12 between bar and step).
        let cx = (screen[0] + screen[2]) as f32 / 2.0;
        let icon_size = (112.0 * s).round() as i32;
        let word_px = 72.0 * s;
        let loader_w = 440.0 * s;
        let bar_h = (10.0 * s).round().max(4.0);
        let step_px = 20.0 * s;
        let step_h = step_px * 1.5;
        let column = icon_size as f32 + 18.0 * s + word_px + 28.0 * s + bar_h + 12.0 * s + step_h;
        let top = (screen[1] + screen[3]) as f32 / 2.0 - column / 2.0;
        let icon_at = (
            (cx - icon_size as f32 / 2.0).round() as i32,
            top.round() as i32,
        );
        let word_top = top + icon_size as f32 + 18.0 * s;
        let bar_top = word_top + word_px + 28.0 * s;
        let left = (cx - loader_w / 2.0).round() as i32;
        let track = [
            left,
            bar_top.round() as i32,
            left + loader_w.round() as i32,
            (bar_top + bar_h).round() as i32,
        ];
        let step_top = if kind == Kind::Welcome {
            bar_top + bar_h + 12.0 * s
        } else {
            bar_top - 4.0 * s
        };
        let half = (loader_w.max(900.0 * s)) / 2.0;
        let step = [
            (cx - half).round() as i32,
            step_top.round() as i32,
            (cx + half).round() as i32,
            (step_top + step_h).round() as i32,
        ];

        // Wordmark: "Splitscreen" amber, ".Club" lilac, letter-spacing .01em.
        let parts = [("Splitscreen", AMBER), (".Club", LILAC)];
        let spacing = 0.01 * word_px;
        let total: f32 = parts
            .iter()
            .map(|(t, _)| text_width(&bungee, word_px, t, spacing))
            .sum();
        let mut x = cx - total / 2.0;
        for (t, color) in parts {
            canvas.text(
                &bungee, word_px, x, word_top, word_px, t, color, 1.0, spacing,
            );
            x += text_width(&bungee, word_px, t, spacing);
        }

        let icon = icon_sprite(icon_size);
        // Icon shadow: 0 18px 50px rgba(0,0,0,.45), under the bob's whole range.
        let shadow = [
            icon_at.0 as f32,
            icon_at.1 as f32 + 18.0 * s - 3.0 * s,
            (icon_at.0 + icon_size) as f32,
            (icon_at.1 + icon_size) as f32 + 18.0 * s - 3.0 * s,
        ];
        canvas.shadow(shadow, 26.0 * s, 25.0 * s, 0.45);

        // The controller card (browser #pad-hint): bottom-left, one panel.
        let mut pad = Sprite {
            w: 0,
            h: 0,
            px: Vec::new(),
        };
        let mut pad_at = (0, 0);
        let mut dirty = vec![
            [
                icon_at.0,
                icon_at.1 - (8.0 * s) as i32,
                icon_at.0 + icon_size,
                icon_at.1 + icon_size + 2,
            ],
            step,
        ];
        if kind == Kind::Welcome {
            dirty.push(track);
            let glyph = (150.0 * s).round() as i32;
            pad = controller_sprite(glyph);
            let (pad_x, pad_y, pad_r) = (22.0 * s, 22.0 * s, 28.0 * s);
            let kicker = 15.0 * s;
            let title = 30.0 * s;
            let body = 18.0 * s;
            let lines = [
                (
                    "BEST WITH A CONTROLLER",
                    &outfit_bold,
                    kicker,
                    AMBER,
                    0.04 * kicker,
                ),
                ("Grab a controller", &outfit_bold, title, TEXT, 0.0),
                (
                    "Connect one to join, the best way to play",
                    &outfit,
                    body,
                    MUTED,
                    0.0,
                ),
            ];
            let text_w = lines
                .iter()
                .map(|(t, f, px, _, sp)| text_width(f, *px, t, *sp))
                .fold(0.0, f32::max);
            let text_h = kicker * 1.5 + title * 1.25 + body * 1.5 + 6.0 * s;
            let glyph_h = glyph as f32 * pad.h as f32 / pad.w as f32;
            let inner_h = text_h.max(glyph_h);
            let card_w = pad_x + glyph as f32 + 22.0 * s + text_w + pad_r;
            let card_h = pad_y * 2.0 + inner_h;
            let card_left = screen[0] as f32 + 48.0 * s;
            let card_bottom = screen[3] as f32 - 48.0 * s;
            let card = [
                card_left,
                card_bottom - card_h,
                card_left + card_w,
                card_bottom,
            ];
            canvas.shadow(
                [card[0], card[1] + 12.0 * s, card[2], card[3] + 12.0 * s],
                24.0 * s,
                18.0 * s,
                0.45,
            );
            canvas.panel(card, 24.0 * s, s);
            pad_at = (
                (card[0] + pad_x).round() as i32,
                (card[1] + pad_y + (inner_h - glyph_h) / 2.0).round() as i32,
            );
            dirty.push([
                pad_at.0,
                pad_at.1 - (8.0 * s) as i32,
                pad_at.0 + pad.w,
                pad_at.1 + pad.h + 2,
            ]);
            let tx = card[0] + pad_x + glyph as f32 + 22.0 * s;
            let mut ty = card[1] + pad_y + (inner_h - text_h) / 2.0;
            let heights = [kicker * 1.5, title * 1.25 + 2.0 * s, body * 1.5];
            for ((t, f, px, color, sp), lh) in lines.iter().zip(heights) {
                canvas.text(f, *px, tx, ty, lh, t, *color, 1.0, *sp);
                ty += lh + if *px == title { 4.0 * s } else { 0.0 };
            }
        }

        Splash {
            width,
            height,
            kind,
            s,
            still,
            icon,
            pad,
            icon_at,
            pad_at,
            track,
            step,
            dirty,
        }
    }

    pub fn size(&self) -> (i32, i32) {
        (self.width, self.height)
    }

    /// The still screen into `out` (`width × height` pixels).
    pub fn draw_all(&self, out: &mut [u32], state: &State) {
        out.copy_from_slice(&self.still);
        self.draw(out, state);
    }

    /// Redraws the moving parts into `out`, which holds an earlier frame;
    /// returns the rectangles that changed.
    pub fn draw(&self, out: &mut [u32], state: &State) -> Vec<Rect> {
        let (_, outfit, _) = fonts();
        for r in &self.dirty {
            let r = clip(*r, [0, 0, self.width, self.height]);
            for y in r[1]..r[3] {
                let row = (y * self.width) as usize;
                out[row + r[0] as usize..row + r[2] as usize]
                    .copy_from_slice(&self.still[row + r[0] as usize..row + r[2] as usize]);
            }
        }
        let s = self.s;
        // The browser's bob: 2.4 s, up 6 px at the middle, eased.
        let bob = |phase: f32| -6.0 * s * (0.5 - 0.5 * (std::f32::consts::TAU * phase).cos());
        let mut canvas = Canvas {
            px: out,
            w: self.width,
            h: self.height,
            clip: [0, 0, self.width, self.height],
        };
        let lift = bob(state.time / 2.4);
        canvas.sprite(
            &self.icon,
            self.icon_at.0 as f32,
            self.icon_at.1 as f32 + lift,
        );
        if self.kind == Kind::Welcome {
            canvas.sprite(
                &self.pad,
                self.pad_at.0 as f32,
                self.pad_at.1 as f32 + bob(state.time / 2.4 + 0.35),
            );
            if let Some(p) = state.progress {
                let t = self.track.map(|v| v as f32);
                let radius = (t[3] - t[1]) / 2.0;
                canvas.round_rect(t, radius, [1.0, 1.0, 1.0], 0.08);
                let end = t[0] + (t[2] - t[0]) * p.clamp(0.0, 1.0);
                canvas.round_rect(
                    [t[0], t[1], end.max(t[0] + 2.0 * radius), t[3]],
                    radius,
                    AMBER,
                    1.0,
                );
            }
        }
        let step_px = 20.0 * s;
        let (color, weight) = if self.kind == Kind::Cover {
            (TEXT, 1.2)
        } else {
            (MUTED, 1.0)
        };
        let px = step_px * weight;
        let w = text_width(&outfit, px, &state.text, 0.0);
        let r = self.step.map(|v| v as f32);
        canvas.clip = self.step;
        canvas.text(
            &outfit,
            px,
            (r[0] + r[2] - w) / 2.0,
            r[1],
            r[3] - r[1],
            &state.text,
            color,
            1.0,
            0.0,
        );
        self.dirty.clone()
    }
}

fn clip(r: Rect, by: Rect) -> Rect {
    let r = [
        r[0].max(by[0]),
        r[1].max(by[1]),
        r[2].min(by[2]),
        r[3].min(by[3]),
    ];
    [r[0], r[1], r[2].max(r[0]), r[3].max(r[1])]
}

/// Width of `text` at `px` (CSS font-size) with `spacing` after each glyph.
fn text_width(font: &FontRef, px: f32, text: &str, spacing: f32) -> f32 {
    let scaled = font.as_scaled(em_scale(font, px));
    let mut width = 0.0;
    let mut last = None;
    for c in text.chars() {
        let id = scaled.glyph_id(c);
        if let Some(prev) = last {
            width += scaled.kern(prev, id);
        }
        width += scaled.h_advance(id) + spacing;
        last = Some(id);
    }
    width - if text.is_empty() { 0.0 } else { spacing }
}

/// ab_glyph scales by ascent - descent; CSS sizes by the em.
fn em_scale(font: &FontRef, px: f32) -> ab_glyph::PxScale {
    let em = font.units_per_em().unwrap_or(1000.0);
    ab_glyph::PxScale::from(px * font.height_unscaled() / em)
}

struct Canvas<'a> {
    px: &'a mut [u32],
    w: i32,
    h: i32,
    clip: Rect,
}

fn unpack(p: u32) -> [f32; 3] {
    [
        ((p >> 16) & 0xff) as f32 / 255.0,
        ((p >> 8) & 0xff) as f32 / 255.0,
        (p & 0xff) as f32 / 255.0,
    ]
}

fn pack(c: [f32; 3]) -> u32 {
    let q = |v: f32| (v.clamp(0.0, 1.0) * 255.0 + 0.5) as u32;
    0xff00_0000 | q(c[0]) << 16 | q(c[1]) << 8 | q(c[2])
}

/// Signed distance to a rounded rectangle (negative inside).
fn rounded_box(x: f32, y: f32, r: [f32; 4], radius: f32) -> f32 {
    let (cx, cy) = ((r[0] + r[2]) / 2.0, (r[1] + r[3]) / 2.0);
    let (hx, hy) = ((r[2] - r[0]) / 2.0 - radius, (r[3] - r[1]) / 2.0 - radius);
    let (qx, qy) = ((x - cx).abs() - hx, (y - cy).abs() - hy);
    let outside = (qx.max(0.0).powi(2) + qy.max(0.0).powi(2)).sqrt();
    outside + qx.max(qy).min(0.0) - radius
}

impl Canvas<'_> {
    fn blend(&mut self, x: i32, y: i32, color: [f32; 3], alpha: f32) {
        if alpha <= 0.0
            || x < self.clip[0]
            || y < self.clip[1]
            || x >= self.clip[2]
            || y >= self.clip[3]
        {
            return;
        }
        let i = (y * self.w + x) as usize;
        let under = unpack(self.px[i]);
        let a = alpha.min(1.0);
        self.px[i] = pack([0, 1, 2].map(|k| under[k] + (color[k] - under[k]) * a));
    }

    fn area(&self, r: [f32; 4], pad: f32) -> Rect {
        clip(
            [
                (r[0] - pad).floor() as i32,
                (r[1] - pad).floor() as i32,
                (r[2] + pad).ceil() as i32,
                (r[3] + pad).ceil() as i32,
            ],
            self.clip,
        )
    }

    /// `bg` with the browser's two glows, dithered against banding.
    fn background(&mut self, screen: Rect) {
        let (sx, sy) = (screen[0] as f32, screen[1] as f32);
        let (sw, sh) = (
            (screen[2] - screen[0]) as f32,
            (screen[3] - screen[1]) as f32,
        );
        // radial-gradient(rx% ry% at x% y%, color alpha, transparent 70%).
        let glows = [
            (0.72, 0.65, 0.55, 0.50, LILAC, 0.18),
            (0.30, 0.35, 0.60, 0.50, AMBER, 0.16),
        ];
        let mut seed = 0x9e37_79b9u32;
        for y in 0..self.h {
            for x in 0..self.w {
                let mut c = BG;
                for (gx, gy, rx, ry, color, alpha) in glows {
                    let dx = (x as f32 - sx - gx * sw) / (rx * sw);
                    let dy = (y as f32 - sy - gy * sh) / (ry * sh);
                    let d = (dx * dx + dy * dy).sqrt() / 0.7;
                    if d < 1.0 {
                        let a = alpha * (1.0 - d);
                        c = [0, 1, 2].map(|k| c[k] + (color[k] - c[k]) * a);
                    }
                }
                seed ^= seed << 13;
                seed ^= seed >> 17;
                seed ^= seed << 5;
                let noise = ((seed & 0xff) as f32 / 255.0 - 0.5) / 255.0;
                self.px[(y * self.w + x) as usize] = pack(c.map(|v| v + noise));
            }
        }
    }

    /// A soft black shadow of a rounded box (`blur` ≈ the CSS blur radius / 2).
    fn shadow(&mut self, r: [f32; 4], radius: f32, blur: f32, alpha: f32) {
        let a = self.area(r, blur * 2.0);
        for y in a[1]..a[3] {
            for x in a[0]..a[2] {
                let d = rounded_box(x as f32 + 0.5, y as f32 + 0.5, r, radius);
                let t = (0.5 - d / (blur * 2.0)).clamp(0.0, 1.0);
                self.blend(x, y, [0.0; 3], alpha * t * t * (3.0 - 2.0 * t));
            }
        }
    }

    fn round_rect(&mut self, r: [f32; 4], radius: f32, color: [f32; 3], alpha: f32) {
        let a = self.area(r, 1.0);
        for y in a[1]..a[3] {
            for x in a[0]..a[2] {
                let d = rounded_box(x as f32 + 0.5, y as f32 + 0.5, r, radius);
                self.blend(x, y, color, alpha * (0.5 - d).clamp(0.0, 1.0));
            }
        }
    }

    /// One DESIGN.md panel: `bg` at 88 %, a 1 px white 10 % edge.
    fn panel(&mut self, r: [f32; 4], radius: f32, s: f32) {
        let edge = s.max(1.0);
        let a = self.area(r, 1.0);
        for y in a[1]..a[3] {
            for x in a[0]..a[2] {
                let d = rounded_box(x as f32 + 0.5, y as f32 + 0.5, r, radius);
                let inside = (0.5 - d).clamp(0.0, 1.0);
                self.blend(x, y, BG, 0.88 * inside);
                let line = (0.5 - (d + edge / 2.0).abs() + edge / 2.0).clamp(0.0, 1.0);
                self.blend(x, y, [1.0; 3], 0.10 * line);
            }
        }
    }

    fn sprite(&mut self, sprite: &Sprite, x: f32, y: f32) {
        let (ox, oy) = (x.round() as i32, y.round() as i32);
        for j in 0..sprite.h {
            for i in 0..sprite.w {
                let p = sprite.px[(j * sprite.w + i) as usize];
                if p[3] <= 0.0 {
                    continue;
                }
                let (px, py) = (ox + i, oy + j);
                if px < self.clip[0]
                    || py < self.clip[1]
                    || px >= self.clip[2]
                    || py >= self.clip[3]
                {
                    continue;
                }
                let k = (py * self.w + px) as usize;
                let under = unpack(self.px[k]);
                self.px[k] = pack([0, 1, 2].map(|c| p[c] + under[c] * (1.0 - p[3])));
            }
        }
    }

    /// One line of text in a `line`-high box from `top`, baseline as CSS
    /// places it (half-leading above and below).
    #[allow(clippy::too_many_arguments)]
    fn text(
        &mut self,
        font: &FontRef,
        px: f32,
        x: f32,
        top: f32,
        line: f32,
        text: &str,
        color: [f32; 3],
        alpha: f32,
        spacing: f32,
    ) {
        let scaled = font.as_scaled(em_scale(font, px));
        let content = scaled.ascent() - scaled.descent();
        let baseline = top + (line - content) / 2.0 + scaled.ascent();
        let mut pen = x;
        let mut last = None;
        for c in text.chars() {
            let id = scaled.glyph_id(c);
            if let Some(prev) = last {
                pen += scaled.kern(prev, id);
            }
            let glyph = id.with_scale_and_position(scaled.scale(), ab_glyph::point(pen, baseline));
            if let Some(outlined) = font.outline_glyph(glyph) {
                let b = outlined.px_bounds();
                outlined.draw(|gx, gy, coverage| {
                    self.blend(
                        b.min.x as i32 + gx as i32,
                        b.min.y as i32 + gy as i32,
                        color,
                        coverage * alpha,
                    );
                });
            }
            pen += scaled.h_advance(id) + spacing;
            last = Some(id);
        }
    }
}

/// The 256 px icon from the .ico, scaled to `size`, premultiplied.
fn icon_sprite(size: i32) -> Sprite {
    let size = size.max(1);
    let count = u16::from_le_bytes([ICON[4], ICON[5]]) as usize;
    let png = (0..count)
        .map(|i| &ICON[6 + 16 * i..22 + 16 * i])
        .filter_map(|e| {
            let len = u32::from_le_bytes(e[8..12].try_into().ok()?) as usize;
            let at = u32::from_le_bytes(e[12..16].try_into().ok()?) as usize;
            let data = ICON.get(at..at + len)?;
            data.starts_with(b"\x89PNG").then_some(data)
        })
        .next();
    let Some(image) = png.and_then(|p| image::load_from_memory(p).ok()) else {
        return Sprite {
            w: 0,
            h: 0,
            px: Vec::new(),
        };
    };
    let small = image::imageops::resize(
        &image.to_rgba8(),
        size as u32,
        size as u32,
        image::imageops::FilterType::Lanczos3,
    );
    let px = small
        .pixels()
        .map(|p| {
            let a = p[3] as f32 / 255.0;
            [
                p[0] as f32 / 255.0 * a,
                p[1] as f32 / 255.0 * a,
                p[2] as f32 / 255.0 * a,
                a,
            ]
        })
        .collect();
    Sprite {
        w: size,
        h: size,
        px,
    }
}

/// The browser's amber controller (a 48-unit SVG: body, grips, d-pad, two
/// buttons), `width` pixels wide, trimmed to the drawn rows.
fn controller_sprite(width: i32) -> Sprite {
    let width = width.max(8);
    let u = width as f32 / 42.0; // the drawing spans x 3..45, y 12..39
    let h = (27.0 * u).ceil() as i32;
    let mut px = Vec::with_capacity((width * h) as usize);
    for j in 0..h {
        for i in 0..width {
            // 4× supersampling in SVG units.
            let mut amber = 0.0;
            let mut ink = 0.0;
            for (sx, sy) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
                let x = 3.0 + (i as f32 + sx) / u;
                let y = 12.0 + (j as f32 + sy) / u;
                let body = rounded_box(x, y, [4.0, 12.0, 44.0, 34.0], 10.0)
                    .min(((x - 12.0).powi(2) + (y - 30.0).powi(2)).sqrt() - 9.0)
                    .min(((x - 36.0).powi(2) + (y - 30.0).powi(2)).sqrt() - 9.0);
                let marks = rounded_box(x, y, [9.0, 21.0, 19.0, 24.5], 1.75)
                    .min(rounded_box(x, y, [12.25, 17.75, 15.75, 27.75], 1.75))
                    .min(((x - 33.0).powi(2) + (y - 19.5).powi(2)).sqrt() - 2.6)
                    .min(((x - 38.0).powi(2) + (y - 24.5).powi(2)).sqrt() - 2.6);
                if body <= 0.0 {
                    if marks <= 0.0 {
                        ink += 0.25;
                    } else {
                        amber += 0.25;
                    }
                }
            }
            let a = amber + ink;
            let c = [0, 1, 2].map(|k| AMBER[k] * amber + BG[k] * ink);
            px.push([c[0], c[1], c[2], a]);
        }
    }
    Sprite { w: width, h, px }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(px: &[u32], w: i32, x: i32, y: i32) -> [u8; 3] {
        let p = px[(y * w + x) as usize];
        [(p >> 16) as u8, (p >> 8) as u8, p as u8]
    }

    #[test]
    fn welcome_draws_brand_bar_and_card_at_1080p_and_4k() {
        for (w, h) in [(1920, 1080), (3840, 2160)] {
            let splash = Splash::new(w, h, [0, 0, w, h], Kind::Welcome);
            let mut out = vec![0; (w * h) as usize];
            let state = State {
                progress: Some(0.5),
                text: "Opening the lobby\u{2026}".into(),
                time: 0.0,
            };
            splash.draw_all(&mut out, &state);
            // The bar's filled half is amber, the empty half is not.
            let mid = (splash.track[1] + splash.track[3]) / 2;
            let quarter = splash.track[0] + (splash.track[2] - splash.track[0]) / 4;
            assert_eq!(at(&out, w, quarter, mid), [0xff, 0xb4, 0x54]);
            let three = splash.track[0] + (splash.track[2] - splash.track[0]) * 3 / 4;
            assert_ne!(at(&out, w, three, mid), [0xff, 0xb4, 0x54]);
            // Corners stay near bg.
            let c = at(&out, w, w - 2, 1);
            assert!(c[0] < 40 && c[2] < 60, "{c:?}");
            // Something amber in the bottom-left card (the controller).
            let found =
                (h * 3 / 4..h).any(|y| (0..w / 3).any(|x| at(&out, w, x, y) == [0xff, 0xb4, 0x54]));
            assert!(found);
        }
    }

    #[test]
    fn a_frame_only_touches_its_dirty_rects() {
        let (w, h) = (1280, 720);
        let splash = Splash::new(w, h, [0, 0, w, h], Kind::Welcome);
        let mut a = vec![0; (w * h) as usize];
        splash.draw_all(
            &mut a,
            &State {
                progress: Some(0.1),
                text: "Starting".into(),
                time: 0.0,
            },
        );
        let mut b = a.clone();
        let dirty = splash.draw(
            &mut b,
            &State {
                progress: Some(0.9),
                text: "Setting up the room".into(),
                time: 1.2,
            },
        );
        for y in 0..h {
            for x in 0..w {
                if a[(y * w + x) as usize] != b[(y * w + x) as usize] {
                    assert!(
                        dirty
                            .iter()
                            .any(|r| x >= r[0] && x < r[2] && y >= r[1] && y < r[3]),
                        "{x},{y}"
                    );
                }
            }
        }
    }

    #[test]
    fn cover_spans_all_screens_with_the_brand_on_the_main_one() {
        // Main 1920×1080 on the right of a 1280×1024 second screen.
        let splash = Splash::new(3200, 1080, [1280, 0, 3200, 1080], Kind::Cover);
        let mut out = vec![0; 3200 * 1080];
        splash.draw_all(
            &mut out,
            &State {
                progress: None,
                text: "Updating Splitscreen Club\u{2026}".into(),
                time: 0.0,
            },
        );
        assert!(splash.icon_at.0 > 1280 + 800 && splash.icon_at.0 < 1280 + 1000);
    }
}
