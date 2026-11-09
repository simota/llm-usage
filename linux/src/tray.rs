//! The system tray item: a StatusNotifierItem on the session bus, which KDE,
//! XFCE, Cinnamon, and GNOME with the AppIndicator extension (Ubuntu's default)
//! all host. Left click toggles the panel; the context menu repeats the panel's
//! two actions so the item is usable without opening it.

use std::sync::Mutex;
use std::sync::mpsc::Sender;

use ksni::menu::StandardItem;
use ksni::{Icon, MenuItem, ToolTip};

use crate::daemon::Event;
use crate::icon::{self, TrayArt};

pub enum TrayEvent {
    /// Left click: open the panel, or close it if it is open.
    Toggle,
    Show,
    Refresh,
    Quit,
}

pub struct Tray {
    pub art: TrayArt,
    pub summary: String,
    pub events: Mutex<Sender<Event>>,
}

impl Tray {
    fn send(&self, event: TrayEvent) {
        let _ = self.events.lock().unwrap().send(Event::Tray(event));
    }
}

impl ksni::Tray for Tray {
    fn id(&self) -> String {
        "llm-usage".into()
    }

    fn title(&self) -> String {
        "LLM Usage".into()
    }

    fn category(&self) -> ksni::Category {
        ksni::Category::ApplicationStatus
    }

    fn icon_pixmap(&self) -> Vec<Icon> {
        let color = icon::foreground();
        [22usize, 32, 48, 64]
            .into_iter()
            .map(|size| Icon {
                width: size as i32,
                height: size as i32,
                data: icon::argb(&self.art, size, color),
            })
            .collect()
    }

    fn tool_tip(&self) -> ToolTip {
        ToolTip {
            title: "LLM Usage".into(),
            description: self.summary.clone(),
            icon_name: String::new(),
            icon_pixmap: Vec::new(),
        }
    }

    fn activate(&mut self, _x: i32, _y: i32) {
        self.send(TrayEvent::Toggle);
    }

    fn menu(&self) -> Vec<MenuItem<Self>> {
        vec![
            MenuItem::Standard(StandardItem {
                label: self.summary.clone(),
                enabled: false,
                ..Default::default()
            }),
            MenuItem::Separator,
            MenuItem::Standard(StandardItem {
                label: "Open Panel".into(),
                activate: Box::new(|tray: &mut Self| tray.send(TrayEvent::Show)),
                ..Default::default()
            }),
            MenuItem::Standard(StandardItem {
                label: "Refresh".into(),
                activate: Box::new(|tray: &mut Self| tray.send(TrayEvent::Refresh)),
                ..Default::default()
            }),
            MenuItem::Separator,
            MenuItem::Standard(StandardItem {
                label: "Quit".into(),
                activate: Box::new(|tray: &mut Self| tray.send(TrayEvent::Quit)),
                ..Default::default()
            }),
        ]
    }
}
