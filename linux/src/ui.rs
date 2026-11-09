//! The panel. Port of `Sources/LLMUsage/Views.swift`; the layout constants and
//! the reasoning behind each element are in docs/design.md §3–§9.

use std::collections::HashSet;

use gpui::{
    AnyElement, App, Context, Entity, FocusHandle, Font, FontWeight, Hsla, IntoElement,
    MouseButton, ParentElement, Render, SharedString, Styled, Subscription, TextRun, Window,
    WindowAppearance, actions, canvas, div, prelude::*, px, relative, rgb, rgba, size, svg,
};
use jiff::Timestamp;

use crate::assets;
use crate::ipc::FromPanel;
use crate::model::{Severity, SourceState, UsageSource, UsageSpend, UsageWindow, format};
use crate::panel::PanelModel;

actions!(llm_usage, [RefreshAll, ClosePanel, QuitApp]);

// MARK: - Layout (docs/design.md §9)

const PANEL_WIDTH: f32 = 320.0;
const PADDING: f32 = 12.0;
const ROW_SPACING: f32 = 6.0;
const SECTION_SPACING: f32 = 14.0;
const GAUGE_PRIMARY: f32 = 6.0;
const GAUGE_SECONDARY: f32 = 4.0;
/// Everything except the gauge is fixed; the gauge absorbs the remainder.
const LABEL_COLUMN: f32 = 76.0;
const PERCENT_COLUMN: f32 = 44.0;
const RESET_COLUMN: f32 = 60.0;
const ROW_MIN_HEIGHT: f32 = 22.0;
/// Long labels ("Claude/GPT 7d") shrink to fit rather than truncate, down to this.
const MINIMUM_SCALE: f32 = 0.7;
/// WCAG 2.5.8.
const HIT_TARGET: f32 = 24.0;
/// The pace marker's box; the glyph centres in it so the marker stays on the
/// elapsed position.
const PACE_MARKER: f32 = 9.0;
const LEGEND_SYMBOL_COLUMN: f32 = 52.0;
const TITLE_BAR: f32 = 30.0;

// Type sizes. The macOS text styles, a step larger for typical Linux DPI.
const BODY: f32 = 13.0;
const SUBHEADLINE: f32 = 12.0;
const CAPTION: f32 = 11.0;
const FOOTNOTE: f32 = 11.0;

// MARK: - Theme

#[derive(Clone, Copy)]
pub struct Theme {
    bg: Hsla,
    text: Hsla,
    secondary: Hsla,
    track: Hsla,
    divider: Hsla,
    border: Hsla,
    button: Hsla,
    button_hover: Hsla,
    accent: Hsla,
    yellow: Hsla,
    orange: Hsla,
    red: Hsla,
}

impl Theme {
    fn for_window(window: &Window) -> Theme {
        match window.appearance() {
            WindowAppearance::Dark | WindowAppearance::VibrantDark => Theme {
                bg: rgb(0x252527).into(),
                text: rgb(0xf2f2f7).into(),
                secondary: rgb(0xa1a1a8).into(),
                track: rgba(0xffffff26).into(),
                divider: rgba(0xffffff1f).into(),
                border: rgba(0xffffff2e).into(),
                button: rgba(0xffffff1a).into(),
                button_hover: rgba(0xffffff2b).into(),
                accent: rgb(0x0a84ff).into(),
                yellow: rgb(0xffd60a).into(),
                orange: rgb(0xff9f0a).into(),
                red: rgb(0xff453a).into(),
            },
            WindowAppearance::Light | WindowAppearance::VibrantLight => Theme {
                bg: rgb(0xf7f7f8).into(),
                text: rgb(0x1d1d1f).into(),
                secondary: rgb(0x5f5f66).into(),
                track: rgba(0x0000001f).into(),
                divider: rgba(0x0000001f).into(),
                border: rgba(0x00000033).into(),
                button: rgba(0x0000000f).into(),
                button_hover: rgba(0x0000001f).into(),
                accent: rgb(0x007aff).into(),
                yellow: rgb(0xe6b800).into(),
                orange: rgb(0xff9500).into(),
                red: rgb(0xd70015).into(),
            },
        }
    }

    fn severity(&self, severity: Severity) -> Hsla {
        match severity {
            Severity::Normal => self.accent,
            Severity::Caution => self.yellow,
            Severity::Warning => self.orange,
            Severity::Critical => self.red,
        }
    }
}

