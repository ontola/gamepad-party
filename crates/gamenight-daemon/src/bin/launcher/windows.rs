use std::{
    fs::OpenOptions,
    io::{self, Write},
    os::windows::io::AsRawHandle,
    path::{Path, PathBuf},
    process::Child,
};
use windows_sys::Win32::{
    Foundation::{CloseHandle, HANDLE},
    System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JobObjectBasicAccountingInformation,
        JobObjectExtendedLimitInformation, QueryInformationJobObject, SetInformationJobObject,
        TerminateJobObject, JOBOBJECT_BASIC_ACCOUNTING_INFORMATION,
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    },
};

/// Own all descendants, including games that outlive their immediate parent.
pub struct ProcessTree(HANDLE);
impl ProcessTree {
    pub fn attach(child: &Child) -> io::Result<Self> {
        // SAFETY: null security/name pointers request an unnamed, private job.
        let handle = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
        if handle.is_null() {
            return Err(io::Error::last_os_error());
        }
        let job = Self(handle);
        let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { std::mem::zeroed() };
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        // SAFETY: the live job and Child own these handles; the structure size matches its class.
        if unsafe {
            SetInformationJobObject(
                handle,
                JobObjectExtendedLimitInformation,
                &limits as *const _ as *const _,
                std::mem::size_of_val(&limits) as u32,
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        if unsafe { AssignProcessToJobObject(handle, child.as_raw_handle() as HANDLE) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(job)
    }
    pub fn close(self) -> io::Result<()> {
        // Termination is asynchronous. Wait for every descendant before handing off to Update.exe.
        if unsafe { TerminateJobObject(self.0, 0) } == 0 {
            return Err(io::Error::last_os_error());
        }
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        loop {
            let mut accounting: JOBOBJECT_BASIC_ACCOUNTING_INFORMATION =
                unsafe { std::mem::zeroed() };
            if unsafe {
                QueryInformationJobObject(
                    self.0,
                    JobObjectBasicAccountingInformation,
                    &mut accounting as *mut _ as *mut _,
                    std::mem::size_of_val(&accounting) as u32,
                    std::ptr::null_mut(),
                )
            } == 0
            {
                return Err(io::Error::last_os_error());
            }
            if accounting.ActiveProcesses == 0 {
                return Ok(());
            }
            if std::time::Instant::now() >= deadline {
                return Err(io::Error::other(
                    "Games are still closing; update postponed",
                ));
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
    }
}
impl Drop for ProcessTree {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}

/// A party PC can keep GameNight open for days, so look again now and then.
const RECHECK: std::time::Duration = std::time::Duration::from_secs(30 * 60);

/// Files the launcher shares with the daemon for in-place updates; see
/// `gamenight_daemon::HostUpdate`.
pub struct UpdateFiles {
    pub ready: PathBuf,
    pub resume: PathBuf,
    pub splash: PathBuf,
}
impl UpdateFiles {
    pub fn new(data: &Path) -> Self {
        Self {
            ready: data.join("update-ready.json"),
            resume: data.join("resume.json"),
            splash: data.join("update-splash.flag"),
        }
    }
}

pub struct Updates {
    manager: Option<velopack::UpdateManager>,
    /// True while a check or download is running; never block exit on it.
    busy: std::sync::Arc<std::sync::atomic::AtomicBool>,
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
    log: PathBuf,
    files: UpdateFiles,
}
impl Updates {
    pub fn start(data: &Path) -> Self {
        // No token in the client. The installed manifest chooses stable or preview;
        // including GitHub prereleases cannot switch a stable install's channel.
        let source = velopack::sources::GithubSource::new(
            "https://github.com/ontola/gamepad-party",
            None,
            true,
        );
        Self::with_source(data, source)
    }
    pub fn with_source(
        data: &Path,
        source: impl velopack::sources::UpdateSource + 'static,
    ) -> Self {
        use std::sync::{atomic::AtomicBool, atomic::Ordering, Arc};
        let log = data.join("updater.log");
        let files = UpdateFiles::new(data);
        // Readiness is re-established by this session's check, never inherited.
        let _ = std::fs::remove_file(&files.ready);
        let manager = match velopack::UpdateManager::new(source, None, None) {
            Ok(manager) if !manager.get_is_portable() => Some(manager),
            Ok(_) => None,
            Err(error) => {
                append_log(&log, &format!("Portable/uninstalled build: {error}"));
                None
            }
        };
        let busy = Arc::new(AtomicBool::new(manager.is_some()));
        let stop = Arc::new(AtomicBool::new(false));
        if let Some(manager) = manager.clone() {
            let (log, busy, stop) = (log.clone(), busy.clone(), stop.clone());
            let ready = files.ready.clone();
            std::thread::spawn(move || loop {
                busy.store(true, Ordering::SeqCst);
                let result = (|| -> Result<Option<String>, velopack::Error> {
                    if let velopack::UpdateCheck::UpdateAvailable(update) =
                        manager.check_for_updates()?
                    {
                        manager.download_updates(&update, None)?;
                        return Ok(Some(update.TargetFullRelease.Version.clone()));
                    }
                    Ok(None)
                })();
                // Clear before logging, so whoever reads the log may exit and apply.
                busy.store(false, Ordering::SeqCst);
                match result {
                    Ok(Some(version)) => {
                        // Tell the lobby, which offers a restart between games.
                        let note = serde_json::json!({ "version": version }).to_string();
                        let temporary = ready.with_extension("tmp");
                        if std::fs::write(&temporary, note).is_ok() {
                            let _ = std::fs::rename(&temporary, &ready);
                        }
                        append_log(
                            &log,
                            &format!(
                                "Update downloaded ({version}); waiting for Splitscreen Club to close."
                            ),
                        );
                        return;
                    }
                    Ok(None) => {}
                    Err(error) => {
                        append_log(&log, &format!("Update check/download skipped: {error}"))
                    }
                }
                let wake = std::time::Instant::now() + RECHECK;
                while std::time::Instant::now() < wake {
                    if stop.load(Ordering::SeqCst) {
                        return;
                    }
                    std::thread::sleep(std::time::Duration::from_secs(1));
                }
            });
        }
        Self {
            manager,
            busy,
            stop,
            log,
            files,
        }
    }
    pub fn files(&self) -> &UpdateFiles {
        &self.files
    }
    /// The daemon saved the party and stopped to update. Apply the update and
    /// start again, with a cover over the screen until the new lobby is up.
    /// Returns false when no update could be applied, so the caller restarts
    /// the current version itself.
    pub fn restart_into_update(self) -> bool {
        use std::sync::atomic::Ordering;
        self.stop.store(true, Ordering::SeqCst);
        let _ = std::fs::remove_file(&self.files.ready);
        let Some(manager) = self.manager else {
            return false;
        };
        let Some(update) = manager.get_update_pending_restart() else {
            append_log(&self.log, "Restart requested but no update is pending.");
            return false;
        };
        if let Err(error) = spawn_splash(&self.files.splash, "Updating Splitscreen Club\u{2026}") {
            append_log(&self.log, &format!("Update cover unavailable: {error}"));
        }
        // Silent: the cover is the progress, and nobody is at a keyboard.
        match manager.wait_exit_then_apply_updates(update, true, true, Vec::<String>::new()) {
            Ok(()) => {
                append_log(&self.log, "Applying update and restarting with the party.");
                true
            }
            Err(error) => {
                append_log(&self.log, &format!("Could not apply update: {error}"));
                let _ = std::fs::remove_file(&self.files.splash);
                false
            }
        }
    }
    /// The daemon stopped to open another lobby; this launcher starts it again.
    pub fn restart_for_lobby(self, title: &str) {
        self.stop.store(true, std::sync::atomic::Ordering::SeqCst);
        append_log(
            &self.log,
            &format!("Restarting into {title} with the party."),
        );
    }
    /// Call only after all application children have stopped. Never block exit on networking.
    pub fn apply_on_exit(self) {
        use std::sync::atomic::Ordering;
        self.stop.store(true, Ordering::SeqCst);
        if self.busy.load(Ordering::SeqCst) {
            append_log(
                &self.log,
                "Download still running; update deferred to a later session.",
            );
            return;
        }
        if let Some(manager) = self.manager {
            if let Some(update) = manager.get_update_pending_restart() {
                if let Err(error) = manager.apply_updates_and_exit(update) {
                    append_log(&self.log, &format!("Could not apply update: {error}"));
                }
            }
        }
    }
}
/// Run a copy of this executable from outside the install directory, which
/// the updater is about to replace, as a full-screen cover.
pub fn spawn_splash(flag: &Path, text: &str) -> io::Result<()> {
    use std::os::windows::process::CommandExt;
    let exe = std::env::current_exe()?;
    let source = exe
        .parent()
        .ok_or_else(|| io::Error::other("No package directory"))?;
    let target = std::env::temp_dir().join("GameNightUpdateCover");
    std::fs::create_dir_all(&target)?;
    // The bundled C runtime travels along; the machine may not have one.
    for entry in std::fs::read_dir(source)? {
        let path = entry?.path();
        if path
            .extension()
            .is_some_and(|ext| ext.eq_ignore_ascii_case("dll"))
        {
            std::fs::copy(&path, target.join(path.file_name().unwrap()))?;
        }
    }
    let copy = target.join("GameNightUpdateCover.exe");
    std::fs::copy(&exe, &copy)?;
    std::fs::write(flag, b"updating")?;
    std::process::Command::new(copy)
        .arg("--update-cover")
        .arg(flag)
        .arg(text)
        .current_dir(&target)
        // DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP: outlive this launcher.
        .creation_flags(0x0000_0008 | 0x0000_0200)
        .spawn()?;
    Ok(())
}

/// The loading screen's pixels on a window: the software-drawn
/// [`Splash`](gamenight_daemon::splash::Splash) in a 32-bit DIB that
/// `WM_PAINT` blits. The process is per-monitor DPI aware, so a 4K TV gets
/// 4K pixels instead of a stretched 1080p bitmap.
struct Surface {
    splash: gamenight_daemon::splash::Splash,
    dc: windows_sys::Win32::Graphics::Gdi::HDC,
    bits: *mut u32,
    started: std::time::Instant,
    state: gamenight_daemon::splash::State,
}

// The window thread owns it; the statics below only hand it to the window
// procedure on that same thread.
unsafe impl Send for Surface {}

static SURFACE: std::sync::Mutex<Option<Surface>> = std::sync::Mutex::new(None);

/// Sharp text on high-DPI screens. Called before the first window; the
/// launcher shows nothing else that depends on scaling.
fn dpi_aware() {
    unsafe {
        windows_sys::Win32::UI::HiDpi::SetProcessDpiAwarenessContext(
            windows_sys::Win32::UI::HiDpi::DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
        );
    }
}

impl Surface {
    /// `area` is the window in screen coordinates, `main` the main monitor.
    unsafe fn new(
        area: [i32; 4],
        main: [i32; 4],
        kind: gamenight_daemon::splash::Kind,
        text: String,
        progress: Option<f32>,
    ) -> Option<Surface> {
        use windows_sys::Win32::Graphics::Gdi::{
            CreateCompatibleDC, CreateDIBSection, SelectObject, BITMAPINFO, BI_RGB, DIB_RGB_COLORS,
        };
        let (w, h) = (area[2] - area[0], area[3] - area[1]);
        let main = [
            main[0] - area[0],
            main[1] - area[1],
            main[2] - area[0],
            main[3] - area[1],
        ];
        let splash = gamenight_daemon::splash::Splash::new(w, h, main, kind);
        let mut info: BITMAPINFO = std::mem::zeroed();
        info.bmiHeader.biSize = std::mem::size_of_val(&info.bmiHeader) as u32;
        info.bmiHeader.biWidth = w;
        info.bmiHeader.biHeight = -h; // top-down
        info.bmiHeader.biPlanes = 1;
        info.bmiHeader.biBitCount = 32;
        info.bmiHeader.biCompression = BI_RGB;
        let dc = CreateCompatibleDC(std::ptr::null_mut());
        let mut bits: *mut core::ffi::c_void = std::ptr::null_mut();
        let bitmap = CreateDIBSection(
            dc,
            &info,
            DIB_RGB_COLORS,
            &mut bits,
            std::ptr::null_mut(),
            0,
        );
        if dc.is_null() || bitmap.is_null() || bits.is_null() {
            return None;
        }
        SelectObject(dc, bitmap);
        let state = gamenight_daemon::splash::State {
            progress,
            text,
            time: 0.0,
        };
        let surface = Surface {
            splash,
            dc,
            bits: bits.cast(),
            started: std::time::Instant::now(),
            state,
        };
        surface.splash.draw_all(surface.pixels(), &surface.state);
        Some(surface)
    }

    #[allow(clippy::mut_from_ref)] // the DIB's memory, only touched on the window thread
    fn pixels(&self) -> &mut [u32] {
        let (w, h) = self.splash.size();
        unsafe { std::slice::from_raw_parts_mut(self.bits, (w * h) as usize) }
    }

    /// Draw the moving parts and ask the window to show them.
    unsafe fn tick(&mut self, window: windows_sys::Win32::Foundation::HWND) {
        use windows_sys::Win32::{Foundation::RECT, Graphics::Gdi::InvalidateRect};
        self.state.time = self.started.elapsed().as_secs_f32();
        for r in self.splash.draw(self.pixels(), &self.state) {
            let rect = RECT {
                left: r[0],
                top: r[1],
                right: r[2],
                bottom: r[3],
            };
            InvalidateRect(window, &rect, 0);
        }
    }

    unsafe fn paint(&self, window: windows_sys::Win32::Foundation::HWND) {
        use windows_sys::Win32::Graphics::Gdi::{
            BeginPaint, BitBlt, EndPaint, GdiFlush, PAINTSTRUCT, SRCCOPY,
        };
        let mut paint: PAINTSTRUCT = std::mem::zeroed();
        let dc = BeginPaint(window, &mut paint);
        GdiFlush();
        let r = paint.rcPaint;
        BitBlt(
            dc,
            r.left,
            r.top,
            r.right - r.left,
            r.bottom - r.top,
            self.dc,
            r.left,
            r.top,
            SRCCOPY,
        );
        EndPaint(window, &paint);
    }
}

/// The main monitor in screen coordinates.
fn main_monitor() -> [i32; 4] {
    use windows_sys::Win32::UI::WindowsAndMessaging::{GetSystemMetrics, SM_CXSCREEN, SM_CYSCREEN};
    unsafe {
        [
            0,
            0,
            GetSystemMetrics(SM_CXSCREEN),
            GetSystemMetrics(SM_CYSCREEN),
        ]
    }
}

/// The window procedure both screens share: paint from the surface, tick on
/// the timer (`done` says when to go), Esc minimises.
unsafe fn splash_proc(
    window: windows_sys::Win32::Foundation::HWND,
    message: u32,
    wparam: windows_sys::Win32::Foundation::WPARAM,
    lparam: windows_sys::Win32::Foundation::LPARAM,
    done: impl FnOnce(&mut gamenight_daemon::splash::State) -> bool,
) -> windows_sys::Win32::Foundation::LRESULT {
    use windows_sys::Win32::UI::{
        Input::KeyboardAndMouse::VK_ESCAPE,
        WindowsAndMessaging::{
            DefWindowProcW, DestroyWindow, PostQuitMessage, ShowWindow, SW_MINIMIZE, WM_DESTROY,
            WM_ERASEBKGND, WM_KEYDOWN, WM_PAINT, WM_TIMER,
        },
    };
    match message {
        WM_TIMER => {
            let mut surface = SURFACE.lock().unwrap_or_else(|e| e.into_inner());
            let live = match surface.as_mut() {
                Some(s) => {
                    let go = !done(&mut s.state);
                    if go {
                        s.tick(window);
                    }
                    go
                }
                None => false,
            };
            drop(surface);
            if !live {
                DestroyWindow(window);
            }
            0
        }
        WM_ERASEBKGND => 1,
        WM_PAINT => {
            if let Some(s) = SURFACE.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
                s.paint(window);
            } else {
                return DefWindowProcW(window, message, wparam, lparam);
            }
            0
        }
        WM_KEYDOWN if wparam == VK_ESCAPE as usize => {
            ShowWindow(window, SW_MINIMIZE);
            0
        }
        WM_DESTROY => {
            PostQuitMessage(0);
            0
        }
        _ => DefWindowProcW(window, message, wparam, lparam),
    }
}

/// Register `class`, open a borderless window over `area` and run its loop.
unsafe fn run_splash(
    class: &str,
    area: [i32; 4],
    ex_style: u32,
    style: u32,
    proc_: unsafe extern "system" fn(
        windows_sys::Win32::Foundation::HWND,
        u32,
        windows_sys::Win32::Foundation::WPARAM,
        windows_sys::Win32::Foundation::LPARAM,
    ) -> windows_sys::Win32::Foundation::LRESULT,
    after_show: impl FnOnce(windows_sys::Win32::Foundation::HWND),
) {
    use windows_sys::Win32::{
        Graphics::Gdi::UpdateWindow,
        System::LibraryLoader::GetModuleHandleW,
        UI::WindowsAndMessaging::{
            CreateWindowExW, DispatchMessageW, GetMessageW, LoadCursorW, LoadIconW, RegisterClassW,
            SetTimer, ShowWindow, TranslateMessage, IDC_ARROW, MSG, SW_SHOW, WNDCLASSW,
        },
    };
    let class: Vec<u16> = class.encode_utf16().chain(Some(0)).collect();
    let title: Vec<u16> = "Splitscreen Club\0".encode_utf16().collect();
    let instance = GetModuleHandleW(std::ptr::null());
    let mut window_class: WNDCLASSW = std::mem::zeroed();
    window_class.lpfnWndProc = Some(proc_);
    window_class.hInstance = instance;
    // winres embeds branding/gamenight.ico as resource 1.
    window_class.hIcon = LoadIconW(instance, std::ptr::without_provenance(1));
    window_class.hCursor = LoadCursorW(std::ptr::null_mut(), IDC_ARROW);
    window_class.lpszClassName = class.as_ptr();
    RegisterClassW(&window_class);
    let window = CreateWindowExW(
        ex_style,
        class.as_ptr(),
        title.as_ptr(),
        style,
        area[0],
        area[1],
        area[2] - area[0],
        area[3] - area[1],
        std::ptr::null_mut(),
        std::ptr::null_mut(),
        instance,
        std::ptr::null(),
    );
    if window.is_null() {
        return;
    }
    ShowWindow(window, SW_SHOW);
    UpdateWindow(window);
    after_show(window);
    // ~30 fps for the bar and the bob; only small rectangles are redrawn.
    SetTimer(window, 1, 33, None);
    let mut message: MSG = std::mem::zeroed();
    while GetMessageW(&mut message, std::ptr::null_mut(), 0, 0) > 0 {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    *SURFACE.lock().unwrap_or_else(|e| e.into_inner()) = None;
}

static COVER_FLAG: std::sync::OnceLock<(PathBuf, std::time::Instant)> = std::sync::OnceLock::new();

/// A borderless window over every screen saying what Splitscreen Club is
/// doing (updating, opening another lobby), the loading screen's look with
/// one line instead of the bar. It goes when the new lobby removes `flag`,
/// or after two minutes at most.
pub fn show_update_cover(flag: PathBuf, text: String) {
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        AllowSetForegroundWindow, GetSystemMetrics, SetForegroundWindow, ShowCursor, ASFW_ANY,
        SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN,
        WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_POPUP,
    };
    dpi_aware();
    let _ = COVER_FLAG.set((flag, std::time::Instant::now()));
    unsafe {
        let (x, y) = (
            GetSystemMetrics(SM_XVIRTUALSCREEN),
            GetSystemMetrics(SM_YVIRTUALSCREEN),
        );
        let area = [
            x,
            y,
            x + GetSystemMetrics(SM_CXVIRTUALSCREEN),
            y + GetSystemMetrics(SM_CYVIRTUALSCREEN),
        ];
        let kind = gamenight_daemon::splash::Kind::Cover;
        *SURFACE.lock().unwrap_or_else(|e| e.into_inner()) =
            Surface::new(area, main_monitor(), kind, text, None);
        run_splash(
            "GameNightUpdateCover",
            area,
            WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
            WS_POPUP,
            cover_proc,
            |window| {
                SetForegroundWindow(window);
                ShowCursor(0);
                // We hold the foreground now; let the new lobby take it from us.
                AllowSetForegroundWindow(ASFW_ANY);
            },
        );
    }
}

unsafe extern "system" fn cover_proc(
    window: windows_sys::Win32::Foundation::HWND,
    message: u32,
    wparam: windows_sys::Win32::Foundation::WPARAM,
    lparam: windows_sys::Win32::Foundation::LPARAM,
) -> windows_sys::Win32::Foundation::LRESULT {
    splash_proc(window, message, wparam, lparam, |_| {
        COVER_FLAG.get().is_none_or(|(flag, started)| {
            !flag.exists() || started.elapsed() > std::time::Duration::from_secs(120)
        })
    })
}

fn append_log(path: &Path, message: &str) {
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "{} {message}", utc_now());
    }
}

/// The current UTC time as `2026-10-19T19:52:03Z`, for the updater log.
fn utc_now() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    let (days, rest) = (secs / 86_400, secs % 86_400);
    // Civil date from days since 1970-01-01 (Howard Hinnant's algorithm).
    let z = days as i64 + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        rest / 3600,
        rest % 3600 / 60,
        rest % 60
    )
}
pub fn show_error(message: &str) {
    use windows_sys::Win32::UI::WindowsAndMessaging::{MessageBoxW, MB_ICONERROR, MB_OK};
    let text: Vec<u16> = format!("Splitscreen Club could not start or close.\n\n{message}")
        .encode_utf16()
        .chain(Some(0))
        .collect();
    let title: Vec<u16> = "Splitscreen Club".encode_utf16().chain(Some(0)).collect();
    unsafe {
        MessageBoxW(
            std::ptr::null_mut(),
            text.as_ptr(),
            title.as_ptr(),
            MB_OK | MB_ICONERROR,
        );
    }
}

