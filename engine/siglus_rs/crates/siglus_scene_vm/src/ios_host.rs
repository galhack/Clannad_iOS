//! iOS host-driven Siglus FFI.
//!
//! UIKit/SwiftUI owns the platform run loop.  The host supplies a CAMetalLayer-backed
//! UIView pointer and advances the engine once per display-link tick.

#![cfg(any(target_os = "ios", target_os = "visionos"))]

use std::ffi::{CStr, c_char, c_void};
use std::ptr::NonNull;
use std::sync::{Mutex, Once, OnceLock};
use std::time::{Duration, Instant};

use raw_window_handle::{RawDisplayHandle, RawWindowHandle, UiKitDisplayHandle, UiKitWindowHandle};

use crate::host::{
    SiglusHost, SiglusHostConfig, SiglusNativeMessageBoxCallback, cstr_opt, cstr_required,
    default_frame_interval_ms,
};
use crate::render::Renderer;
use crate::runtime::input::VmMouseButton;

static IOS_PANIC_HOOK: Once = Once::new();
static IOS_TRACE_STATUS: OnceLock<bool> = OnceLock::new();
static IOS_LAST_STATUS: Mutex<Option<Instant>> = Mutex::new(None);

fn install_ios_panic_hook() {
    IOS_PANIC_HOOK.call_once(|| {
        let _ = env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("warn"))
            .try_init();
        std::panic::set_hook(Box::new(|info| {
            let location = info
                .location()
                .map(|loc| format!("{}:{}", loc.file(), loc.line()))
                .unwrap_or_else(|| "<unknown>".to_string());
            let message = if let Some(s) = info.payload().downcast_ref::<&str>() {
                (*s).to_string()
            } else if let Some(s) = info.payload().downcast_ref::<String>() {
                s.clone()
            } else {
                "<non-string panic payload>".to_string()
            };
            eprintln!("[SIGLUS_IOS_PANIC] panic at {location}: {message}");
            eprintln!(
                "[SIGLUS_IOS_PANIC] backtrace:\n{}",
                std::backtrace::Backtrace::force_capture()
            );
        }));
    });
}

fn aspect_fit_viewport(
    surface_w: u32,
    surface_h: u32,
    logical_w: u32,
    logical_h: u32,
) -> (u32, u32, u32, u32) {
    let sw = surface_w.max(1) as f64;
    let sh = surface_h.max(1) as f64;
    let lw = logical_w.max(1) as f64;
    let lh = logical_h.max(1) as f64;
    let scale = (sw / lw).min(sh / lh);
    let vw = (lw * scale).round().max(1.0).min(sw) as u32;
    let vh = (lh * scale).round().max(1.0).min(sh) as u32;
    let vx = ((surface_w.max(1).saturating_sub(vw)) / 2) as u32;
    let vy = ((surface_h.max(1).saturating_sub(vh)) / 2) as u32;
    (vx, vy, vw, vh)
}

unsafe fn build_host(
    ui_view: *mut c_void,
    surface_width: u32,
    surface_height: u32,
    native_scale_factor: f64,
    game_root_utf8: *const c_char,
) -> anyhow::Result<Box<SiglusHost>> {
    let view = NonNull::new(ui_view).ok_or_else(|| anyhow::anyhow!("ui_view is null"))?;
    let game_root = unsafe { cstr_required(game_root_utf8, "game_root_utf8") }?;
    let scale = if native_scale_factor.is_finite() && native_scale_factor > 0.0 {
        native_scale_factor as f32
    } else {
        1.0
    };
    let raw_display_handle = RawDisplayHandle::UiKit(UiKitDisplayHandle::new());
    let raw_window_handle = RawWindowHandle::UiKit(UiKitWindowHandle::new(view));
    let renderer = pollster::block_on(unsafe {
        Renderer::new_from_raw_handles(
            raw_display_handle,
            raw_window_handle,
            surface_width.max(1),
            surface_height.max(1),
            scale,
        )
    })?;
    let config = SiglusHostConfig::new(std::path::PathBuf::from(game_root));
    pollster::block_on(SiglusHost::new_with_renderer(config, renderer)).map(Box::new)
}