/// Shape, not hue, has to survive greyscale and colour blindness: round /
/// square / triangular / octagonal.
fn symbol(severity: Severity) -> &'static str {
    match severity {
        Severity::Normal => "circle.fill",
        Severity::Caution => "exclamationmark.square.fill",
        Severity::Warning => "exclamationmark.triangle.fill",
        Severity::Critical => "exclamationmark.octagon.fill",
    }
}

/// The same silhouettes unfilled, for a figure that is no longer current.
fn last_known_symbol(severity: Severity) -> &'static str {
    match severity {
        Severity::Normal => "circle",
        Severity::Caution => "exclamationmark.square",
        Severity::Warning => "exclamationmark.triangle",
        Severity::Critical => "exclamationmark.octagon",
    }
}

fn icon(name: &str, size_px: f32, color: Hsla) -> impl IntoElement {
    svg()
        .path(assets::path(name))
        .size(px(size_px))
        .flex_none()
        .text_color(color)
}

// MARK: - Panel

pub struct Panel {
    model: Entity<PanelModel>,
    focus: FocusHandle,
    legend_expanded: bool,
    expanded_buckets: HashSet<String>,
    was_active: bool,
    _subscriptions: [Subscription; 2],
}

impl Panel {
    pub fn new(model: Entity<PanelModel>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let observer = cx.observe(&model, |_, _, cx| cx.notify());
        // A popover, as the macOS panel is: it goes away when you click
        // elsewhere. Only after it has been active once — a compositor that
        // declines to focus a new window must not make it vanish unseen.
        let activation = cx.observe_window_activation(window, |this: &mut Panel, window, _| {
            if window.is_window_active() {
                this.was_active = true;
            } else if this.was_active {
                window.remove_window();
            }
        });
        let focus = cx.focus_handle();
        focus.focus(window);
        Self {
            model,
            focus,
            legend_expanded: false,
            expanded_buckets: HashSet::new(),
            was_active: false,
            _subscriptions: [observer, activation],
        }
    }

    fn send(&self, command: FromPanel, cx: &mut App) {
        self.model
            .update(cx, |model, cx| model.command(command, cx));
    }

    /// A tray click while open. Once the panel has had focus, the click is
    /// what took it away, so the answer is to close; a panel the compositor
    /// never focused is brought forward instead.
    pub fn toggle(&mut self, window: &mut Window) {
        if self.was_active {
            window.remove_window();
        } else {
            window.activate_window();
        }
    }
}

/// The desktop's UI font. gpui resolves its own system-font alias to IBM Plex
/// Sans on Linux, and where that is not installed the fallback face it lands
/// on has no bold, so every weight in the panel rendered regular.
static UI_FONT: std::sync::OnceLock<Option<SharedString>> = std::sync::OnceLock::new();

/// GNOME's interface font when there is one, else fontconfig's Latin
/// sans-serif — and only a family gpui can actually load.
pub fn init_ui_font(installed: &[String]) {
    let run = |program: &str, args: &[&str]| {
        crate::cli::run(
            program,
            args,
            None,
            std::time::Duration::from_secs(2),
            &[0],
            &|| false,
        )
        .ok()
    };
    let gnome = run(
        "gsettings",
        &["get", "org.gnome.desktop.interface", "font-name"],
    )
    .map(|value| {
        // "'Ubuntu Sans 11'" -> "Ubuntu Sans"
        let name = value.trim().trim_matches('\'');
        name.rsplit_once(' ')
            .filter(|(_, size)| size.parse::<f32>().is_ok())
            .map_or(name, |(family, _)| family)
            .to_string()
    });
    let fontconfig = run("fc-match", &["-f", "%{family[0]}", "sans-serif:lang=en"]);
    // gpui does not instance variable fonts by weight, so a family whose bold
    // exists only as a named instance (fontconfig index ≥ 0x10000) would draw
    // every weight regular — Ubuntu's own Ubuntu Sans is one.
    let has_static_bold = |family: &str| {
        run(
            "fc-list",
            &["-f", "%{index}\n", &format!("{family}:weight=200")],
        )
        .is_some_and(|out| {
            out.lines()
                .any(|index| index.trim().parse::<u32>().is_ok_and(|i| i < 0x10000))
        })
    };
    let family = [gnome, fontconfig]
        .into_iter()
        .flatten()
        .map(|f| f.trim().to_string())
        .find(|f| installed.iter().any(|name| name == f) && has_static_bold(f));
    let _ = UI_FONT.set(family.map(SharedString::from));
}