static WELCOME: std::sync::OnceLock<(PathBuf, std::time::Instant)> = std::sync::OnceLock::new();
/// The bar as shown, the bar's target (eased towards).
static WELCOME_BAR: std::sync::Mutex<(f32, f32)> = std::sync::Mutex::new((0.0, 0.0));

/// Splitscreen Club's first screen, up the moment the launcher starts: the
/// browser host's loading screen (brand, amber bar, what the host is doing,
/// the controller card), full screen on the main monitor so it hands over to
/// the full-screen room without a desktop in between. It keeps a taskbar
/// entry under the launcher's identity and Esc minimises it, so it can be
/// sent to the background. The daemon writes "progress\ntext" to `flag` and
/// removes it once the lobby is on screen; then this window goes.
pub fn show_welcome(flag: PathBuf) {
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        AllowSetForegroundWindow, ASFW_ANY, WS_EX_APPWINDOW, WS_MINIMIZEBOX, WS_POPUP, WS_SYSMENU,
    };
    dpi_aware();
    let _ = WELCOME.set((flag, std::time::Instant::now()));
    *WELCOME_BAR.lock().unwrap_or_else(|e| e.into_inner()) = (0.0, 0.1);
    unsafe {
        let area = main_monitor();
        let kind = gamenight_daemon::splash::Kind::Welcome;
        let text = "Starting Splitscreen Club\u{2026}".to_owned();
        *SURFACE.lock().unwrap_or_else(|e| e.into_inner()) =
            Surface::new(area, area, kind, text, Some(0.0));
        run_splash(
            "GameNightWelcome",
            area,
            WS_EX_APPWINDOW,
            WS_POPUP | WS_SYSMENU | WS_MINIMIZEBOX,
            welcome_proc,
            // The lobby must be able to take the screen from this window.
            |_| {
                AllowSetForegroundWindow(ASFW_ANY);
            },
        );
    }
}