/// Pre-warm the GPU-free startup work before the UI thread creates the view.
///
/// Runs on the caller's queue (a background queue is expected): resolves the
/// localized Gameexe/scene archive, performs automatic secondary-key recovery
/// (writing `key.toml`), decrypts and indexes `Scene*.pck`, and parses the
/// shipped fonts. It never creates a wgpu instance/device and never touches
/// UIKit, so it is safe off the main thread. `siglus_ios_create` then reuses
/// the cached state and does not block on the first-launch key recovery.
///
/// `0` = ok, negative = error. May be called more than once (idempotent).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn siglus_ios_prepare(game_root_utf8: *const c_char) -> i32 {
    let Ok(game_root) = (unsafe { cstr_required(game_root_utf8, "game_root_utf8") }) else {
        return -1;
    };
    match crate::host::prepare_project(std::path::Path::new(&game_root)) {
        Ok(prepared) => {
            eprintln!(
                "[SIGLUS_IOS_PREPARE] ok dir={} scene_pck={} title={:?} key_configured={}",
                prepared.project_dir.display(),
                prepared.scene_pck_path.display(),
                prepared.game_title,
                prepared.key_configured
            );
            0
        }
        Err(error) => {
            log::error!("siglus_ios_prepare: {error:?}");
            eprintln!("[SIGLUS_IOS_ERROR] siglus_ios_prepare: {error:?}");
            -2
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn siglus_ios_create(
    ui_view: *mut c_void,
    surface_width: u32,
    surface_height: u32,
    native_scale_factor: f64,
    game_root_utf8: *const c_char,
) -> *mut c_void {
    install_ios_panic_hook();
    match unsafe {
        build_host(
            ui_view,
            surface_width,
            surface_height,
            native_scale_factor,
            game_root_utf8,
        )
    } {
        Ok(mut host) => {
            host.enable_native_story_choices();
            let (logical_w, logical_h) = host.logical_size();
            let (vx, vy, vw, vh) =
                aspect_fit_viewport(surface_width, surface_height, logical_w, logical_h);
            eprintln!(
                "[SIGLUS_IOS_VIEWPORT] create surface={}x{} scale={:.3} logical={}x{} viewport={}x{}+{}+{}",
                surface_width,
                surface_height,
                native_scale_factor,
                logical_w,
                logical_h,
                vw,
                vh,
                vx,
                vy
            );
            host.resize_with_logical_viewport(
                surface_width,
                surface_height,
                native_scale_factor as f32,
                logical_w,
                logical_h,
                vx,
                vy,
                vw,
                vh,
            );
            Box::into_raw(host) as *mut c_void
        }
        Err(e) => {
            log::error!("siglus_ios_create: {e:?}");
            eprintln!("[SIGLUS_IOS_ERROR] siglus_ios_create: {e:?}");
            std::ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn siglus_ios_set_native_messagebox_callback(
    handle: *mut c_void,
    callback: Option<SiglusNativeMessageBoxCallback>,
    user_data: *mut c_void,
) {
    if handle.is_null() {
        return;
    }
    let host = unsafe { &mut *(handle as *mut SiglusHost) };
    host.set_native_messagebox_callback(callback, user_data);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn siglus_ios_submit_messagebox_result(
    handle: *mut c_void,
    request_id: u64,
    value: i64,
) {
    if handle.is_null() {
        return;
    }
    let host = unsafe { &mut *(handle as *mut SiglusHost) };
    host.submit_native_messagebox_result(request_id, value);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn siglus_ios_frame_count(handle: *mut c_void) -> u32 {
    if handle.is_null() {
        return 0;
    }
    let host = unsafe { &*(handle as *const SiglusHost) };
    host.frame_count()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn siglus_ios_invalidate_frame(handle: *mut c_void) {
    if !handle.is_null() {
        let host = unsafe { &mut *(handle as *mut SiglusHost) };
        host.invalidate_frame();
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn siglus_ios_step(handle: *mut c_void, dt_ms: u32) -> i32 {
    if handle.is_null() {
        eprintln!("[SIGLUS_IOS_ERROR] siglus_ios_step: null handle");
        return 2;
    }
    let host = unsafe { &mut *(handle as *mut SiglusHost) };
    let result = host.step(default_frame_interval_ms(dt_ms));
    if *IOS_TRACE_STATUS
        .get_or_init(|| std::env::var("SIGLUS_IOS_TRACE_STATUS").as_deref() == Ok("1"))
    {
        if let Ok(mut last) = IOS_LAST_STATUS.lock() {
            if last.is_none_or(|time| time.elapsed() >= Duration::from_secs(5)) {
                *last = Some(Instant::now());
                eprintln!("[SIGLUS_IOS_TRACE] {}", host.debug_status_summary());
            }
        }
    }
    match result {
        Ok(false) => 0,
        Ok(true) => {
            eprintln!(
                "[SIGLUS_IOS_STATUS] siglus_ios_step: engine requested exit; {}",
                host.debug_status_summary()
            );
            1
        }
        Err(err) => {
            eprintln!(
                "[SIGLUS_IOS_ERROR] siglus_ios_step: {err:?}; {}",
                host.debug_status_summary()
            );
            2
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn siglus_ios_resize(
    handle: *mut c_void,
    surface_width: u32,
    surface_height: u32,
) {
    if handle.is_null() {
        return;
    }
    let host = unsafe { &mut *(handle as *mut SiglusHost) };
    let sf = host.renderer_mut().scale_factor();
    let (logical_w, logical_h) = host.logical_size();
    let (vx, vy, vw, vh) = aspect_fit_viewport(surface_width, surface_height, logical_w, logical_h);
    eprintln!(
        "[SIGLUS_IOS_VIEWPORT] resize surface={}x{} scale={:.3} logical={}x{} viewport={}x{}+{}+{}",
        surface_width, surface_height, sf, logical_w, logical_h, vw, vh, vx, vy
    );
    host.resize_with_logical_viewport(
        surface_width.max(1),
        surface_height.max(1),
        sf,
        logical_w,
        logical_h,
        vx,
        vy,
        vw,
        vh,
    );
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn siglus_ios_resize_viewport(
    handle: *mut c_void,
    surface_width: u32,
    surface_height: u32,
    viewport_x: u32,
    viewport_y: u32,
    viewport_width: u32,
    viewport_height: u32,
) {
    if handle.is_null() {
        return;
    }
    let host = unsafe { &mut *(handle as *mut SiglusHost) };
    let sf = host.renderer_mut().scale_factor();
    let (logical_w, logical_h) = host.logical_size();
    eprintln!(
        "[SIGLUS_IOS_VIEWPORT] resize_viewport surface={}x{} scale={:.3} logical={}x{} viewport={}x{}+{}+{}",
        surface_width,
        surface_height,
        sf,
        logical_w,
        logical_h,
        viewport_width,
        viewport_height,
        viewport_x,
        viewport_y
    );
    host.resize_with_logical_viewport(
        surface_width.max(1),
        surface_height.max(1),
        sf,
        logical_w,
        logical_h,
        viewport_x,
        viewport_y,
        viewport_width.max(1),
        viewport_height.max(1),
    );
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn siglus_ios_logical_size(
    handle: *mut c_void,
    width_out: *mut u32,
    height_out: *mut u32,
) {
    if handle.is_null() {
        return;
    }
    let host = unsafe { &mut *(handle as *mut SiglusHost) };
    let (w, h) = host.logical_size();
    if let Some(out) = unsafe { width_out.as_mut() } {
        *out = w;
    }
    if let Some(out) = unsafe { height_out.as_mut() } {
        *out = h;
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn siglus_ios_touch(
    handle: *mut c_void,
    phase: i32,
    x_points: f64,
    y_points: f64,
) {
    if handle.is_null() {
        return;
    }
    let host = unsafe { &mut *(handle as *mut SiglusHost) };
    // UIKit delivers points.  The VM input model is logical coordinates, so pass
    // points directly.
    host.touch(phase, x_points, y_points);
}

/// Feed a mouse-button transition from the iOS/visionOS shell.
///
/// iPhones and iPads have no secondary mouse button, so the native shell
/// synthesises one for two-finger gestures. `button`: 0 = left, 1 = right.
/// `pressed`: non-zero = down, 0 = up.  Lives in the shared iOS/visionOS
/// module so both slices export the same symbol.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn siglus_ios_mouse_button(handle: *mut c_void, button: i32, pressed: i32) {
    let Some(host) = (unsafe { (handle as *mut SiglusHost).as_mut() }) else {
        return;
    };
    let button = if button == 1 {
        VmMouseButton::Right
    } else {
        VmMouseButton::Left
    };
    if pressed != 0 {
        host.mouse_down(button);
    } else {
        host.mouse_up(button);
    }
}

/// Feed mouse-wheel steps from the iOS/visionOS shell (two-finger pan).
///
/// `up` is a wheel delta in the desktop convention: positive = scroll up
/// (one notch is +1).  The VM accumulates and consumes the delta.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn siglus_ios_mouse_wheel(handle: *mut c_void, up: i32) {
    let Some(host) = (unsafe { (handle as *mut SiglusHost).as_mut() }) else {
        return;
    };
    host.mouse_wheel(up);
}

/// Report whether the engine's text editbox currently accepts typed text.
///
/// Touch shells poll this every frame to show/hide the software keyboard
/// automatically (`1` while an editbox has focus, `0` otherwise) instead of
/// relying on a manual keyboard button. Mirrors
/// `siglus_android_editbox_accepts_direct_text`; the iOS/visionOS module is
/// shared, so both slices export it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn siglus_ios_editbox_active(handle: *mut c_void) -> i32 {
    let Some(host) = (unsafe { (handle as *mut SiglusHost).as_mut() }) else {
        return 0;
    };
    if host.editbox_accepts_direct_text() {
        1
    } else {
        0
    }
}

/// Queue the engine's system menu (settings/save/load) from the control bar.
///
/// Returns `1` when the menu was queued and `0` when the engine's own guards
/// refuse it (menu disabled, backlog / hidden message window open, an EXCALL
/// scene such as the menu itself is already active, a movie is playing, or a
/// native message box is pending).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn siglus_ios_open_menu(handle: *mut c_void) -> i32 {
    let Some(host) = (unsafe { (handle as *mut SiglusHost).as_mut() }) else {
        return 0;
    };
    if host.open_syscom_menu() { 1 } else { 0 }
}

/// Turn the engine's "skip everything" fast-forward on/off for touch clients.
///
/// `on != 0` enables unread-skip + read-skip + auto-skip (the game's own skip
/// feature) and keeps skipping across scenes; it still stops at choices and
/// message boxes. `on == 0` restores the engine's previous skip flags.
/// Returns `1` when the VM is skipping after the change, `0` otherwise.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn siglus_ios_set_skip(handle: *mut c_void, on: i32) -> i32 {
    let Some(host) = (unsafe { (handle as *mut SiglusHost).as_mut() }) else {
        return 0;
    };
    if host.set_skip(on != 0) { 1 } else { 0 }
}

/// Read the skip state without re-enabling it or forcing another VM pump.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn siglus_ios_is_skipping(handle: *mut c_void) -> i32 {
    let Some(host) = (unsafe { (handle as *mut SiglusHost).as_mut() }) else {
        return 0;
    };
    i32::from(host.is_skipping())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn siglus_ios_system_interface_active(handle: *mut c_void) -> i32 {
    let Some(host) = (unsafe { (handle as *const SiglusHost).as_ref() }) else {
        return 0;
    };
    i32::from(host.system_interface_active())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn siglus_ios_selection_json(
    handle: *mut c_void,
    buffer: *mut u8,
    capacity: usize,
) -> usize {
    let Some(host) = (unsafe { (handle as *const SiglusHost).as_ref() }) else {
        return 0;
    };
    let Some(bytes) = host.story_selection_json() else {
        return 0;
    };
    if !buffer.is_null() && capacity >= bytes.len() {
        unsafe {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), buffer, bytes.len());
        }
    }
    bytes.len()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn siglus_ios_select_choice(
    handle: *mut c_void,
    generation: u64,
    index: i32,
) -> i32 {
    let Some(host) = (unsafe { (handle as *mut SiglusHost).as_mut() }) else {
        return 0;
    };
    if host.select_story_choice(generation, index) {
        1
    } else {
        0
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn siglus_ios_text_input(handle: *mut c_void, text_utf8: *const c_char) {
    let Some(host) = (unsafe { (handle as *mut SiglusHost).as_mut() }) else {
        return;
    };
    if let Some(text) = unsafe { cstr_opt(text_utf8) } {
        host.text_input(&text);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn siglus_ios_ime_preedit(
    handle: *mut c_void,
    text_utf8: *const c_char,
    cursor_start: i32,
    cursor_end: i32,
) {
    let Some(host) = (unsafe { (handle as *mut SiglusHost).as_mut() }) else {
        return;
    };
    if text_utf8.is_null() {
        host.ime_disabled();
        return;
    }
    let text = unsafe { CStr::from_ptr(text_utf8) }
        .to_string_lossy()
        .into_owned();
    let cursor = if cursor_start >= 0 && cursor_end >= 0 {
        Some((cursor_start as usize, cursor_end as usize))
    } else {
        None
    };
    host.ime_preedit(&text, cursor);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn siglus_ios_key_down(handle: *mut c_void, key_code: i32) {
    let Some(host) = (unsafe { (handle as *mut SiglusHost).as_mut() }) else {
        return;
    };
    host.key_down_code(key_code);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn siglus_ios_key_up(handle: *mut c_void, key_code: i32) {
    let Some(host) = (unsafe { (handle as *mut SiglusHost).as_mut() }) else {
        return;
    };
    host.key_up_code(key_code);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn siglus_ios_destroy(handle: *mut c_void) {
    if handle.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(handle as *mut SiglusHost) });
}
