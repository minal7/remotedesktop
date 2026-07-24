//! egui front-end for the Windows host. Renders the same five-state
//! status surface as `host-mac/RemoteDesktopHost/MenuContent.swift`
//! (idle → starting → advertising → paired → error) plus an extra
//! "signing in" state for the CloudKit web-auth bootstrap that the
//! macOS host gets for free via the system iCloud session.

use crate::app_state::{Command, CommandSender, HostStatus, SharedState};
use eframe::egui::{self, Align, Color32, Layout, RichText, Rounding, Stroke, Vec2};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

pub struct HostApp {
    state: SharedState,
    commands: CommandSender,
    // Shared so the tray thread can flag a real quit before asking the
    // window to close; `update` checks it to know whether a close request
    // should hide-to-tray (X button) or actually terminate (Quit).
    quitting: Arc<AtomicBool>,
    launch_at_login: bool,
}

impl HostApp {
    pub fn new(
        state: SharedState,
        commands: CommandSender,
        ctx: egui::Context,
        show_item_id: tray_icon::menu::MenuId,
        quit_item_id: tray_icon::menu::MenuId,
        launch_at_login: bool,
    ) -> Self {
        let quitting = Arc::new(AtomicBool::new(false));
        let ctx_clone = ctx.clone();
        let show_id = show_item_id.clone();
        let quit_id = quit_item_id.clone();
        let commands_clone = commands.clone();
        let quitting_tray = quitting.clone();

        std::thread::spawn(move || {
            loop {
                // Poll tray events
                if let Ok(event) = tray_icon::TrayIconEvent::receiver().try_recv() {
                    match event {
                        tray_icon::TrayIconEvent::Click {
                            button: tray_icon::MouseButton::Left,
                            ..
                        }
                        | tray_icon::TrayIconEvent::DoubleClick {
                            button: tray_icon::MouseButton::Left,
                            ..
                        } => {
                            #[cfg(windows)]
                            set_window_native_visibility(true);
                            ctx_clone.request_repaint();
                        }
                        _ => {}
                    }
                }

                // Poll menu events
                if let Ok(event) = tray_icon::menu::MenuEvent::receiver().try_recv() {
                    if event.id == show_id {
                        #[cfg(windows)]
                        set_window_native_visibility(true);
                        ctx_clone.request_repaint();
                    } else if event.id == quit_id {
                        // Flag the quit *before* requesting close so the
                        // window's close handler tears down instead of
                        // hiding to tray. Make it visible first so the
                        // event loop is awake to process the close even
                        // when we'd previously hidden it.
                        quitting_tray.store(true, Ordering::SeqCst);
                        commands_clone.send(Command::Quit);
                        #[cfg(windows)]
                        set_window_native_visibility(true);
                        ctx_clone.send_viewport_cmd(egui::ViewportCommand::Close);
                        ctx_clone.request_repaint();
                        break;
                    }
                }

                std::thread::sleep(std::time::Duration::from_millis(50));
            }
        });

        Self {
            state,
            commands,
            quitting,
            launch_at_login,
        }
    }
}

impl eframe::App for HostApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        let quitting = self.quitting.load(Ordering::SeqCst);
        if ctx.input(|i| i.viewport().close_requested()) && !quitting {
            // Plain window-close (X button) hides to tray instead of
            // quitting; a real Quit sets `quitting` and falls through.
            ctx.send_viewport_cmd(egui::ViewportCommand::CancelClose);
            #[cfg(windows)]
            set_window_native_visibility(false);
        }

        // Keep refreshing so background state changes show up quickly.
        // egui is otherwise lazy when no input events arrive.
        ctx.request_repaint_after(Duration::from_millis(200));

        let snapshot = match self.state.read() {
            Ok(guard) => guard.clone(),
            Err(poisoned) => poisoned.into_inner().clone(),
        };

        egui::CentralPanel::default().show(ctx, |ui| {
            ui.add_space(8.0);
            self.header(ui, &snapshot);
            ui.add_space(8.0);
            ui.separator();
            ui.add_space(12.0);
            self.content(ui, &snapshot.status);
            ui.add_space(12.0);
            ui.with_layout(Layout::bottom_up(Align::Min), |ui| {
                ui.add_space(4.0);
                self.footer(ui, &snapshot);
                ui.separator();
            });
        });

        if quitting {
            ctx.send_viewport_cmd(egui::ViewportCommand::Close);
        }
    }

    fn on_exit(&mut self, _gl: Option<&eframe::glow::Context>) {
        self.commands.send(Command::Quit);
    }
}

impl HostApp {
    fn header(&self, ui: &mut egui::Ui, snapshot: &crate::app_state::AppState) {
        ui.horizontal(|ui| {
            ui.add_space(4.0);
            display_glyph(ui, 40.0, accent_color());
            ui.add_space(10.0);
            ui.vertical(|ui| {
                ui.label(RichText::new("Remote Desktop Host").strong().size(16.0));
                ui.label(
                    RichText::new(snapshot.status.short_label())
                        .color(Color32::from_gray(150))
                        .size(12.0),
                );
            });
        });
    }