unsafe extern "system" fn welcome_proc(
    window: windows_sys::Win32::Foundation::HWND,
    message: u32,
    wparam: windows_sys::Win32::Foundation::WPARAM,
    lparam: windows_sys::Win32::Foundation::LPARAM,
) -> windows_sys::Win32::Foundation::LRESULT {
    splash_proc(window, message, wparam, lparam, |state| {
        let Some((flag, started)) = WELCOME.get() else {
            return true;
        };
        let Ok(content) = std::fs::read_to_string(flag) else {
            return true;
        };
        if started.elapsed() > std::time::Duration::from_secs(180) {
            return true;
        }
        let mut lines = content.lines();
        let target = lines
            .next()
            .and_then(|p| p.trim().parse::<f32>().ok())
            .unwrap_or(0.1)
            .clamp(0.0, 1.0);
        if let Some(text) = lines.next().filter(|t| !t.trim().is_empty()) {
            state.text = text.to_owned();
        }
        let mut bar = WELCOME_BAR.lock().unwrap_or_else(|e| e.into_inner());
        // Ease toward the step, then creep on while it takes long, so the
        // bar never looks stuck (but never passes the next step).
        bar.1 = bar.1.max(target);
        let (ceiling, speed) = if bar.0 < bar.1 {
            (bar.1, 0.08)
        } else {
            ((bar.1 + 0.12).min(0.97), 0.003)
        };
        bar.0 += (ceiling - bar.0).max(0.0) * speed;
        state.progress = Some(bar.0);
        false
    })
}
