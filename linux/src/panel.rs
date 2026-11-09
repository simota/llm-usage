//! The panel process: one gpui window that draws what the daemon sends and
//! exits when the window closes (see `ipc.rs`). `--demo` runs the same window
//! on fixed data with no daemon at all.

use std::io::BufRead;
use std::time::Duration;

use gpui::{
    App, AppContext, Application, Bounds, Entity, KeyBinding, TitlebarOptions, WindowBounds,
    WindowDecorations, WindowHandle, WindowKind, WindowOptions, px, size,
};
use jiff::Timestamp;

use crate::assets::Assets;
use crate::ipc::{FromPanel, ToPanel, write_line};
use crate::model::UsageSource;
use crate::store::UsageStore;
use crate::ui::{ClosePanel, Panel, QuitApp, RefreshAll};

pub enum Link {
    /// Snapshots on stdin, commands on stdout.
    Daemon,
    /// Fixed sources; Refresh does nothing and Quit closes the window.
    Demo(Vec<UsageSource>),
}

pub struct PanelModel {
    pub store: UsageStore,
    demo: bool,
}

impl PanelModel {
    pub fn command(&mut self, command: FromPanel, cx: &mut App) {
        if self.demo {
            if command == FromPanel::Quit {
                cx.quit();
            }
            return;
        }
        // The daemon owns the providers; this process only asks.
        let _ = write_line(&mut std::io::stdout().lock(), &command);
    }
}

pub fn run(link: Link) {
    Application::new()
        .with_assets(Assets)
        .run(move |cx: &mut App| {
            cx.bind_keys([
                KeyBinding::new("ctrl-r", RefreshAll, Some("Panel")),
                KeyBinding::new("escape", ClosePanel, Some("Panel")),
                KeyBinding::new("ctrl-q", QuitApp, Some("Panel")),
            ]);
            crate::ui::init_ui_font(&cx.text_system().all_font_names());

            let now = Timestamp::now();
            let (store, demo) = match link {
                Link::Daemon => (UsageStore::new(Vec::new(), now), false),
                Link::Demo(sources) => (UsageStore::new(sources, now), true),
            };
            let model = cx.new(|_| PanelModel { store, demo });

            // Relative times ("12s ago", "in 48m") and staleness age with the clock.
            let clock = model.clone();
            cx.spawn(async move |cx| {
                loop {
                    cx.background_executor()
                        .timer(Duration::from_secs(30))
                        .await;
                    if cx
                        .update(|cx| clock.update(cx, |_, cx| cx.notify()))
                        .is_err()
                    {
                        break;
                    }
                }
            })
            .detach();

            if demo {
                open_window(&model, cx);
                return;
            }

            let (sender, receiver) = async_channel::unbounded::<ToPanel>();
            std::thread::spawn(move || {
                for line in std::io::stdin().lock().lines() {
                    let Ok(line) = line else { break };
                    if let Ok(message) = serde_json::from_str::<ToPanel>(&line)
                        && sender.send_blocking(message).is_err()
                    {
                        break;
                    }
                }
                // Dropping the sender ends the loop below: the daemon is gone.
            });
            cx.spawn(async move |cx| {
                let mut window: Option<WindowHandle<Panel>> = None;
                while let Ok(message) = receiver.recv().await {
                    let handled = cx.update(|cx| match message {
                        ToPanel::Snapshot {
                            sources,
                            last_refreshed,
                        } => {
                            model.update(cx, |model, cx| {
                                model.store = UsageStore::new(sources, Timestamp::now());
                                model.store.last_refreshed = last_refreshed;
                                cx.notify();
                            });
                            // The window waits for the first snapshot, so it never
                            // flashes an empty panel.
                            if window.is_none() {
                                window = open_window(&model, cx);
                            }
                        }
                        ToPanel::Toggle => {
                            if let Some(window) = window {
                                let _ = window.update(cx, |panel, window, _| panel.toggle(window));
                            }
                        }
                        ToPanel::Activate => {
                            if let Some(window) = window {
                                let _ = window.update(cx, |_, window, _| window.activate_window());
                            }
                        }
                    });
                    if handled.is_err() {
                        return;
                    }
                }
                let _ = cx.update(|cx| cx.quit());
            })
            .detach();
        });
}

fn open_window(model: &Entity<PanelModel>, cx: &mut App) -> Option<WindowHandle<Panel>> {
    // The real height is set by the panel itself once it has laid out.
    let bounds = Bounds::centered(None, size(px(322.0), px(480.0)), cx);
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        titlebar: Some(TitlebarOptions {
            title: Some("LLM Usage".into()),
            ..Default::default()
        }),
        focus: true,
        show: true,
        kind: WindowKind::Normal,
        is_resizable: false,
        is_minimizable: false,
        app_id: Some("llm-usage".into()),
        window_decorations: Some(WindowDecorations::Client),
        ..Default::default()
    };
    let model = model.clone();
    match cx.open_window(options, |window, cx| {
        cx.new(|cx| Panel::new(model, window, cx))
    }) {
        Ok(handle) => {
            cx.activate(true);
            Some(handle)
        }
        Err(error) => {
            eprintln!("llm-usage: could not open the panel: {error}");
            cx.quit();
            None
        }
    }
}