    fn content(&self, ui: &mut egui::Ui, status: &HostStatus) {
        match status {
            HostStatus::Initializing => spinner_row(ui, "Starting up…"),
            HostStatus::SigningIn => spinner_row(ui, "Signing in to iCloud…"),
            HostStatus::Idle => self.idle(ui),
            HostStatus::Starting => spinner_row(ui, "Starting…"),
            HostStatus::Advertising => self.advertising(ui),
            HostStatus::Paired { client } => self.paired(ui, client),
            HostStatus::Error(message) => self.error(ui, message),
        }
    }

    fn idle(&self, ui: &mut egui::Ui) {
        ui.label(
            RichText::new("Ready for devices on your Apple Account.")
                .color(Color32::from_gray(140))
                .size(13.0),
        );
        ui.add_space(12.0);
        let button = egui::Button::new(
            RichText::new("Start listening")
                .strong()
                .color(Color32::WHITE)
                .size(14.0),
        )
        .min_size(Vec2::new(ui.available_width(), 36.0))
        .fill(accent_color())
        .rounding(Rounding::same(8.0))
        .stroke(Stroke::NONE);
        if ui.add(button).clicked() {
            self.commands.send(Command::Start);
        }
    }

    fn advertising(&self, ui: &mut egui::Ui) {
        ui.vertical_centered(|ui| {
            ui.label(
                RichText::new("Your iPhone or iPad connects automatically when it uses the same Apple Account.")
                    .color(Color32::from_gray(140))
                    .size(13.0),
            );
            ui.add_space(14.0);
            let stop = egui::Button::new(RichText::new("Stop").size(13.0).color(Color32::WHITE))
                .min_size(Vec2::new(100.0, 28.0))
                .fill(Color32::from_rgba_unmultiplied(255, 255, 255, 18))
                .rounding(Rounding::same(6.0))
                .stroke(Stroke::NONE);
            if ui.add(stop).clicked() {
                self.commands.send(Command::Stop);
            }
        });
    }

    fn paired(&self, ui: &mut egui::Ui, client: &str) {
        ui.vertical_centered(|ui| {
            ui.label(
                RichText::new("\u{2714} Connected")
                    .color(Color32::from_rgb(80, 200, 120))
                    .strong()
                    .size(16.0),
            );
            ui.add_space(4.0);
            ui.label(
                RichText::new(client)
                    .color(Color32::from_gray(160))
                    .size(13.0),
            );
            ui.add_space(14.0);
            let end = egui::Button::new(
                RichText::new("End session")
                    .size(13.0)
                    .color(Color32::WHITE),
            )
            .min_size(Vec2::new(140.0, 30.0))
            .fill(Color32::from_rgba_unmultiplied(255, 80, 80, 200))
            .rounding(Rounding::same(6.0))
            .stroke(Stroke::NONE);
            if ui.add(end).clicked() {
                self.commands.send(Command::Stop);
            }
        });
    }

    fn error(&self, ui: &mut egui::Ui, message: &str) {
        ui.horizontal_wrapped(|ui| {
            ui.label(
                RichText::new("\u{26A0}")
                    .color(Color32::from_rgb(255, 175, 60))
                    .size(18.0),
            );
            ui.label(
                RichText::new(message)
                    .color(Color32::from_gray(220))
                    .size(13.0),
            );
        });
        ui.add_space(12.0);
        ui.horizontal(|ui| {
            let retry = egui::Button::new(RichText::new("Retry").color(Color32::WHITE).size(13.0))
                .min_size(Vec2::new(90.0, 28.0))
                .fill(accent_color())
                .rounding(Rounding::same(6.0))
                .stroke(Stroke::NONE);
            if ui.add(retry).clicked() {
                self.commands.send(Command::Start);
            }
        });
    }

