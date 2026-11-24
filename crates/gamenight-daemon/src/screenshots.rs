//! Screenshots for the lobby TV (Joep, 2026-11-24: a game like Sideways
//! should show a screenshot there, the store's while it loads, or the game
//! as it was left when the party comes back to the room).
//!
//! - When the host pauses the game in front for the lobby (Back, Alt+Tab
//!   with the game still on screen), it captures that game's window
//!   ([`capture_foreground`], Windows only) and the lobby gets it as the
//!   game's `live_screenshot`. The last capture is also kept on disk, so a
//!   game without a store screenshot shows it on later nights too.
//! - Store screenshots are HTTPS URLs in the published catalogue, which a
//!   lobby cannot fetch: the host downloads them ([`fetch_store`]) and hands
//!   them over as PNG data URIs.
use std::path::PathBuf;

use gamenight_protocol::GameId;

/// Width the TV gets: the room's TV is a small part of the screen.
const WIDTHS: [u32; 3] = [640, 480, 320];

/// Where captures are kept between nights: next to the installed games.
pub(crate) fn dir() -> PathBuf {
    let games = gamenight_installer::install_dir();
    games
        .parent()
        .map(|p| p.join("screenshots"))
        .unwrap_or_else(|| games.join("screenshots"))
}

fn file(game: &GameId) -> Option<PathBuf> {
    let id = &game.0;
    let safe = !id.is_empty()
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
    safe.then(|| dir().join(format!("{id}.png")))
}

/// A PNG data URI of `image`, scaled down to the TV's size and within the
/// protocol's artwork limit.
pub(crate) fn data_uri(image: &image::RgbaImage) -> Option<String> {
    let (w, h) = image.dimensions();
    if w == 0 || h == 0 {
        return None;
    }
    for width in WIDTHS {
        let width = width.min(w);
        let height = ((h as u64 * width as u64) / w as u64).max(1) as u32;
        let small = image::imageops::thumbnail(image, width, height);
        let mut png = Vec::new();
        if small
            .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
            .is_err()
        {
            return None;
        }
        if let Some(uri) = gamenight_protocol::artwork::png_data_uri(&png) {
            return Some(uri);
        }
    }
    None
}

/// A JPEG data URI of `image` for a bug report: full detail up to 1920
/// pixels wide, small enough to send (the cloud takes up to 3 MB).
pub(crate) fn jpeg_data_uri(image: &image::RgbaImage) -> Option<String> {
    use base64::Engine;
    let (w, h) = image.dimensions();
    if w == 0 || h == 0 {
        return None;
    }
    let width = w.min(1920);
    let height = ((h as u64 * width as u64) / w as u64).max(1) as u32;
    let small = image::DynamicImage::ImageRgba8(if width == w {
        image.clone()
    } else {
        image::imageops::resize(image, width, height, image::imageops::FilterType::Triangle)
    })
    .to_rgb8();
    for quality in [85, 70, 50] {
        let mut jpeg = Vec::new();
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpeg, quality)
            .encode_image(&small)
            .ok()?;
        if jpeg.len() <= 2_500_000 {
            return Some(format!(
                "data:image/jpeg;base64,{}",
                base64::engine::general_purpose::STANDARD.encode(jpeg)
            ));
        }
    }
    None
}

/// Nearly every pixel black: a capture of an exclusive-fullscreen game or
/// a window not drawn yet. Not worth putting on the TV.
pub(crate) fn blank(image: &image::RgbaImage) -> bool {
    let pixels = image.pixels().len().max(1);
    let lit = image
        .pixels()
        .step_by(97)
        .filter(|p| p.0[0] as u16 + p.0[1] as u16 + p.0[2] as u16 > 24)
        .count();
    lit * 97 * 50 < pixels
}

/// Keep `uri` as the game's last capture for later nights.
pub(crate) fn save(game: &GameId, uri: &str) {
    let (Some(path), Some(png)) = (
        file(game),
        gamenight_protocol::artwork::decode_png_data_uri(uri),
    ) else {
        return;
    };
    let _ = std::fs::create_dir_all(dir());
    let tmp = path.with_extension("png.tmp");
    if std::fs::write(&tmp, png).is_ok() {
        let _ = std::fs::rename(&tmp, &path);
    }
}

/// The game's last capture from an earlier night, if any.
pub(crate) fn load(game: &GameId) -> Option<String> {
    let bytes = std::fs::read(file(game)?).ok()?;
    gamenight_protocol::artwork::png_data_uri(&bytes)
}

/// Download a store screenshot (PNG, JPEG or WebP) as a TV-sized data URI.
pub(crate) async fn fetch_store(url: &str) -> Option<String> {
    if !url.starts_with("https://") {
        return None;
    }
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(20))
        .build()
        .ok()?;
    let response = client.get(url).send().await.ok()?.error_for_status().ok()?;
    if response.content_length().is_some_and(|n| n > 16 << 20) {
        return None;
    }
    let bytes = response.bytes().await.ok()?;
    if bytes.len() > 16 << 20 {
        return None;
    }
    let image = image::load_from_memory(&bytes).ok()?.to_rgba8();
    data_uri(&image)
}