fn ui_font() -> Option<SharedString> {
    UI_FONT.get().cloned().flatten()
}

/// Text that shrinks rather than truncates, the way SwiftUI's
/// `minimumScaleFactor` does, and ellipsises only below the minimum.
fn fitted(
    text: impl Into<SharedString>,
    width: f32,
    base: f32,
    weight: FontWeight,
    window: &Window,
) -> impl IntoElement {
    let text: SharedString = text.into();
    let mut font: Font = window.text_style().font();
    if let Some(family) = ui_font() {
        font.family = family;
    }
    font.weight = weight;
    let run = TextRun {
        len: text.len(),
        font,
        color: Hsla::default(),
        background_color: None,
        underline: None,
        strikethrough: None,
    };
    let measured: f32 = window
        .text_system()
        .layout_line(&text, px(base), &[run], None)
        .width
        .into();
    let scale = if measured > width {
        (width / measured).max(MINIMUM_SCALE)
    } else {
        1.0
    };
    div()
        .w(px(width))
        .flex_none()
        .overflow_hidden()
        .whitespace_nowrap()
        .text_ellipsis()
        .text_size(px(base * scale))
        .font_weight(weight)
        .child(text)
}

impl Render for Panel {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = Theme::for_window(window);
        let now = Timestamp::now();
        let store = &self.model.read(cx).store;
        let summary = store.summary(now);
        let last_refreshed = format::relative(store.last_refreshed, now);
        let sources = store.sources.clone();

        let mut content = div()
            .relative()
            .flex_none()
            .w(px(PANEL_WIDTH))
            .p(px(PADDING))
            .flex()
            .flex_col()
            .gap(px(SECTION_SPACING));

        // The conclusion, stated once, before any of the detail below it. It
        // shrinks to fit rather than lose its end, which is the date.
        let summary_width =
            PANEL_WIDTH - 2.0 * PADDING - if summary.is_warning { 14.0 + 5.0 } else { 0.0 };
        content = content.child(
            div()
                .flex()
                .items_center()
                .gap(px(5.0))
                .when(summary.is_warning, |d| {
                    d.child(icon(
                        symbol(summary.severity),
                        14.0,
                        t.severity(summary.severity),
                    ))
                })
                .child(fitted(
                    summary.text.clone(),
                    summary_width,
                    BODY,
                    FontWeight::SEMIBOLD,
                    window,
                )),
        );

        for (index, source) in sources.iter().enumerate() {
            if index > 0 {
                content = content.child(divider(t));
            }
            content = content.child(self.card(source, now, t, window, cx));
        }
        content = content.child(divider(t));
        if self.legend_expanded {
            content = content.child(legend(t));
        }
        content = content.child(self.footer(&last_refreshed, t, cx));

        // Size the window to the content: the panel has no scroll position to
        // keep, and a fixed height either clipped a card or left a blank band.
        content = content.child(
            canvas(
                |bounds, window, _| {
                    let want = size(
                        px(PANEL_WIDTH + 2.0),
                        bounds.size.height + px(TITLE_BAR + 2.0),
                    );
                    let have = window.viewport_size();
                    let dh: f32 = (have.height - want.height).into();
                    let dw: f32 = (have.width - want.width).into();
                    if dh.abs() > 0.5 || dw.abs() > 0.5 {
                        window.on_next_frame(move |window, _| window.resize(want));
                    }
                },
                |_, _, _, _| {},
            )
            .absolute()
            .top_0()
            .left_0()
            .size_full(),
        );

        div()
            .id("panel")
            .key_context("Panel")
            .track_focus(&self.focus)
            .on_action(cx.listener(|this, _: &RefreshAll, _, cx| this.send(FromPanel::Refresh, cx)))
            .on_action(cx.listener(|_, _: &ClosePanel, window, _| window.remove_window()))
            .on_action(cx.listener(|this, _: &QuitApp, _, cx| this.send(FromPanel::Quit, cx)))
            .size_full()
            .overflow_hidden()
            .bg(t.bg)
            .border_1()
            .border_color(t.border)
            .text_color(t.text)
            .text_size(px(BODY))
            .when_some(ui_font(), |d, family| d.font_family(family))
            .flex()
            .flex_col()
            .child(title_bar(t, cx))
            .child(content)
    }
}

