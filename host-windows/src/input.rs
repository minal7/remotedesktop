//! Synthetic input injection. Decoded `ClientMessage`s become OS input
//! events via `enigo` (SendInput on Windows, CGEvent on macOS — so this
//! compiles and is exercisable on the dev machine too).
//!
//! `enigo::Enigo` is single-threaded and must not cross threads, so all
//! injection happens on one dedicated OS thread fed by a channel. The
//! public `InputInjector` is a cheap, cloneable handle.

use crate::protocol::ClientMessage;
use enigo::{Axis, Button, Coordinate, Direction, Enigo, Key, Keyboard, Mouse, Settings};
use std::sync::mpsc::{self, Sender};
use std::thread;
use tracing::{debug, warn};

/// Pixels of wheel travel that equal one `enigo` scroll notch. The wire
/// protocol carries pixel deltas; enigo only does discrete steps.
const SCROLL_PIXELS_PER_NOTCH: i32 = 40;

#[derive(Clone)]
pub struct InputInjector {
    tx: Sender<ClientMessage>,
}

impl InputInjector {
    /// Spawns the injection thread. Fails only if `enigo` can't grab the
    /// OS input APIs (e.g. missing Accessibility approval on macOS).
    pub fn spawn() -> anyhow::Result<Self> {
        let (ready_tx, ready_rx) = mpsc::channel::<Result<(), String>>();
        let (tx, rx) = mpsc::channel::<ClientMessage>();

        thread::Builder::new()
            .name("input-injector".to_string())
            .spawn(move || match Enigo::new(&Settings::default()) {
                Ok(mut enigo) => {
                    let _ = ready_tx.send(Ok(()));
                    let mut state = PointerState::default();
                    while let Ok(message) = rx.recv() {
                        apply(&mut enigo, &mut state, message);
                    }
                    debug!("input injector thread exiting");
                }
                Err(error) => {
                    let _ = ready_tx.send(Err(error.to_string()));
                }
            })?;

        match ready_rx.recv() {
            Ok(Ok(())) => Ok(Self { tx }),
            Ok(Err(reason)) => Err(anyhow::anyhow!("couldn't start input injection: {reason}")),
            Err(_) => Err(anyhow::anyhow!("input injection thread died on startup")),
        }
    }

    /// Hand a decoded message to the injection thread. Non-blocking;
    /// drops silently once the thread is gone (session torn down).
    pub fn apply(&self, message: ClientMessage) {
        let _ = self.tx.send(message);
    }
}

#[derive(Default)]
struct PointerState {
    buttons: u8,
}

fn apply(enigo: &mut Enigo, state: &mut PointerState, message: ClientMessage) {
    let result = match message {
        ClientMessage::Pointer { x, y, buttons } => inject_pointer(enigo, state, x, y, buttons),
        ClientMessage::Scroll { dx, dy, .. } => inject_scroll(enigo, dx, dy),
        ClientMessage::Key { usage, down, .. } => inject_key(enigo, usage, down),
        ClientMessage::Text(text) => enigo.text(&text).map(|_| ()),
        // hello / qos / bye are handled by the session, never injected.
        ClientMessage::Hello { .. } | ClientMessage::Qos { .. } | ClientMessage::Bye { .. } => {
            Ok(())
        }
    };
    if let Err(error) = result {
        warn!("input injection failed: {error:?}");
    }
}

fn inject_pointer(
    enigo: &mut Enigo,
    state: &mut PointerState,
    x: i32,
    y: i32,
    buttons: u8,
) -> enigo::InputResult<()> {
    enigo.move_mouse(x, y, Coordinate::Abs)?;

    let pressed = buttons & !state.buttons;
    let released = state.buttons & !buttons;
    for (bit, button) in [
        (0b001, Button::Left),
        (0b010, Button::Right),
        (0b100, Button::Middle),
    ] {
        if pressed & bit != 0 {
            enigo.button(button, Direction::Press)?;
        }
        if released & bit != 0 {
            enigo.button(button, Direction::Release)?;
        }
    }
    state.buttons = buttons;
    Ok(())
}

fn inject_scroll(enigo: &mut Enigo, dx: i32, dy: i32) -> enigo::InputResult<()> {
    if dy != 0 {
        // Wire protocol: positive `dy` means content moves up (scroll
        // up). enigo's positive vertical length scrolls down — invert.
        enigo.scroll(-notches(dy), Axis::Vertical)?;
    }
    if dx != 0 {
        enigo.scroll(notches(dx), Axis::Horizontal)?;
    }
    Ok(())
}

