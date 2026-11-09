//! The panel's glyphs, drawn inline so the binary needs no asset directory.
//!
//! They stand in for the SF Symbols the macOS panel uses and keep the same rule:
//! shape, not hue, carries severity — round / square / triangular / octagonal,
//! filled when the figure is current and outlined when it is not
//! (docs/design.md §6–7). gpui renders an SVG as a mask in the element's text
//! colour, so every path here is single-colour; cut-outs use even-odd fills.

use std::borrow::Cow;

use gpui::{AssetSource, SharedString};

const EXCL_SQUARE: &str = "M7.1 4.2h1.8v5H7.1z M7.1 10.4h1.8v1.8H7.1z";
const EXCL_TRIANGLE: &str = "M7.1 6h1.8v4.2H7.1z M7.1 11.1h1.8v1.7H7.1z";
const OCTAGON: &str = "M5.2 1.2h5.6l4 4v5.6l-4 4H5.2l-4-4V5.2z";

fn svg(body: &str) -> String {
    format!(r#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">{body}</svg>"#)
}

fn filled(outline: &str, cutout: &str) -> String {
    svg(&format!(
        r#"<path fill-rule="evenodd" d="{outline} {cutout}"/>"#
    ))
}

fn stroked(outline: &str, inner: &str) -> String {
    svg(&format!(
        r#"<path d="{outline}" fill="none" stroke="black" stroke-width="1.4" stroke-linejoin="round"/>{inner}"#
    ))
}

pub fn icon(name: &str) -> Option<String> {
    let square = "M3 1.5h10A1.5 1.5 0 0 1 14.5 3v10a1.5 1.5 0 0 1-1.5 1.5H3A1.5 1.5 0 0 1 1.5 13V3A1.5 1.5 0 0 1 3 1.5z";
    let triangle = "M8 1.3c.4 0 .7.2.9.5l6.3 11.4c.4.7-.1 1.5-.9 1.5H1.7c-.8 0-1.3-.8-.9-1.5L7.1 1.8c.2-.3.5-.5.9-.5z";
    let circle = "M8 1.5a6.5 6.5 0 1 1 0 13a6.5 6.5 0 1 1 0-13z";
    let excl_fill = |d: &str| format!(r#"<path d="{d}"/>"#);
    Some(match name {
        "circle.fill" => svg(r#"<circle cx="8" cy="8" r="6"/>"#),
        "exclamationmark.square.fill" => filled(square, EXCL_SQUARE),
        "exclamationmark.triangle.fill" => filled(triangle, EXCL_TRIANGLE),
        "exclamationmark.octagon.fill" => filled(OCTAGON, EXCL_SQUARE),
        "circle" => {
            svg(r#"<circle cx="8" cy="8" r="5.5" fill="none" stroke="black" stroke-width="1.4"/>"#)
        }
        "exclamationmark.square" => stroked(square, &excl_fill(EXCL_SQUARE)),
        "exclamationmark.triangle" => stroked(triangle, &excl_fill(EXCL_TRIANGLE)),
        "exclamationmark.octagon" => stroked(OCTAGON, &excl_fill(EXCL_SQUARE)),
        "clock" => stroked(
            circle,
            r#"<path d="M8 4.3V8l2.6 1.6" fill="none" stroke="black" stroke-width="1.4" stroke-linecap="round"/>"#,
        ),
        "xmark.octagon" => stroked(
            OCTAGON,
            r#"<path d="M5.6 5.6l4.8 4.8M10.4 5.6l-4.8 4.8" stroke="black" stroke-width="1.4" stroke-linecap="round"/>"#,
        ),
        "circle.dashed" => svg(
            r#"<circle cx="8" cy="8" r="5.6" fill="none" stroke="black" stroke-width="1.4" stroke-dasharray="2.2 1.8"/>"#,
        ),
        "arrowtriangle.down.fill" => svg(r#"<path d="M2 3.5h12L8 13.5z"/>"#),
        "arrowtriangle.down" => svg(
            r#"<path d="M2.8 4h10.4L8 12.4z" fill="none" stroke="black" stroke-width="1.5" stroke-linejoin="round"/>"#,
        ),
        "xmark" => svg(
            r#"<path d="M4 4l8 8M12 4l-8 8" stroke="black" stroke-width="1.6" stroke-linecap="round"/>"#,
        ),
        "chevron.down" => svg(
            r#"<path d="M3.5 6l4.5 4.5L12.5 6" fill="none" stroke="black" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>"#,
        ),
        "chevron.up" => svg(
            r#"<path d="M3.5 10.5L8 6l4.5 4.5" fill="none" stroke="black" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>"#,
        ),
        "questionmark.circle" => stroked(
            circle,
            r#"<path d="M6.2 6.3a1.9 1.9 0 1 1 2.6 1.8c-.5.2-.8.6-.8 1.1v.5" fill="none" stroke="black" stroke-width="1.4" stroke-linecap="round"/><circle cx="8" cy="11.6" r=".9"/>"#,
        ),
        "arrow.clockwise" => svg(
            r#"<path d="M12.6 8.6A4.7 4.7 0 1 1 11 4.6" fill="none" stroke="black" stroke-width="1.5" stroke-linecap="round"/><path d="M9.6 2.4l3.2.2-.4 3.3z"/>"#,
        ),
        _ => return None,
    })
}

pub struct Assets;

impl AssetSource for Assets {
    fn load(&self, path: &str) -> anyhow::Result<Option<Cow<'static, [u8]>>> {
        let name = path
            .strip_prefix("icons/")
            .and_then(|p| p.strip_suffix(".svg"));
        Ok(name.and_then(icon).map(|s| Cow::Owned(s.into_bytes())))
    }

    fn list(&self, _path: &str) -> anyhow::Result<Vec<SharedString>> {
        Ok(Vec::new())
    }
}

pub fn path(name: &str) -> SharedString {
    format!("icons/{name}.svg").into()
}