    fn footer(&mut self, ui: &mut egui::Ui, snapshot: &crate::app_state::AppState) {
        // Bottom-up layout: this host/quit row sits at the very bottom,
        // the launch-at-login row is added afterwards so it renders above.
        ui.horizontal(|ui| {
            if !snapshot.host_name.is_empty() {
                ui.label(
                    RichText::new(format!("Host: {}", snapshot.host_name))
                        .color(Color32::from_gray(130))
                        .size(11.0),
                );
            }
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                let quit = egui::Button::new(
                    RichText::new("Quit")
                        .color(Color32::from_gray(220))
                        .size(12.0),
                )
                .min_size(Vec2::new(60.0, 22.0))
                .fill(Color32::TRANSPARENT)
                .rounding(Rounding::same(4.0))
                .stroke(Stroke::new(1.0, Color32::from_gray(80)));
                if ui.add(quit).clicked() {
                    self.commands.send(Command::Quit);
                    self.quitting.store(true, Ordering::SeqCst);
                }
            });
        });
        ui.add_space(6.0);
        self.launch_at_login_toggle(ui);
    }

    fn launch_at_login_toggle(&mut self, ui: &mut egui::Ui) {
        let checkbox = ui.checkbox(
            &mut self.launch_at_login,
            RichText::new("Open automatically at startup")
                .color(Color32::from_gray(170))
                .size(12.0),
        );
        if checkbox.changed() {
            if let Err(error) = crate::autostart::apply(self.launch_at_login) {
                tracing::warn!("couldn't update launch-at-login registration: {error:#}");
            }
            let settings = crate::settings::Settings {
                launch_at_login: self.launch_at_login,
            };
            if let Err(error) = crate::settings::save(&settings) {
                tracing::warn!("couldn't persist launch-at-login preference: {error:#}");
            }
        }
    }
}

fn spinner_row(ui: &mut egui::Ui, message: &str) {
    ui.horizontal(|ui| {
        ui.spinner();
        ui.label(
            RichText::new(message)
                .color(Color32::from_gray(180))
                .size(13.0),
        );
    });
}

fn display_glyph(ui: &mut egui::Ui, size: f32, color: Color32) {
    // A small drawn monitor: filled rounded rectangle for the screen
    // and a stand, so we don't depend on system-symbol fonts that may
    // not be available on every Windows install.
    let (response, painter) = ui.allocate_painter(Vec2::splat(size), egui::Sense::hover());
    let rect = response.rect;
    let screen = egui::Rect::from_min_size(
        rect.min + Vec2::new(size * 0.08, size * 0.12),
        Vec2::new(size * 0.84, size * 0.56),
    );
    painter.rect_filled(screen, Rounding::same(size * 0.10), color);
    let stand = egui::Rect::from_min_size(
        rect.min + Vec2::new(size * 0.42, size * 0.70),
        Vec2::new(size * 0.16, size * 0.10),
    );
    painter.rect_filled(stand, Rounding::ZERO, Color32::from_gray(180));
    let base = egui::Rect::from_min_size(
        rect.min + Vec2::new(size * 0.28, size * 0.80),
        Vec2::new(size * 0.44, size * 0.08),
    );
    painter.rect_filled(base, Rounding::same(size * 0.02), Color32::from_gray(180));
}

fn accent_color() -> Color32 {
    Color32::from_rgb(58, 132, 255)
}

/// Build a small in-memory icon used both for the window frame and the
/// Windows taskbar entry. Procedurally drawn so the binary doesn't need
/// an external `.ico` asset bundled in.
pub fn make_icon() -> egui::IconData {
    const SIZE: u32 = 64;
    let mut rgba = vec![0u8; (SIZE * SIZE * 4) as usize];

    let bezel = [38u8, 42, 50, 255];
    let screen = [58u8, 132, 255, 255];
    let stand = [180u8, 180, 190, 255];

    let in_rect =
        |x: u32, y: u32, x0: u32, x1: u32, y0: u32, y1: u32| x >= x0 && x < x1 && y >= y0 && y < y1;

    for y in 0..SIZE {
        for x in 0..SIZE {
            let idx = ((y * SIZE + x) * 4) as usize;
            // Outer bezel
            if in_rect(x, y, 4, 60, 6, 46) {
                rgba[idx..idx + 4].copy_from_slice(&bezel);
            }
            // Screen
            if in_rect(x, y, 8, 56, 10, 42) {
                rgba[idx..idx + 4].copy_from_slice(&screen);
            }
            // Stand
            if in_rect(x, y, 28, 36, 46, 54) {
                rgba[idx..idx + 4].copy_from_slice(&stand);
            }
            // Base
            if in_rect(x, y, 18, 46, 54, 58) {
                rgba[idx..idx + 4].copy_from_slice(&stand);
            }
        }
    }

    egui::IconData {
        rgba,
        width: SIZE,
        height: SIZE,
    }
}

#[cfg(windows)]
fn set_window_native_visibility(visible: bool) {
    use std::ffi::OsStr;
    use std::iter::once;
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        FindWindowW, ShowWindow, SW_HIDE, SW_RESTORE, SW_SHOW,
    };

    let title: Vec<u16> = OsStr::new("Remote Desktop Host")
        .encode_wide()
        .chain(once(0))
        .collect();

    unsafe {
        let hwnd = FindWindowW(std::ptr::null(), title.as_ptr());
        if hwnd != std::ptr::null_mut() {
            if visible {
                ShowWindow(hwnd, SW_SHOW);
                ShowWindow(hwnd, SW_RESTORE);
            } else {
                ShowWindow(hwnd, SW_HIDE);
            }
        }
    }
}
