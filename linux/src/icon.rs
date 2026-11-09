//! The tray artwork. Port of `Sources/LLMUsage/MenuBarIcon.swift` — the same
//! A+B hybrid (docs/design.md §2): one mini gauge per source normally, the
//! hottest figure once the projection crosses the warning threshold.
//!
//! Two differences from macOS, both forced by StatusNotifierItem hosts. They
//! show a square icon, so the artwork is laid out in a square rather than at
//! the text's natural width. And there is no template rendering, so the image
//! is drawn in one foreground colour: light by default, since the GNOME and KDE
//! panels are dark; `LLM_USAGE_TRAY_THEME=dark` draws it dark for a light panel.

use jiff::Timestamp;

use crate::model::UsageSource;

/// What the tray should show. Derived from the store; cheap to compare.
#[derive(Clone, Debug, PartialEq)]
pub enum TrayArt {
    /// Each entry is a source's worst consumption, or `None` without current data.
    Bars(Vec<Option<f64>>),
    Figure(f64),
}

impl TrayArt {
    pub fn from_sources(
        sources: &[UsageSource],
        worst: Option<f64>,
        shows_worst_figure: bool,
        now: Timestamp,
    ) -> Self {
        match (shows_worst_figure, worst) {
            (true, Some(used)) => TrayArt::Figure(used),
            _ => TrayArt::Bars(
                sources
                    .iter()
                    .map(|s| {
                        s.has_current_data(now)
                            .then(|| s.worst_window().map_or(0.0, |w| w.used_percent))
                    })
                    .collect(),
            ),
        }
    }
}

/// Coverage mask, 0...1 per pixel.
struct Mask {
    size: usize,
    alpha: Vec<f32>,
}

impl Mask {
    fn new(size: usize) -> Self {
        Self {
            size,
            alpha: vec![0.0; size * size],
        }
    }

    /// A rounded rectangle in pixel coordinates (origin top-left), 4×4
    /// supersampled, composited at `opacity` over what is already there.
    fn rounded_rect(&mut self, x: f32, y: f32, w: f32, h: f32, radius: f32, opacity: f32) {
        let r = radius.min(w / 2.0).min(h / 2.0);
        let (x0, y0) = (x.floor().max(0.0) as usize, y.floor().max(0.0) as usize);
        let x1 = ((x + w).ceil() as usize).min(self.size);
        let y1 = ((y + h).ceil() as usize).min(self.size);
        for py in y0..y1 {
            for px in x0..x1 {
                let mut hits = 0;
                for sy in 0..4 {
                    for sx in 0..4 {
                        let fx = px as f32 + (sx as f32 + 0.5) / 4.0;
                        let fy = py as f32 + (sy as f32 + 0.5) / 4.0;
                        if inside_rounded(fx, fy, x, y, w, h, r) {
                            hits += 1;
                        }
                    }
                }
                let coverage = hits as f32 / 16.0 * opacity;
                let a = &mut self.alpha[py * self.size + px];
                *a = coverage + *a * (1.0 - coverage);
            }
        }
    }
}

fn inside_rounded(fx: f32, fy: f32, x: f32, y: f32, w: f32, h: f32, r: f32) -> bool {
    if fx < x || fy < y || fx > x + w || fy > y + h {
        return false;
    }
    let cx = fx.clamp(x + r, x + w - r);
    let cy = fy.clamp(y + r, y + h - r);
    (fx - cx).powi(2) + (fy - cy).powi(2) <= r * r
}

/// A 3×5 pixel font: digits and the percent sign. Each row is three bits, MSB left.
fn glyph(c: char) -> [u8; 5] {
    match c {
        '0' => [0b111, 0b101, 0b101, 0b101, 0b111],
        '1' => [0b010, 0b110, 0b010, 0b010, 0b111],
        '2' => [0b111, 0b001, 0b111, 0b100, 0b111],
        '3' => [0b111, 0b001, 0b011, 0b001, 0b111],
        '4' => [0b101, 0b101, 0b111, 0b001, 0b001],
        '5' => [0b111, 0b100, 0b111, 0b001, 0b111],
        '6' => [0b111, 0b100, 0b111, 0b101, 0b111],
        '7' => [0b111, 0b001, 0b010, 0b010, 0b010],
        '8' => [0b111, 0b101, 0b111, 0b101, 0b111],
        '9' => [0b111, 0b101, 0b111, 0b001, 0b111],
        '%' => [0b101, 0b001, 0b010, 0b100, 0b101],
        _ => [0; 5],
    }
}