/// With client-side decorations there is no window-manager title bar, so the
/// panel carries its own drag handle and close control.
fn title_bar(t: Theme, cx: &mut Context<Panel>) -> impl IntoElement {
    div()
        .id("title")
        .h(px(TITLE_BAR))
        .flex_none()
        .flex()
        .items_center()
        .pl(px(PADDING))
        .pr(px(4.0))
        .border_b_1()
        .border_color(t.divider)
        .on_mouse_down(MouseButton::Left, |_, window, _| window.start_window_move())
        .child(
            div()
                .flex_1()
                .text_size(px(CAPTION))
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(t.secondary)
                .child("LLM Usage"),
        )
        .child(
            div()
                .id("close")
                .size(px(HIT_TARGET))
                .flex()
                .items_center()
                .justify_center()
                .rounded(px(5.0))
                .cursor_pointer()
                .hover(move |s| s.bg(t.button_hover))
                .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                .on_click(cx.listener(|_, _, window, _| window.remove_window()))
                .child(icon("xmark", 12.0, t.secondary)),
        )
}

fn divider(t: Theme) -> impl IntoElement {
    div().h(px(1.0)).w_full().bg(t.divider)
}

fn caption(text: impl Into<SharedString>) -> impl IntoElement {
    div().w_full().text_size(px(SUBHEADLINE)).child(text.into())
}

fn button(id: &'static str, t: Theme) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .h(px(HIT_TARGET))
        .px(px(10.0))
        .flex()
        .items_center()
        .gap(px(4.0))
        .rounded(px(6.0))
        .border_1()
        .border_color(t.border)
        .bg(t.button)
        .cursor_pointer()
        .hover(move |s| s.bg(t.button_hover))
}

