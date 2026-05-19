//! Screen + system-audio capture. This is the single OS-specific seam:
//! the Windows path uses Windows.Graphics.Capture (BGRA frames) and
//! WASAPI render-loopback (system audio). Every other module is
//! portable, so only this file is `cfg`-gated.
//!
//! Frames and audio flow over `std::sync::mpsc` so the encoder threads
//! can own the receivers directly. Video uses a depth-2 channel and
//! drops the oldest frame under back-pressure — for a live screen the
//! freshest frame always wins; queuing them just adds latency.

use std::sync::mpsc::Receiver;

/// One captured screen frame: tightly packed BGRA8888, top-down.
pub struct ScreenFrame {
    pub data: Vec<u8>,
    pub width: usize,
    pub height: usize,
}

/// A running capture. Drop `stop` to halt both grabbers.
pub struct Capture {
    pub width: u32,
    pub height: u32,
    pub video_rx: Receiver<ScreenFrame>,
    /// Interleaved-stereo f32 @ 48 kHz, arbitrary chunk lengths. Stays
    /// silent (sender dropped) when system-audio capture is unavailable.
    pub audio_rx: Receiver<Vec<f32>>,
    pub stop: StopHandle,
}

#[cfg(windows)]
mod platform {
    use super::*;

    const VIDEO_CHANNEL_DEPTH: usize = 2;
    const AUDIO_CHANNEL_DEPTH: usize = 64;
    use crate::media::{OPUS_CHANNELS, OPUS_SAMPLE_RATE};
    use anyhow::{Context, Result};
    use std::collections::VecDeque;
    use std::fmt;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::mpsc::{sync_channel, Sender, SyncSender, TrySendError};
    use std::sync::Arc;
    use tracing::{info, warn};
    use wasapi::{Direction, SampleType, StreamMode, WaveFormat};
    use windows_capture::capture::{
        CaptureControl, Context as WcContext, GraphicsCaptureApiHandler,
    };
    use windows_capture::frame::Frame;
    use windows_capture::graphics_capture_api::InternalCaptureControl;
    use windows_capture::monitor::Monitor;
    use windows_capture::settings::{
        ColorFormat, CursorCaptureSettings, DirtyRegionSettings, DrawBorderSettings,
        MinimumUpdateIntervalSettings, SecondaryWindowSettings, Settings,
    };

