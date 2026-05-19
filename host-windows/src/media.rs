//! Software media encoders. Both are pure and portable so the whole
//! pipeline is unit-testable on the dev machine:
//!
//! - `VideoEncoder`: BGRA → I420 → H.264 Annex-B (OpenH264). Annex-B
//!   with start codes is exactly what webrtc-rs's H264 payloader wants.
//! - `AudioEncoder`: interleaved-stereo f32 @ 48 kHz → Opus, one 20 ms
//!   packet per call.

use anyhow::{Context, Result};
use openh264::encoder::{Encoder, EncoderConfig, FrameRate, IntraFramePeriod, UsageType};
use openh264::formats::YUVBuffer;
use openh264::OpenH264API;

/// Opus is fixed at 48 kHz stereo; one frame is 20 ms = 960 samples per
/// channel = 1920 interleaved samples.
#[cfg_attr(not(windows), allow(dead_code))] // only the Windows capture path reads this
pub const OPUS_SAMPLE_RATE: u32 = 48_000;
pub const OPUS_CHANNELS: usize = 2;
pub const OPUS_FRAME_SAMPLES: usize = 960;
pub const OPUS_FRAME_INTERLEAVED: usize = OPUS_FRAME_SAMPLES * OPUS_CHANNELS;

pub struct VideoEncoder {
    encoder: Encoder,
}

impl VideoEncoder {
    pub fn new(target_bitrate_bps: u32, max_fps: f32) -> Result<Self> {
        // Periodic IDR every `gop_frames` frames (~2 s at 60 fps) so a
        // late-joining decoder recovers without RTCP feedback, and
        // anyone who drops a P-frame resyncs quickly. PLI/FIR from the
        // receiver still triggers an out-of-band keyframe via
        // `force_intra_frame`.
        let gop_frames = (max_fps * 2.0).max(30.0) as u32;
        let config = EncoderConfig::new()
            .usage_type(UsageType::ScreenContentRealTime)
            .bitrate(openh264::encoder::BitRate::from_bps(target_bitrate_bps))
            .max_frame_rate(FrameRate::from_hz(max_fps))
            .intra_frame_period(IntraFramePeriod::from_num_frames(gop_frames))
            .skip_frames(true);
        let encoder = Encoder::with_api_config(OpenH264API::from_source(), config)
            .context("couldn't initialize the OpenH264 encoder")?;
        Ok(Self { encoder })
    }

    /// Flags the next encoded frame as an IDR keyframe. Used to satisfy
    /// receiver PLI/FIR (an iOS client that joins after the initial IDR
    /// needs a fresh one to start decoding).
    pub fn force_intra_frame(&mut self) {
        self.encoder.force_intra_frame();
    }

    /// Encodes one BGRA frame (top-down, tightly packed `w*h*4`) and
    /// returns Annex-B H.264. Empty when the encoder skipped the frame.
    pub fn encode_bgra(&mut self, bgra: &[u8], width: usize, height: usize) -> Result<Vec<u8>> {
        let (width, height) = (width & !1, height & !1);
        anyhow::ensure!(
            width >= 2 && height >= 2,
            "frame too small after even-rounding: {width}x{height}"
        );
        anyhow::ensure!(
            bgra.len()
                >= width
                    .checked_mul(height)
                    .and_then(|p| p.checked_mul(4))
                    .unwrap_or(0),
            "BGRA buffer {} too small for {width}x{height}",
            bgra.len()
        );
        let yuv = bgra_to_i420(bgra, width, height);
        let buffer = YUVBuffer::from_vec(yuv, width, height);
        let bitstream = self
            .encoder
            .encode(&buffer)
            .context("OpenH264 frame encode failed")?;
        Ok(bitstream.to_vec())
    }
}