impl Panel {
    fn footer(&self, last_refreshed: &str, t: Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let legend_icon = if self.legend_expanded {
            t.text
        } else {
            t.secondary
        };
        div()
            .flex()
            .items_center()
            .gap(px(ROW_SPACING))
            .text_size(px(SUBHEADLINE))
            .child(
                button("refresh", t)
                    .on_click(cx.listener(|this, _, _, cx| this.send(FromPanel::Refresh, cx)))
                    .child("Refresh"),
            )
            // The system's own "explain this" affordance: costs nothing until asked.
            .child(
                div()
                    .id("legend")
                    .size(px(HIT_TARGET))
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded(px(5.0))
                    .cursor_pointer()
                    .hover(move |s| s.bg(t.button_hover))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.legend_expanded = !this.legend_expanded;
                        cx.notify();
                    }))
                    .child(icon("questionmark.circle", 15.0, legend_icon)),
            )
            .child(div().flex_1())
            .child(
                div()
                    .text_size(px(CAPTION))
                    .text_color(t.secondary)
                    .child(last_refreshed.to_string()),
            )
            // Quit is the destructive one and has no confirm step, so it takes
            // the opposite end of the row and no button chrome.
            .child(
                div()
                    .id("quit")
                    .h(px(HIT_TARGET))
                    .px(px(ROW_SPACING))
                    .flex()
                    .items_center()
                    .rounded(px(5.0))
                    .cursor_pointer()
                    .hover(move |s| s.bg(t.button_hover))
                    .on_click(cx.listener(|this, _, _, cx| this.send(FromPanel::Quit, cx)))
                    .child("Quit"),
            )
    }

    fn card(
        &self,
        source: &UsageSource,
        now: Timestamp,
        t: Theme,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let state = source.aged_state(now);
        let dimmed = matches!(state, SourceState::Stale { .. });
        // Only Claude reports `is_active`; without it every figure stays primary.
        let reports_activity = source.windows.iter().any(|w| w.is_active);
        // The worst of what this card's own rows show.
        let severity = source
            .windows
            .iter()
            .map(|w| w.displayed_severity(now))
            .max()
            .unwrap_or(Severity::Normal);
        let (status_symbol, status_color) = match state {
            SourceState::Ok => (symbol(severity), t.severity(severity)),
            SourceState::Stale { .. } => ("clock", t.secondary),
            SourceState::Error(_) => ("xmark.octagon", t.secondary),
            SourceState::Unconfigured => ("circle.dashed", t.secondary),
        };
        // A stale or failed card still knows what it last saw: say what the
        // figure was, in outline, without claiming it still holds.
        let last_known = (state != SourceState::Ok && severity > Severity::Normal)
            .then(|| last_known_symbol(severity));

        let header = div()
            .flex()
            .items_center()
            .gap(px(6.0))
            .child(
                div()
                    .flex()
                    .gap(px(3.0))
                    .child(icon(status_symbol, 14.0, status_color))
                    .when_some(last_known, |d, s| {
                        d.child(icon(s, 14.0, t.severity(severity)))
                    }),
            )
            .child(
                div()
                    .flex_none()
                    .whitespace_nowrap()
                    .font_weight(FontWeight::BOLD)
                    .child(source.display_name.clone()),
            )
            .child(div().flex_1().min_w(px(6.0)))
            .when_some(source.plan.clone(), |d, plan| {
                // Provider-supplied and can be long; never let it push the name around.
                d.child(
                    div()
                        .min_w_0()
                        .overflow_hidden()
                        .whitespace_nowrap()
                        .text_ellipsis()
                        .text_size(px(CAPTION))
                        .text_color(t.secondary)
                        .child(plan),
                )
            });

        let mut card = div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(ROW_SPACING))
            .child(header);

        // Each source authenticates separately, so which login is being metered
        // is worth stating even when they all happen to match.
        if let Some(account) = &source.account {
            card = card.child(
                div()
                    .mt(px(-3.0))
                    .overflow_hidden()
                    .whitespace_nowrap()
                    .text_ellipsis()
                    .text_size(px(CAPTION))
                    .text_color(t.secondary)
                    .child(account.clone()),
            );
        }

        match &state {
            SourceState::Unconfigured => {
                card = card.child(caption(
                    source
                        .note
                        .clone()
                        .unwrap_or_else(|| "Not configured".into()),
                ));
            }
            SourceState::Error(reason) => {
                card = card.child(caption(reason.clone()));
                if let Some(note) = source.note.as_ref().filter(|n| *n != reason) {
                    card = card.child(caption(note.clone()));
                }
                card = card.child(
                    div().flex().child(
                        button(leak_id("retry", &source.id), t)
                            .text_size(px(SUBHEADLINE))
                            .on_click(
                                cx.listener(|this, _, _, cx| this.send(FromPanel::Refresh, cx)),
                            )
                            .child(icon("arrow.clockwise", 12.0, t.text))
                            .child("Retry"),
                    ),
                );
            }
            SourceState::Ok | SourceState::Stale { .. } => {
                for (index, w) in source.windows.iter().enumerate() {
                    card = card.child(if w.is_unused() {
                        unused_row(w, t, window).into_any_element()
                    } else {
                        window_row(
                            w,
                            index == 0,
                            dimmed,
                            reports_activity && !w.is_active,
                            now,
                            t,
                            window,
                        )
                        .into_any_element()
                    });
                }
                if let Some(spend) = &source.spend {
                    card = card.child(spend_row(spend, dimmed, t, window));
                }
                if let SourceState::Stale { since } = state {
                    card = card.child(
                        div()
                            .flex()
                            .items_center()
                            .gap(px(5.0))
                            .text_size(px(SUBHEADLINE))
                            .child(icon("clock", 12.0, t.text))
                            .child(format!(
                                "Last known · {}",
                                format::relative(Some(since), now)
                            )),
                    );
                }
                // Before the disclosure: placed after, it read as the collapsed
                // section's contents.
                if let Some(note) = &source.note {
                    card = card.child(caption(note.clone()));
                }
                let buckets = source.meaningful_buckets();
                if !buckets.is_empty() {
                    let expanded = self.expanded_buckets.contains(&source.id);
                    let id = source.id.clone();
                    card = card.child(
                        div()
                            .id(leak_id("buckets", &source.id))
                            .h(px(HIT_TARGET))
                            .flex()
                            .items_center()
                            .gap(px(5.0))
                            .text_size(px(SUBHEADLINE))
                            .cursor_pointer()
                            .on_click(cx.listener(move |this, _, _, cx| {
                                if !this.expanded_buckets.remove(&id) {
                                    this.expanded_buckets.insert(id.clone());
                                }
                                cx.notify();
                            }))
                            .child(icon(
                                if expanded {
                                    "chevron.up"
                                } else {
                                    "chevron.down"
                                },
                                12.0,
                                t.text,
                            ))
                            .child(format!("By model ({})", buckets.len())),
                    );
                    if expanded {
                        for bucket in buckets {
                            card = card.child(
                                div()
                                    .flex()
                                    .text_size(px(SUBHEADLINE))
                                    .child(
                                        div()
                                            .w(px(120.0))
                                            .overflow_hidden()
                                            .whitespace_nowrap()
                                            .text_ellipsis()
                                            .child(bucket.label.clone()),
                                    )
                                    .child(div().flex_1())
                                    .child(format::percent(bucket.used_percent)),
                            );
                        }
                    }
                }
            }
        }
        card.into_any_element()
    }
}