fn render(art: &TrayArt, size: usize) -> Mask {
    let mut mask = Mask::new(size);
    // Design units: a 16-unit square, as the macOS item is 16pt tall.
    let u = size as f32 / 16.0;
    match art {
        TrayArt::Bars(bars) => {
            let count = bars.len().max(1) as f32;
            let (bar, gap, height, baseline) = (3.0, 2.0, 12.0, 2.0);
            let total = count * bar + (count - 1.0) * gap;
            let left = (16.0 - total) / 2.0;
            for (i, used) in bars.iter().enumerate() {
                let x = (left + i as f32 * (bar + gap)) * u;
                let bottom = (16.0 - baseline) * u;
                // The track first: a source at 0% still has to read as present.
                mask.rounded_rect(
                    x,
                    bottom - height * u,
                    bar * u,
                    height * u,
                    bar * u / 2.0,
                    0.3,
                );
                if let Some(used) = used {
                    let fill = (height * (used / 100.0).clamp(0.0, 1.0) as f32).max(1.5) * u;
                    mask.rounded_rect(x, bottom - fill, bar * u, fill, bar * u / 2.0, 1.0);
                }
            }
        }
        TrayArt::Figure(used) => {
            let value = used.round() as i64;
            // "100%" does not fit a square at tray sizes; at the ceiling the
            // number alone says it.
            let text = if value >= 100 {
                "100".to_string()
            } else {
                format!("{}%", value.max(0))
            };
            let cells = text.chars().count() * 4 - 1;
            let cell = ((size as f32 / cells as f32).floor() as usize).max(1);
            let text_w = cells * cell;
            let text_h = 5 * cell;
            let gauge_h = (2.0 * u).max(2.0);
            let gauge_gap = (1.5 * u).max(1.0);
            let block = text_h as f32 + gauge_gap + gauge_h;
            let top = ((size as f32 - block) / 2.0).floor();
            let left = ((size - text_w) / 2) as f32;
            for (i, c) in text.chars().enumerate() {
                for (row, bits) in glyph(c).iter().enumerate() {
                    for col in 0..3 {
                        if bits & (0b100 >> col) != 0 {
                            let x = left + ((i * 4 + col) * cell) as f32;
                            let y = top + (row * cell) as f32;
                            mask.rounded_rect(x, y, cell as f32, cell as f32, 0.0, 1.0);
                        }
                    }
                }
            }
            // Under the number, how full the hottest window is.
            let gy = top + text_h as f32 + gauge_gap;
            let gw = text_w as f32;
            mask.rounded_rect(left, gy, gw, gauge_h, gauge_h / 2.0, 0.3);
            let fill = gw * (used / 100.0).clamp(0.0, 1.0) as f32;
            if fill > 0.0 {
                mask.rounded_rect(left, gy, fill.max(gauge_h), gauge_h, gauge_h / 2.0, 1.0);
            }
        }
    }
    mask
}

pub fn foreground() -> [u8; 3] {
    match std::env::var("LLM_USAGE_TRAY_THEME").as_deref() {
        Ok("dark") => [0x1e, 0x1e, 0x1e],
        _ => [0xf2, 0xf2, 0xf2],
    }
}

/// ARGB32 in network byte order, as StatusNotifierItem's `IconPixmap` wants.
pub fn argb(art: &TrayArt, size: usize, color: [u8; 3]) -> Vec<u8> {
    let mask = render(art, size);
    mask.alpha
        .iter()
        .flat_map(|a| [(a * 255.0).round() as u8, color[0], color[1], color[2]])
        .collect()
}

/// `--icon <dir>`: the tray artwork as PNGs, over a panel-coloured background,
/// so it can be inspected without hunting for it in the panel.
pub fn dump(directory: &str) -> std::io::Result<()> {
    let demo = TrayArt::Bars(vec![Some(62.0), Some(55.0), Some(13.0)]);
    let cases = [
        ("tray-bars", demo),
        ("tray-bars-empty", TrayArt::Bars(vec![None, None, None])),
        ("tray-figure", TrayArt::Figure(82.0)),
        ("tray-figure-full", TrayArt::Figure(100.0)),
    ];
    let color = foreground();
    let background = if color[0] > 0x80 {
        [0x24, 0x24, 0x24]
    } else {
        [0xf0, 0xf0, 0xf0]
    };
    for (name, art) in cases {
        for size in [22usize, 64] {
            let mask = render(&art, size);
            let rgb: Vec<u8> = mask
                .alpha
                .iter()
                .flat_map(|a| {
                    (0..3).map(move |i| {
                        (color[i] as f32 * a + background[i] as f32 * (1.0 - a)).round() as u8
                    })
                })
                .collect();
            let path = format!("{directory}/{name}-{size}.png");
            let file = std::io::BufWriter::new(std::fs::File::create(&path)?);
            let mut encoder = png::Encoder::new(file, size as u32, size as u32);
            encoder.set_color(png::ColorType::Rgb);
            encoder.set_depth(png::BitDepth::Eight);
            encoder.write_header()?.write_image_data(&rgb)?;
            println!("{path}  {size}x{size}px");
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn coverage(art: &TrayArt, size: usize) -> f32 {
        render(art, size).alpha.iter().sum()
    }

    #[test]
    fn fuller_bars_cover_more_and_empty_sources_keep_their_track() {
        let empty = coverage(&TrayArt::Bars(vec![None, None, None]), 22);
        let low = coverage(&TrayArt::Bars(vec![Some(10.0), Some(10.0), Some(10.0)]), 22);
        let high = coverage(&TrayArt::Bars(vec![Some(90.0), Some(90.0), Some(90.0)]), 22);
        assert!(empty > 0.0);
        assert!(empty < low && low < high);
    }

    #[test]
    fn pixmap_is_argb_and_square() {
        let data = argb(&TrayArt::Figure(82.0), 22, [1, 2, 3]);
        assert_eq!(data.len(), 22 * 22 * 4);
        assert!(data.chunks(4).all(|p| p[1..] == [1, 2, 3]));
        assert!(data.chunks(4).any(|p| p[0] == 255));
    }

    #[test]
    fn art_switches_to_the_figure_only_with_a_worst_window() {
        let now = Timestamp::now();
        assert_eq!(
            TrayArt::from_sources(&[], Some(82.0), true, now),
            TrayArt::Figure(82.0)
        );
        assert_eq!(
            TrayArt::from_sources(&[], None, true, now),
            TrayArt::Bars(vec![])
        );
        let placeholder = UsageSource::placeholder("codex", "Codex");
        assert_eq!(
            TrayArt::from_sources(&[placeholder], Some(10.0), false, now),
            TrayArt::Bars(vec![None])
        );
    }
}