    #[derive(Debug)]
    pub struct HandlerError(String);
    impl fmt::Display for HandlerError {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            write!(f, "{}", self.0)
        }
    }
    impl std::error::Error for HandlerError {}

    struct FrameSink {
        tx: SyncSender<ScreenFrame>,
        scratch: Vec<u8>,
    }

    impl GraphicsCaptureApiHandler for FrameSink {
        type Flags = SyncSender<ScreenFrame>;
        type Error = HandlerError;

        fn new(ctx: WcContext<Self::Flags>) -> Result<Self, Self::Error> {
            Ok(Self {
                tx: ctx.flags,
                scratch: Vec::new(),
            })
        }

        fn on_frame_arrived(
            &mut self,
            frame: &mut Frame,
            capture_control: InternalCaptureControl,
        ) -> Result<(), Self::Error> {
            let buffer = frame
                .buffer()
                .map_err(|e| HandlerError(format!("frame buffer: {e}")))?;
            let width = buffer.width() as usize;
            let height = buffer.height() as usize;
            let bytes = buffer.as_nopadding_buffer(&mut self.scratch);

            let screen = ScreenFrame {
                data: bytes.to_vec(),
                width,
                height,
            };
            match self.tx.try_send(screen) {
                Ok(()) | Err(TrySendError::Full(_)) => {}
                Err(TrySendError::Disconnected(_)) => capture_control.stop(),
            }
            Ok(())
        }

        fn on_closed(&mut self) -> Result<(), Self::Error> {
            Ok(())
        }
    }

    pub struct StopHandle {
        screen: Option<CaptureControl<FrameSink, HandlerError>>,
        audio_stop: Arc<AtomicBool>,
        audio_join: Option<std::thread::JoinHandle<()>>,
    }

    impl Drop for StopHandle {
        fn drop(&mut self) {
            if let Some(control) = self.screen.take() {
                let _ = control.stop();
            }
            self.audio_stop.store(true, Ordering::SeqCst);
            if let Some(join) = self.audio_join.take() {
                let _ = join.join();
            }
        }
    }

    pub fn start() -> Result<Capture> {
        let monitor = Monitor::primary().context("no primary monitor")?;
        let width = monitor.width().context("monitor width")?;
        let height = monitor.height().context("monitor height")?;

        let (video_tx, video_rx) = sync_channel::<ScreenFrame>(VIDEO_CHANNEL_DEPTH);
        let settings = Settings::new(
            monitor,
            CursorCaptureSettings::WithCursor,
            DrawBorderSettings::WithoutBorder,
            SecondaryWindowSettings::Default,
            MinimumUpdateIntervalSettings::Default,
            DirtyRegionSettings::Default,
            ColorFormat::Bgra8,
            video_tx,
        );
        let capture_control = FrameSink::start_free_threaded(settings)
            .map_err(|e| anyhow::anyhow!("couldn't start screen capture: {e}"))?;

        let (audio_tx, audio_rx) = sync_channel::<Vec<f32>>(AUDIO_CHANNEL_DEPTH);
        let audio_stop = Arc::new(AtomicBool::new(false));
        let audio_join = spawn_audio_loopback(audio_tx, audio_stop.clone());

        Ok(Capture {
            width,
            height,
            video_rx,
            audio_rx,
            stop: StopHandle {
                screen: Some(capture_control),
                audio_stop,
                audio_join,
            },
        })
    }

    /// WASAPI render-endpoint loopback → resampled f32 stereo @ 48 kHz.
    /// Best-effort: a failure here just means the session has no audio,
    /// never that it fails to start.
    fn spawn_audio_loopback(
        tx: SyncSender<Vec<f32>>,
        stop: Arc<AtomicBool>,
    ) -> Option<std::thread::JoinHandle<()>> {
        let (ready_tx, ready_rx) = std::sync::mpsc::channel::<bool>();
        let handle = std::thread::Builder::new()
            .name("audio-loopback".to_string())
            .spawn(move || {
                if let Err(error) = audio_loopback_loop(&tx, &stop, &ready_tx) {
                    let _ = ready_tx.send(false);
                    warn!("system audio capture unavailable: {error:#}");
                }
            })
            .ok()?;
        match ready_rx.recv() {
            Ok(true) => info!("system audio loopback started"),
            _ => { /* thread logged why; session continues silent */ }
        }
        Some(handle)
    }

    fn audio_loopback_loop(
        tx: &SyncSender<Vec<f32>>,
        stop: &Arc<AtomicBool>,
        ready_tx: &Sender<bool>,
    ) -> Result<()> {
        let _ = wasapi::initialize_mta();
        let enumerator = wasapi::DeviceEnumerator::new().context("WASAPI enumerator")?;
        // Default *render* device + Capture direction = system loopback.
        let device = enumerator
            .get_default_device(&Direction::Render)
            .context("default render device")?;
        let mut audio_client = device.get_iaudioclient().context("audio client")?;

        let format = WaveFormat::new(
            32,
            32,
            &SampleType::Float,
            OPUS_SAMPLE_RATE as usize,
            OPUS_CHANNELS,
            None,
        );
        let (_, min_time) = audio_client.get_device_period().context("device period")?;
        let mode = StreamMode::EventsShared {
            autoconvert: true,
            buffer_duration_hns: min_time,
        };
        audio_client
            .initialize_client(&format, &Direction::Capture, &mode)
            .context("initialize loopback client")?;

        let h_event = audio_client.set_get_eventhandle().context("event handle")?;
        let capture_client = audio_client
            .get_audiocaptureclient()
            .context("capture client")?;
        let block_align = format.get_blockalign() as usize;
        audio_client.start_stream().context("start stream")?;
        let _ = ready_tx.send(true);

        let mut raw: VecDeque<u8> = VecDeque::new();
        while !stop.load(Ordering::SeqCst) {
            capture_client
                .read_from_device_to_deque(&mut raw)
                .context("read loopback")?;

            let frames = raw.len() / block_align;
            if frames > 0 {
                let mut samples = Vec::with_capacity(frames * OPUS_CHANNELS);
                for _ in 0..frames {
                    for _ in 0..OPUS_CHANNELS {
                        let bytes = [
                            raw.pop_front().unwrap(),
                            raw.pop_front().unwrap(),
                            raw.pop_front().unwrap(),
                            raw.pop_front().unwrap(),
                        ];
                        samples.push(f32::from_le_bytes(bytes));
                    }
                }
                let _ = tx.try_send(samples);
            }

            if h_event.wait_for_event(200).is_err() && stop.load(Ordering::SeqCst) {
                break;
            }
        }
        let _ = audio_client.stop_stream();
        Ok(())
    }
}

#[cfg(not(windows))]
mod platform {
    use super::*;
    use anyhow::Result;

    pub struct StopHandle;

    pub fn start() -> Result<Capture> {
        anyhow::bail!(
            "screen and audio capture are implemented for Windows only; \
             this binary is the Windows host agent"
        )
    }
}

pub use platform::start;
pub use platform::StopHandle;