/// gpui element ids are `'static`; a card's ids are few and fixed per source,
/// so interning them once is cheaper than allocating every frame.
fn leak_id(prefix: &str, id: &str) -> &'static str {
    use std::collections::HashMap;
    use std::sync::{Mutex, OnceLock};
    static IDS: OnceLock<Mutex<HashMap<String, &'static str>>> = OnceLock::new();
    let key = format!("{prefix}-{id}");
    let mut ids = IDS.get_or_init(Default::default).lock().unwrap();
    ids.entry(key.clone())
        .or_insert_with(|| Box::leak(key.into_boxed_str()))
}

// MARK: - Rows

/// Track + fill + pace marker. The marker is what makes over-consumption
/// legible without doing arithmetic (docs/design.md §4).
fn gauge(
    used_percent: f64,
    elapsed: Option<f64>,
    height: f32,
    dimmed: bool,
    t: Theme,
) -> impl IntoElement {
    let pace_delta = elapsed.map(|e| used_percent / 100.0 - e);
    // The marker's own tier: any positive delta at all.
    let over_pace = pace_delta.unwrap_or(0.0) > 0.0;
    // The same escalation the card header uses, so the bar and the mark above
    // it cannot make different claims about the same window.
    let severity = Severity::escalated(Severity::from_used(used_percent), pace_delta);
    let fraction = (used_percent / 100.0).clamp(0.0, 1.0) as f32;
    div()
        .flex_1()
        .min_w_0()
        .h(px(height))
        .relative()
        .rounded_full()
        .bg(t.track)
        .opacity(if dimmed { 0.4 } else { 1.0 })
        .child(
            div()
                .absolute()
                .top_0()
                .left_0()
                .h_full()
                .w(relative(fraction))
                .rounded_full()
                .bg(t.severity(severity)),
        )
        .when_some(elapsed, |d, elapsed| {
            // Hollow versus filled says over-pace in shape, and above the track
            // it is measured against the panel background, not the track.
            d.child(
                div()
                    .absolute()
                    .top(px(-(PACE_MARKER - 1.0)))
                    .left(relative(elapsed.clamp(0.0, 1.0) as f32))
                    .child(div().absolute().left(px(-PACE_MARKER / 2.0)).child(icon(
                        if over_pace {
                            "arrowtriangle.down.fill"
                        } else {
                            "arrowtriangle.down"
                        },
                        PACE_MARKER,
                        if over_pace { t.red } else { t.secondary },
                    ))),
            )
        })
}

/// The shared column skeleton: label · gauge · percent · trailing.
#[allow(clippy::too_many_arguments)]
fn meter_row(
    label: &str,
    deemphasised: bool,
    used_percent: f64,
    elapsed: Option<f64>,
    height: f32,
    dimmed: bool,
    trailing: String,
    t: Theme,
    window: &Window,
) -> impl IntoElement {
    div()
        .min_h(px(ROW_MIN_HEIGHT))
        .flex()
        .items_center()
        .gap(px(ROW_SPACING))
        .child(fitted(
            label.to_string(),
            LABEL_COLUMN,
            SUBHEADLINE,
            FontWeight::NORMAL,
            window,
        ))
        .child(gauge(used_percent, elapsed, height, dimmed, t))
        // De-emphasis rides on weight rather than a faded fill: the figure is the
        // row's whole point, so it may not drop below 4.5:1.
        .child(
            div()
                .w(px(PERCENT_COLUMN))
                .flex_none()
                .flex()
                .justify_end()
                .whitespace_nowrap()
                .font_weight(if deemphasised {
                    FontWeight::NORMAL
                } else {
                    FontWeight::SEMIBOLD
                })
                .child(format::percent(used_percent)),
        )
        .child(
            div()
                .w(px(RESET_COLUMN))
                .flex_none()
                .flex()
                .justify_end()
                .child(fitted(
                    trailing,
                    RESET_COLUMN,
                    SUBHEADLINE,
                    FontWeight::NORMAL,
                    window,
                )),
        )
}