/// The window in front, as the screen shows it now (Windows): the game's
/// last frame before the lobby comes up.
#[cfg(windows)]
pub(crate) fn capture_foreground() -> Option<image::RgbaImage> {
    use windows_sys::Win32::{
        Foundation::RECT,
        Graphics::Gdi::{
            BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, DeleteDC, DeleteObject, GetDC,
            GetDIBits, ReleaseDC, SelectObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB,
            DIB_RGB_COLORS, SRCCOPY,
        },
        UI::WindowsAndMessaging::{
            GetForegroundWindow, GetSystemMetrics, GetWindowRect, SM_CXVIRTUALSCREEN,
            SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN,
        },
    };
    unsafe {
        let window = GetForegroundWindow();
        if window.is_null() {
            return None;
        }
        let mut rect: RECT = std::mem::zeroed();
        if GetWindowRect(window, &mut rect) == 0 {
            return None;
        }
        // Only the part on the screens.
        let (sx, sy) = (
            GetSystemMetrics(SM_XVIRTUALSCREEN),
            GetSystemMetrics(SM_YVIRTUALSCREEN),
        );
        let (sw, sh) = (
            GetSystemMetrics(SM_CXVIRTUALSCREEN),
            GetSystemMetrics(SM_CYVIRTUALSCREEN),
        );
        let (left, top) = (rect.left.max(sx), rect.top.max(sy));
        let (right, bottom) = (rect.right.min(sx + sw), rect.bottom.min(sy + sh));
        let (w, h) = (right - left, bottom - top);
        if w < 64 || h < 64 {
            return None;
        }
        let screen = GetDC(std::ptr::null_mut());
        if screen.is_null() {
            return None;
        }
        let memory = CreateCompatibleDC(screen);
        let bitmap = CreateCompatibleBitmap(screen, w, h);
        let old = SelectObject(memory, bitmap);
        let copied = BitBlt(memory, 0, 0, w, h, screen, left, top, SRCCOPY) != 0;
        let mut info: BITMAPINFO = std::mem::zeroed();
        info.bmiHeader = BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: w,
            biHeight: -h, // top row first
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB,
            ..std::mem::zeroed()
        };
        let mut pixels = vec![0u8; (w * h * 4) as usize];
        let rows = if copied {
            GetDIBits(
                memory,
                bitmap,
                0,
                h as u32,
                pixels.as_mut_ptr().cast(),
                &mut info,
                DIB_RGB_COLORS,
            )
        } else {
            0
        };
        SelectObject(memory, old);
        DeleteObject(bitmap);
        DeleteDC(memory);
        ReleaseDC(std::ptr::null_mut(), screen);
        if rows != h {
            return None;
        }
        for px in pixels.chunks_exact_mut(4) {
            px.swap(0, 2); // BGRA to RGBA
            px[3] = 255;
        }
        image::RgbaImage::from_raw(w as u32, h as u32, pixels)
    }
}

#[cfg(not(windows))]
pub(crate) fn capture_foreground() -> Option<image::RgbaImage> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bug_screenshots_are_jpeg_and_at_most_1920_wide() {
        use base64::Engine;
        let shot = image::RgbaImage::from_fn(2560, 1440, |x, y| {
            image::Rgba([(x % 255) as u8, (y % 255) as u8, 90, 255])
        });
        let uri = jpeg_data_uri(&shot).unwrap();
        let data = uri.strip_prefix("data:image/jpeg;base64,").unwrap();
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(data)
            .unwrap();
        let decoded = image::load_from_memory(&bytes).unwrap();
        assert_eq!((decoded.width(), decoded.height()), (1920, 1080));
        assert!(bytes.len() <= 2_500_000);
    }

    #[test]
    fn a_capture_becomes_a_tv_sized_png_and_black_frames_are_skipped() {
        let mut shot = image::RgbaImage::new(3840, 2160);
        for (x, y, p) in shot.enumerate_pixels_mut() {
            *p = image::Rgba([(x % 256) as u8, (y % 256) as u8, 128, 255]);
        }
        assert!(!blank(&shot));
        let uri = data_uri(&shot).expect("fits");
        let png = gamenight_protocol::artwork::decode_png_data_uri(&uri).unwrap();
        let back = image::load_from_memory(&png).unwrap();
        assert!(back.width() <= 640 && back.width() >= 320);
        assert_eq!(back.width() * 9, back.height() * 16);
        assert!(blank(&image::RgbaImage::new(1920, 1080)));
    }

    #[test]
    fn only_plain_game_ids_name_a_file() {
        assert!(file(&GameId::new("sideways")).is_some());
        assert!(file(&GameId::new("../evil")).is_none());
        assert!(file(&GameId::new("a/b")).is_none());
    }
}
