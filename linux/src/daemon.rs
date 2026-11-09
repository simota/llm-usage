//! The long-running tray process: providers, the store, the tray item, and the
//! panel child. It links no window toolkit at runtime — see `ipc.rs` for why
//! the panel is a separate process. The lifecycle half of
//! `Sources/LLMUsage/UsageStore.swift` plus `App.swift`.

use std::io::{BufRead, BufReader};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{RecvTimeoutError, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use jiff::Timestamp;

use crate::icon::TrayArt;
use crate::ipc::{FromPanel, ToPanel, write_line};
use crate::menu::{self, Line};
use crate::model::UsageSource;
use crate::provider::UsageProvider;
use crate::store::UsageStore;
use crate::tray::{Tray, TrayEvent};
use crate::{agy, claude, codex};

pub enum Event {
    Update(&'static str, Box<Result<UsageSource, String>>),
    Tray(TrayEvent),
    Panel(u32, FromPanel),
    PanelExited(u32),
}

const TICK: Duration = Duration::from_secs(30);
/// A panel that closed itself this recently lost focus to the click now
/// arriving from the tray; that click must not reopen it.
const REOPEN_GUARD: Duration = Duration::from_millis(400);

struct PanelChild {
    child: Child,
    stdin: ChildStdin,
}

struct Daemon {
    events: Sender<Event>,
    store: UsageStore,
    providers: Vec<Box<dyn UsageProvider>>,
    tray: Option<ksni::blocking::Handle<Tray>>,
    published: Option<(TrayArt, String, Vec<Line>)>,
    panel: Option<PanelChild>,
    panel_closed_at: Option<Instant>,
}

fn providers(events: &Sender<Event>) -> Vec<Box<dyn UsageProvider>> {
    let sink = |id: &'static str| {
        let events = Mutex::new(events.clone());
        Arc::new(move |result| {
            let _ = events
                .lock()
                .unwrap()
                .send(Event::Update(id, Box::new(result)));
        })
    };
    vec![
        Box::new(codex::CodexProvider::new(
            Arc::new(codex::server_process),
            sink("codex"),
        )),
        Box::new(claude::ClaudeProvider::new(
            claude::Deps::system(),
            sink("claude"),
        )),
        Box::new(agy::AgyProvider::new(agy::Deps::system(), sink("agy"))),
    ]
}

pub fn run(open_panel: bool) {
    let (events, receiver) = channel::<Event>();
    let store = UsageStore::default();
    let now = Timestamp::now();
    let tray = {
        use ksni::blocking::TrayMethods;
        Tray {
            art: TrayArt::from_sources(&store.sources, None, false, now),
            summary: store.summary(now).text,
            lines: menu::lines(&store, now),
            events: Mutex::new(events.clone()),
        }
        .spawn()
    };
    let tray = match tray {
        Ok(handle) => Some(handle),
        Err(error) => {
            // Without a StatusNotifierItem host the panel is the only way in,
            // so it opens now and closing it quits.
            eprintln!("llm-usage: no system tray ({error}); showing the panel as a window");
            None
        }
    };

    let mut daemon = Daemon {
        providers: providers(&events),
        events,
        store,
        tray,
        published: None,
        panel: None,
        panel_closed_at: None,
    };
    // Providers start when the app launches and stop when it quits; opening the
    // panel never starts another fetch loop.
    daemon.store.mark_refresh_attempt(Timestamp::now());
    daemon.providers.iter().for_each(|p| p.start());
    daemon.publish_tray();
    if open_panel || daemon.tray.is_none() {
        daemon.open_panel();
    }

    let mut next_tick = Instant::now() + TICK;
    loop {
        let event = match receiver.recv_timeout(next_tick.saturating_duration_since(Instant::now()))
        {
            Ok(event) => event,
            Err(RecvTimeoutError::Timeout) => {
                next_tick = Instant::now() + TICK;
                daemon.tick();
                continue;
            }
            Err(RecvTimeoutError::Disconnected) => break,
        };
        if !daemon.handle(event) {
            break;
        }
    }
    daemon.providers.iter().for_each(|p| p.stop());
    // Closing its stdin is the panel's signal to quit.
    daemon.panel = None;
}

impl Daemon {
    /// Returns false when the app should quit.
    fn handle(&mut self, event: Event) -> bool {
        match event {
            Event::Update(id, result) => {
                self.store.apply(id, *result, Timestamp::now());
                self.publish_tray();
                self.push_snapshot();
            }
            Event::Tray(TrayEvent::Refresh) => self.refresh_all(),
            Event::Tray(TrayEvent::Quit) => return false,
            Event::Tray(TrayEvent::Show) => match self.panel {
                Some(_) => self.send_panel(&ToPanel::Activate),
                None => self.open_panel(),
            },
            Event::Tray(TrayEvent::Toggle) => {
                if self
                    .panel_closed_at
                    .is_some_and(|at| at.elapsed() < REOPEN_GUARD)
                {
                    return true;
                }
                match self.panel {
                    Some(_) => self.send_panel(&ToPanel::Toggle),
                    None => self.open_panel(),
                }
            }
            Event::Panel(pid, command) if self.panel_pid() == Some(pid) => match command {
                FromPanel::Refresh => self.refresh_all(),
                FromPanel::Quit => return false,
            },
            Event::Panel(..) => {}
            Event::PanelExited(pid) if self.panel_pid() == Some(pid) => {
                if let Some(mut panel) = self.panel.take() {
                    drop(panel.stdin);
                    std::thread::spawn(move || panel.child.wait());
                }
                self.panel_closed_at = Some(Instant::now());
                if self.tray.is_none() {
                    return false;
                }
            }
            Event::PanelExited(_) => {}
        }
        true
    }

    fn refresh_all(&mut self) {
        self.store.mark_refresh_attempt(Timestamp::now());
        self.providers.iter().for_each(|p| p.refresh());
    }

    fn tick(&mut self) {
        if self.store.update_clock(Timestamp::now()) {
            self.refresh_all();
        }
        self.publish_tray();
    }

    fn publish_tray(&mut self) {
        let now = Timestamp::now();
        let art = TrayArt::from_sources(
            &self.store.sources,
            self.store.worst(now).map(|w| w.used_percent),
            self.store.shows_worst_figure,
            now,
        );
        // The menu's relative times ("12s ago", "in 48m") move with the clock,
        // so the 30-second tick republishes them as well as every update.
        let next = (
            art,
            self.store.summary(now).text,
            menu::lines(&self.store, now),
        );
        if self.published.as_ref() == Some(&next) {
            return;
        }
        if let Some(tray) = &self.tray {
            let (art, summary, lines) = next.clone();
            tray.update(move |tray| {
                tray.art = art;
                tray.summary = summary;
                tray.lines = lines;
            });
        }
        self.published = Some(next);
    }

    fn panel_pid(&self) -> Option<u32> {
        self.panel.as_ref().map(|p| p.child.id())
    }

    fn open_panel(&mut self) {
        let exe = match std::env::current_exe() {
            Ok(exe) => exe,
            Err(error) => return eprintln!("llm-usage: cannot locate own executable: {error}"),
        };
        let spawned = Command::new(exe)
            .arg("--panel-view")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn();
        let mut child = match spawned {
            Ok(child) => child,
            Err(error) => return eprintln!("llm-usage: could not open the panel: {error}"),
        };
        let pid = child.id();
        let stdin = child.stdin.take().expect("stdin is piped");
        let stdout = child.stdout.take().expect("stdout is piped");
        let events = self.events.clone();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                if let Ok(command) = serde_json::from_str::<FromPanel>(&line) {
                    let _ = events.send(Event::Panel(pid, command));
                }
            }
            let _ = events.send(Event::PanelExited(pid));
        });
        self.panel = Some(PanelChild { child, stdin });
        self.push_snapshot();
    }

    fn push_snapshot(&mut self) {
        let snapshot = ToPanel::Snapshot {
            sources: self.store.sources.clone(),
            last_refreshed: self.store.last_refreshed,
        };
        self.send_panel(&snapshot);
    }

    /// A write to a panel that already exited fails quietly; its reader thread
    /// reports the exit.
    fn send_panel(&mut self, message: &ToPanel) {
        if let Some(panel) = self.panel.as_mut() {
            let _ = write_line(&mut panel.stdin, message);
        }
    }
}