fn window_row(
    w: &UsageWindow,
    primary: bool,
    dimmed: bool,
    deemphasised: bool,
    now: Timestamp,
    t: Theme,
    window: &Window,
) -> impl IntoElement {
    div()
        .flex()
        .flex_col()
        .gap(px(2.0))
        .child(meter_row(
            &w.label,
            deemphasised,
            w.used_percent,
            w.elapsed_fraction(now),
            if primary {
                GAUGE_PRIMARY
            } else {
                GAUGE_SECONDARY
            },
            dimmed,
            format::resets_in(w.resets_at, now),
            t,
            window,
        ))
        // The marker alone does not say what it means; spell it out on the one
        // row where it matters. The symbol carries the alarm, so the sentence
        // itself stays at full contrast.
        .when_some(format::over_pace(w, now), |d, pace| {
            d.child(
                div()
                    .pl(px(LABEL_COLUMN + ROW_SPACING))
                    .flex()
                    .items_center()
                    .gap(px(4.0))
                    .text_size(px(FOOTNOTE))
                    .font_weight(FontWeight::MEDIUM)
                    .child(icon(symbol(Severity::Critical), 11.0, t.red))
                    .child(pace),
            )
        })
}

/// A window at zero does not need a gauge, a percentage and a reset time to
/// say "you have not touched this".
fn unused_row(w: &UsageWindow, t: Theme, window: &Window) -> impl IntoElement {
    div()
        .min_h(px(18.0))
        .flex()
        .items_center()
        .gap(px(ROW_SPACING))
        .text_size(px(SUBHEADLINE))
        .child(fitted(
            w.label.clone(),
            LABEL_COLUMN,
            SUBHEADLINE,
            FontWeight::NORMAL,
            window,
        ))
        .child(div().text_color(t.secondary).child("unused"))
}

fn spend_row(spend: &UsageSpend, dimmed: bool, t: Theme, window: &Window) -> impl IntoElement {
    meter_row(
        &spend.label,
        false,
        spend.used_percent,
        None,
        GAUGE_SECONDARY,
        dimmed,
        spend.detail.clone(),
        t,
        window,
    )
}

// MARK: - Legend

fn legend(t: Theme) -> impl IntoElement {
    let row = |symbols: Vec<(&'static str, Hsla)>, text: &'static str| {
        div()
            .flex()
            .items_start()
            .gap(px(ROW_SPACING))
            .text_size(px(FOOTNOTE))
            .child(
                div()
                    .w(px(LEGEND_SYMBOL_COLUMN))
                    .flex_none()
                    .flex()
                    .gap(px(2.0))
                    .pt(px(1.0))
                    .children(symbols.into_iter().map(|(s, c)| icon(s, 11.0, c))),
            )
            .child(div().flex_1().child(text))
    };
    div()
        .flex()
        .flex_col()
        .gap(px(ROW_SPACING))
        .child(row(
            vec![("arrowtriangle.down", t.text), ("arrowtriangle.down.fill", t.text)],
            "Pace marker: how far into the window you are. Filled means you have already used more than that.",
        ))
        .child(row(
            [Severity::Normal, Severity::Caution, Severity::Warning, Severity::Critical]
                .into_iter()
                .map(|s| (symbol(s), t.text))
                .collect(),
            "Card mark: under 60%, then 60%, 80%, 95% used — or over pace.",
        ))
        .child(row(
            vec![("clock", t.text), ("xmark.octagon", t.text), ("circle.dashed", t.text)],
            "Outlines: the figures are stale, the fetch failed, or the source is not set up.",
        ))
}
