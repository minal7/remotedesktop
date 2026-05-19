//! egui front-end for the Windows host. Renders the same five-state
//! status surface as `host-mac/RemoteDesktopHost/MenuContent.swift`
//! (idle → starting → advertising → paired → error) plus an extra
//! "signing in" state for the CloudKit web-auth bootstrap that the
//! macOS host gets for free via the system iCloud session.

use crate::app_state::{Command, CommandSender, HostStatus, SharedState};
use eframe::egui::{
    self, Align, Color32, Layout, RichText, Rounding, Stroke, Vec2,
};
use std::time::Duration;

pub struct HostApp {
    state: SharedState,
    commands: CommandSender,
    quitting: bool,
}

impl HostApp {
    pub fn new(state: SharedState, commands: CommandSender) -> Self {
        Self {
            state,
            commands,
            quitting: false,
        }
    }
}

impl eframe::App for HostApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
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

        if self.quitting {
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
                ui.label(
                    RichText::new("Remote Desktop Host")
                        .strong()
                        .size(16.0),
                );
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
            HostStatus::Advertising { code } => self.advertising(ui, code),
            HostStatus::Paired { client } => self.paired(ui, client),
            HostStatus::Error(message) => self.error(ui, message),
        }
    }

    fn idle(&self, ui: &mut egui::Ui) {
        ui.label(
            RichText::new("Ready to accept a pairing.")
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

    fn advertising(&self, ui: &mut egui::Ui, code: &str) {
        ui.vertical_centered(|ui| {
            ui.label(
                RichText::new("Enter this code on your iPad or iPhone:")
                    .color(Color32::from_gray(140))
                    .size(13.0),
            );
            ui.add_space(12.0);
            egui::Frame::none()
                .fill(Color32::from_rgba_unmultiplied(255, 255, 255, 14))
                .rounding(Rounding::same(12.0))
                .inner_margin(egui::Margin::symmetric(20.0, 16.0))
                .show(ui, |ui| {
                    ui.label(
                        RichText::new(format_code(code))
                            .strong()
                            .monospace()
                            .size(38.0)
                            .color(Color32::WHITE),
                    );
                });
            ui.add_space(14.0);
            let stop = egui::Button::new(
                RichText::new("Stop").size(13.0).color(Color32::WHITE),
            )
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
            let retry = egui::Button::new(
                RichText::new("Retry").color(Color32::WHITE).size(13.0),
            )
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
                    self.quitting = true;
                }
            });
        });
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

fn format_code(code: &str) -> String {
    if code.len() == 6 && code.chars().all(|c| c.is_ascii_digit()) {
        format!("{} {}", &code[..3], &code[3..])
    } else {
        code.to_string()
    }
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

    let in_rect = |x: u32, y: u32, x0: u32, x1: u32, y0: u32, y1: u32| {
        x >= x0 && x < x1 && y >= y0 && y < y1
    };

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