fn notches(pixels: i32) -> i32 {
    let n = pixels / SCROLL_PIXELS_PER_NOTCH;
    if n != 0 {
        n
    } else if pixels > 0 {
        1
    } else {
        -1
    }
}

fn inject_key(enigo: &mut Enigo, usage: u32, down: bool) -> enigo::InputResult<()> {
    let Some(key) = hid_to_key(usage) else {
        debug!("dropping unmapped HID usage 0x{usage:02x}");
        return Ok(());
    };
    let direction = if down {
        Direction::Press
    } else {
        Direction::Release
    };
    enigo.key(key, direction)
}

/// USB HID usage page 0x07 → cross-platform `enigo::Key`. Letters,
/// digits and punctuation go through `Key::Unicode` so the host's
/// keymap resolves the physical key; named keys cover everything else.
/// Mirrors `host-mac/RemoteDesktopHost/HIDUsage.swift`.
fn hid_to_key(usage: u32) -> Option<Key> {
    // a–z
    if (0x04..=0x1D).contains(&usage) {
        return Some(Key::Unicode((b'a' + (usage - 0x04) as u8) as char));
    }
    // 1–9 then 0
    if (0x1E..=0x26).contains(&usage) {
        return Some(Key::Unicode((b'1' + (usage - 0x1E) as u8) as char));
    }
    if usage == 0x27 {
        return Some(Key::Unicode('0'));
    }
    Some(match usage {
        0x28 => Key::Return,
        0x29 => Key::Escape,
        0x2A => Key::Backspace,
        0x2B => Key::Tab,
        0x2C => Key::Space,
        0x2D => Key::Unicode('-'),
        0x2E => Key::Unicode('='),
        0x2F => Key::Unicode('['),
        0x30 => Key::Unicode(']'),
        0x31 => Key::Unicode('\\'),
        0x33 => Key::Unicode(';'),
        0x34 => Key::Unicode('\''),
        0x35 => Key::Unicode('`'),
        0x36 => Key::Unicode(','),
        0x37 => Key::Unicode('.'),
        0x38 => Key::Unicode('/'),
        0x39 => Key::CapsLock,
        0x3A => Key::F1,
        0x3B => Key::F2,
        0x3C => Key::F3,
        0x3D => Key::F4,
        0x3E => Key::F5,
        0x3F => Key::F6,
        0x40 => Key::F7,
        0x41 => Key::F8,
        0x42 => Key::F9,
        0x43 => Key::F10,
        0x44 => Key::F11,
        0x45 => Key::F12,
        0x4A => Key::Home,
        0x4B => Key::PageUp,
        0x4C => Key::Delete,
        0x4D => Key::End,
        0x4E => Key::PageDown,
        0x4F => Key::RightArrow,
        0x50 => Key::LeftArrow,
        0x51 => Key::DownArrow,
        0x52 => Key::UpArrow,
        0xE0 | 0xE4 => Key::Control,
        0xE1 | 0xE5 => Key::Shift,
        0xE2 | 0xE6 => Key::Alt,
        0xE3 | 0xE7 => Key::Meta,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn letters_map_to_unicode() {
        assert_eq!(hid_to_key(0x04), Some(Key::Unicode('a')));
        assert_eq!(hid_to_key(0x1D), Some(Key::Unicode('z')));
    }

    #[test]
    fn digits_map_one_through_zero() {
        assert_eq!(hid_to_key(0x1E), Some(Key::Unicode('1')));
        assert_eq!(hid_to_key(0x27), Some(Key::Unicode('0')));
    }

    #[test]
    fn control_keys_and_modifiers() {
        assert_eq!(hid_to_key(0x28), Some(Key::Return));
        assert_eq!(hid_to_key(0x2C), Some(Key::Space));
        assert_eq!(hid_to_key(0xE3), Some(Key::Meta));
        assert_eq!(hid_to_key(0xE5), Some(Key::Shift));
    }

    #[test]
    fn unmapped_usage_is_none() {
        assert_eq!(hid_to_key(0x00), None);
        assert_eq!(hid_to_key(0xFF), None);
    }

    #[test]
    fn scroll_notches_round_toward_at_least_one() {
        assert_eq!(notches(0), -1); // never called with 0 in practice
        assert_eq!(notches(10), 1);
        assert_eq!(notches(-10), -1);
        assert_eq!(notches(120), 3);
    }
}
