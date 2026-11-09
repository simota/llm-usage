//! Colour for the tray menu.
//!
//! Ubuntu's AppIndicator extension sets a menu label with `set_text`, so the
//! text itself takes no colour or markup; what it does draw is each item's
//! `icon-data`, a PNG at menu-icon size on the item's trailing edge. These
//! icons carry what the card colours carry in the panel: a usage ring in the
//! severity hue with the pace tick on it, and the four severity silhouettes —
//! outlined in grey when the figure is not current (docs/design.md §6–7).

use crate::model::Severity;

#[derive(Clone, Debug, PartialEq)]
pub enum RowIcon {
    /// A window: how full, how far into it, and the severity it reads at.
    Gauge {
        used: f64,
        elapsed: Option<f64>,
        severity: Severity,
    },
    /// A spend allowance: how full, no window.
    Fill {
        used: f64,
        severity: Severity,
    },
    /// A card or summary mark for a current figure.
    Mark(Severity),
    Stale,
    Error,
    Unconfigured,
}

/// 16 logical pixels, drawn at 2× so HiDPI menus stay sharp.
const SIZE: usize = 32;
const SCALE: f32 = SIZE as f32 / 16.0;
const SAMPLES: usize = 4;

// Hues that hold up on both the dark and the light shell menu.
const BLUE: [u8; 3] = [0x0a, 0x84, 0xff];
const YELLOW: [u8; 3] = [0xff, 0xcc, 0x00];
const ORANGE: [u8; 3] = [0xff, 0x95, 0x00];
const RED: [u8; 3] = [0xff, 0x3b, 0x30];
const GREY: [u8; 3] = [0x8e, 0x8e, 0x93];
/// Lighter than the grey track, so the tick stands off it.
const TICK: [u8; 3] = [0xc7, 0xc7, 0xcc];

fn severity_colour(severity: Severity) -> [u8; 3] {
    match severity {
        Severity::Normal => BLUE,
        Severity::Caution => YELLOW,
        Severity::Warning => ORANGE,
        Severity::Critical => RED,
    }
}

/// Straight-alpha RGBA, composited front to back as layers are added.
struct Canvas {
    pixels: Vec<[f32; 4]>,
}

impl Canvas {
    fn new() -> Self {
        Self {
            pixels: vec![[0.0; 4]; SIZE * SIZE],
        }
    }

    /// Paints `colour` at `opacity` wherever `inside` holds, in 16-unit
    /// design coordinates, supersampled for antialiasing.
    fn fill(&mut self, colour: [u8; 3], opacity: f32, inside: impl Fn(f32, f32) -> bool) {
        for py in 0..SIZE {
            for px in 0..SIZE {
                let mut hits = 0;
                for sy in 0..SAMPLES {
                    for sx in 0..SAMPLES {
                        let x = (px as f32 + (sx as f32 + 0.5) / SAMPLES as f32) / SCALE;
                        let y = (py as f32 + (sy as f32 + 0.5) / SAMPLES as f32) / SCALE;
                        if inside(x, y) {
                            hits += 1;
                        }
                    }
                }
                if hits == 0 {
                    continue;
                }
                let a = hits as f32 / (SAMPLES * SAMPLES) as f32 * opacity;
                let dst = &mut self.pixels[py * SIZE + px];
                let out_a = a + dst[3] * (1.0 - a);
                for i in 0..3 {
                    let src = colour[i] as f32 / 255.0;
                    dst[i] = (src * a + dst[i] * dst[3] * (1.0 - a)) / out_a;
                }
                dst[3] = out_a;
            }
        }
    }

    fn png(&self) -> Vec<u8> {
        let data: Vec<u8> = self
            .pixels
            .iter()
            .flat_map(|p| p.map(|c| (c.clamp(0.0, 1.0) * 255.0).round() as u8))
            .collect();
        let mut out = Vec::new();
        let mut encoder = png::Encoder::new(&mut out, SIZE as u32, SIZE as u32);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        encoder
            .write_header()
            .and_then(|mut w| w.write_image_data(&data))
            .expect("encoding to memory cannot fail");
        out
    }
}

// MARK: - Geometry, in 16-unit coordinates centred on (8, 8)

const C: f32 = 8.0;

fn radius(x: f32, y: f32) -> f32 {
    ((x - C).powi(2) + (y - C).powi(2)).sqrt()
}

/// Clockwise from twelve o'clock, 0...1.
fn turn(x: f32, y: f32) -> f32 {
    let a = (x - C).atan2(C - y) / std::f32::consts::TAU;
    if a < 0.0 { a + 1.0 } else { a }
}