/// BGRA8888 → planar I420 (BT.601 limited range), matching what the
/// browser/iOS H.264 decoder expects. `width`/`height` must be even.
pub fn bgra_to_i420(bgra: &[u8], width: usize, height: usize) -> Vec<u8> {
    let y_size = width * height;
    let c_size = (width / 2) * (height / 2);
    let mut out = vec![0u8; y_size + 2 * c_size];
    let (y_plane, uv) = out.split_at_mut(y_size);
    let (u_plane, v_plane) = uv.split_at_mut(c_size);

    for row in 0..height {
        for col in 0..width {
            let i = (row * width + col) * 4;
            let b = bgra[i] as i32;
            let g = bgra[i + 1] as i32;
            let r = bgra[i + 2] as i32;

            let y = (66 * r + 129 * g + 25 * b + 128) >> 8;
            y_plane[row * width + col] = (y + 16).clamp(0, 255) as u8;

            if row % 2 == 0 && col % 2 == 0 {
                let u = (-38 * r - 74 * g + 112 * b + 128) >> 8;
                let v = (112 * r - 94 * g - 18 * b + 128) >> 8;
                let ci = (row / 2) * (width / 2) + (col / 2);
                u_plane[ci] = (u + 128).clamp(0, 255) as u8;
                v_plane[ci] = (v + 128).clamp(0, 255) as u8;
            }
        }
    }
    out
}

pub struct AudioEncoder {
    encoder: audiopus::coder::Encoder,
    scratch: Vec<u8>,
}

impl AudioEncoder {
    pub fn new() -> Result<Self> {
        let encoder = audiopus::coder::Encoder::new(
            audiopus::SampleRate::Hz48000,
            audiopus::Channels::Stereo,
            audiopus::Application::Audio,
        )
        .context("couldn't initialize the Opus encoder")?;
        Ok(Self {
            encoder,
            scratch: vec![0u8; 4000],
        })
    }

    /// Encodes exactly one 20 ms stereo frame (`OPUS_FRAME_INTERLEAVED`
    /// f32 samples, L/R interleaved, [-1, 1]).
    pub fn encode_frame(&mut self, interleaved: &[f32]) -> Result<Vec<u8>> {
        anyhow::ensure!(
            interleaved.len() == OPUS_FRAME_INTERLEAVED,
            "Opus frame must be {OPUS_FRAME_INTERLEAVED} interleaved samples, got {}",
            interleaved.len()
        );
        let written = self
            .encoder
            .encode_float(interleaved, &mut self.scratch)
            .context("Opus encode failed")?;
        Ok(self.scratch[..written].to_vec())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn i420_buffer_is_correctly_sized() {
        let (w, h) = (4, 4);
        let bgra = vec![0u8; w * h * 4];
        let yuv = bgra_to_i420(&bgra, w, h);
        assert_eq!(yuv.len(), w * h + 2 * (w / 2) * (h / 2));
    }

    #[test]
    fn solid_white_maps_to_high_luma() {
        let (w, h) = (2, 2);
        let bgra = vec![255u8; w * h * 4];
        let yuv = bgra_to_i420(&bgra, w, h);
        // BT.601: white luma ≈ 235 (limited range), well above mid-grey.
        assert!(yuv[0] > 200, "white Y was {}", yuv[0]);
    }

    #[test]
    fn solid_black_maps_to_low_luma() {
        let (w, h) = (2, 2);
        let bgra = vec![0u8; w * h * 4];
        let yuv = bgra_to_i420(&bgra, w, h);
        assert!(yuv[0] <= 16, "black Y was {}", yuv[0]);
    }

    #[test]
    fn audio_encoder_round_trips_a_frame() {
        let mut enc = AudioEncoder::new().unwrap();
        let frame = vec![0.0f32; OPUS_FRAME_INTERLEAVED];
        let packet = enc.encode_frame(&frame).unwrap();
        assert!(!packet.is_empty());
    }

    #[test]
    fn audio_encoder_rejects_wrong_frame_size() {
        let mut enc = AudioEncoder::new().unwrap();
        assert!(enc.encode_frame(&[0.0; 100]).is_err());
    }
}