fn polygon(points: &[(f32, f32)], x: f32, y: f32) -> bool {
    let mut inside = false;
    let mut j = points.len() - 1;
    for i in 0..points.len() {
        let ((xi, yi), (xj, yj)) = (points[i], points[j]);
        if (yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi {
            inside = !inside;
        }
        j = i;
    }
    inside
}

fn segment_distance(x: f32, y: f32, (ax, ay): (f32, f32), (bx, by): (f32, f32)) -> f32 {
    let (dx, dy) = (bx - ax, by - ay);
    let t = (((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy)).clamp(0.0, 1.0);
    ((x - ax - t * dx).powi(2) + (y - ay - t * dy).powi(2)).sqrt()
}

fn shape(severity: Severity) -> Vec<(f32, f32)> {
    match severity {
        // A 32-gon reads as a circle at this size and keeps one code path.
        Severity::Normal => (0..32)
            .map(|i| {
                let a = i as f32 / 32.0 * std::f32::consts::TAU;
                (C + 6.0 * a.cos(), C + 6.0 * a.sin())
            })
            .collect(),
        Severity::Caution => vec![(2.5, 2.5), (13.5, 2.5), (13.5, 13.5), (2.5, 13.5)],
        Severity::Warning => vec![(8.0, 1.5), (15.0, 14.0), (1.0, 14.0)],
        Severity::Critical => vec![
            (5.3, 1.5),
            (10.7, 1.5),
            (14.5, 5.3),
            (14.5, 10.7),
            (10.7, 14.5),
            (5.3, 14.5),
            (1.5, 10.7),
            (1.5, 5.3),
        ],
    }
}

/// The shape minus itself shrunk about its centroid: an outline of even-ish width.
fn outline(points: &[(f32, f32)], width: f32) -> impl Fn(f32, f32) -> bool + '_ {
    let n = points.len() as f32;
    let (gx, gy) = points
        .iter()
        .fold((0.0, 0.0), |(sx, sy), (x, y)| (sx + x / n, sy + y / n));
    let extent = points
        .iter()
        .map(|(x, y)| ((x - gx).powi(2) + (y - gy).powi(2)).sqrt())
        .fold(0.0f32, f32::max);
    let k = 1.0 - 1.6 * width / extent;
    move |x, y| polygon(points, x, y) && !polygon(points, gx + (x - gx) / k, gy + (y - gy) / k)
}

pub fn render(icon: &RowIcon) -> Vec<u8> {
    let mut canvas = Canvas::new();
    match *icon {
        RowIcon::Gauge {
            used,
            elapsed,
            severity,
        } => {
            ring(&mut canvas, used, severity);
            if let Some(elapsed) = elapsed {
                // The pace tick crosses the band and barely clears it — any
                // further and the ring reads as a "Q". Red once the fill has
                // passed it, as the panel's marker turns filled.
                let over = used / 100.0 > elapsed;
                let a = elapsed.clamp(0.0, 1.0) as f32 * std::f32::consts::TAU;
                let (s, c) = a.sin_cos();
                let (inner, outer) = ((C + 3.4 * s, C - 3.4 * c), (C + 7.5 * s, C - 7.5 * c));
                let colour = if over { RED } else { TICK };
                canvas.fill(colour, 1.0, |x, y| {
                    segment_distance(x, y, inner, outer) <= 0.65
                });
            }
        }
        RowIcon::Fill { used, severity } => ring(&mut canvas, used, severity),
        RowIcon::Mark(severity) => {
            let points = shape(severity);
            canvas.fill(severity_colour(severity), 1.0, |x, y| {
                polygon(&points, x, y)
            });
        }
        RowIcon::Stale => {
            canvas.fill(GREY, 1.0, |x, y| (radius(x, y) - 5.8).abs() <= 0.8);
            canvas.fill(GREY, 1.0, |x, y| {
                segment_distance(x, y, (C, C), (C, 4.4)) <= 0.75
                    || segment_distance(x, y, (C, C), (10.4, 9.4)) <= 0.75
            });
        }
        RowIcon::Error => {
            let points = shape(Severity::Critical);
            canvas.fill(GREY, 1.0, outline(&points, 1.4));
            canvas.fill(GREY, 1.0, |x, y| {
                segment_distance(x, y, (5.6, 5.6), (10.4, 10.4)) <= 0.8
                    || segment_distance(x, y, (10.4, 5.6), (5.6, 10.4)) <= 0.8
            });
        }
        RowIcon::Unconfigured => {
            canvas.fill(GREY, 1.0, |x, y| {
                (radius(x, y) - 5.8).abs() <= 0.8 && (turn(x, y) * 12.0).fract() < 0.55
            });
        }
    }
    canvas.png()
}

/// A full track in grey and the used share in the severity hue, clockwise from
/// twelve, as the panel's bar fills from the left.
fn ring(canvas: &mut Canvas, used: f64, severity: Severity) {
    let fraction = (used / 100.0).clamp(0.0, 1.0) as f32;
    let band = |x: f32, y: f32| (4.2..=7.0).contains(&radius(x, y));
    canvas.fill(GREY, 0.4, band);
    canvas.fill(severity_colour(severity), 1.0, |x, y| {
        band(x, y) && turn(x, y) <= fraction
    });
}

/// `--icon <dir>` writes these next to the tray artwork.
pub fn samples() -> Vec<(&'static str, RowIcon)> {
    vec![
        (
            "menu-gauge-normal",
            RowIcon::Gauge {
                used: 14.0,
                elapsed: Some(0.3),
                severity: Severity::Normal,
            },
        ),
        (
            "menu-gauge-caution",
            RowIcon::Gauge {
                used: 70.0,
                elapsed: Some(0.72),
                severity: Severity::Caution,
            },
        ),
        (
            "menu-gauge-warning",
            RowIcon::Gauge {
                used: 87.0,
                elapsed: Some(0.89),
                severity: Severity::Warning,
            },
        ),
        (
            "menu-gauge-overpace",
            RowIcon::Gauge {
                used: 56.0,
                elapsed: Some(0.29),
                severity: Severity::Critical,
            },
        ),
        (
            "menu-fill",
            RowIcon::Fill {
                used: 53.0,
                severity: Severity::Normal,
            },
        ),
        ("menu-mark-normal", RowIcon::Mark(Severity::Normal)),
        ("menu-mark-caution", RowIcon::Mark(Severity::Caution)),
        ("menu-mark-warning", RowIcon::Mark(Severity::Warning)),
        ("menu-mark-critical", RowIcon::Mark(Severity::Critical)),
        ("menu-stale", RowIcon::Stale),
        ("menu-error", RowIcon::Error),
        ("menu-unconfigured", RowIcon::Unconfigured),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decode(png_bytes: &[u8]) -> Vec<u8> {
        let decoder = png::Decoder::new(std::io::Cursor::new(png_bytes));
        let mut reader = decoder.read_info().unwrap();
        let mut buf = vec![0; reader.output_buffer_size().unwrap()];
        let info = reader.next_frame(&mut buf).unwrap();
        assert_eq!((info.width, info.height), (SIZE as u32, SIZE as u32));
        buf
    }

    fn opaque_pixels_of(rgba: &[u8], colour: [u8; 3]) -> usize {
        rgba.chunks(4)
            .filter(|p| p[3] > 200 && p[..3] == colour)
            .count()
    }

    #[test]
    fn every_icon_encodes_as_a_square_png() {
        for (_, icon) in samples() {
            let rgba = decode(&render(&icon));
            assert!(rgba.chunks(4).any(|p| p[3] > 0));
        }
    }

    #[test]
    fn the_ring_fills_in_the_severity_hue_in_proportion() {
        let low = decode(&render(&RowIcon::Fill {
            used: 20.0,
            severity: Severity::Normal,
        }));
        let high = decode(&render(&RowIcon::Fill {
            used: 80.0,
            severity: Severity::Normal,
        }));
        assert!(opaque_pixels_of(&high, BLUE) > 3 * opaque_pixels_of(&low, BLUE));
        let warning = decode(&render(&RowIcon::Fill {
            used: 85.0,
            severity: Severity::Warning,
        }));
        assert!(opaque_pixels_of(&warning, ORANGE) > 0);
        assert_eq!(opaque_pixels_of(&warning, BLUE), 0);
    }

    #[test]
    fn the_pace_tick_turns_red_only_when_the_fill_has_passed_it() {
        let behind = decode(&render(&RowIcon::Gauge {
            used: 10.0,
            elapsed: Some(0.5),
            severity: Severity::Normal,
        }));
        let ahead = decode(&render(&RowIcon::Gauge {
            used: 60.0,
            elapsed: Some(0.3),
            severity: Severity::Critical,
        }));
        assert_eq!(opaque_pixels_of(&behind, RED), 0);
        assert!(opaque_pixels_of(&ahead, RED) > 0);
    }

    #[test]
    fn status_icons_carry_no_severity_hue() {
        for icon in [RowIcon::Stale, RowIcon::Error, RowIcon::Unconfigured] {
            let rgba = decode(&render(&icon));
            for colour in [BLUE, YELLOW, ORANGE, RED] {
                assert_eq!(opaque_pixels_of(&rgba, colour), 0, "{icon:?}");
            }
        }
    }
}
