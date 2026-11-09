//! What every source has in common: start, refresh, stop, and a callback that
//! must never fire for a session that was already stopped.
//!
//! The Swift app gives each provider a serial `DispatchQueue`. Here each started
//! session owns one worker thread and a channel; the thread is the queue. A
//! session's `alive` flag is cleared by `stop()` before anything else, so a
//! worker still blocked on I/O cannot publish once it returns.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};

use crate::model::UsageSource;

pub type UpdateFn = Arc<dyn Fn(Result<UsageSource, String>) + Send + Sync>;

pub trait UsageProvider: Send + Sync {
    fn start(&self);
    fn refresh(&self);
    fn stop(&self);
}

pub enum Msg<E> {
    Refresh,
    Stop,
    Event(E),
}

/// Publishes only while its session is alive.
#[derive(Clone)]
pub struct Emitter {
    alive: Arc<AtomicBool>,
    update: UpdateFn,
}

impl Emitter {
    pub fn is_alive(&self) -> bool {
        self.alive.load(Ordering::SeqCst)
    }

    pub fn emit(&self, result: Result<UsageSource, String>) {
        if self.is_alive() {
            (self.update)(result);
        }
    }

    pub fn source(&self, source: UsageSource) {
        self.emit(Ok(source));
    }
}

pub struct Session<E> {
    pub rx: Receiver<Msg<E>>,
    pub tx: Sender<Msg<E>>,
    pub emitter: Emitter,
}

impl<E> Session<E> {
    /// Refreshes that arrived while a fetch was running were answered by that
    /// fetch; dropping them is what keeps one request in flight. Returns false
    /// when a stop was among them.
    pub fn drain_refreshes(&self, mut on_event: impl FnMut(E)) -> bool {
        while let Ok(msg) = self.rx.try_recv() {
            match msg {
                Msg::Refresh => {}
                Msg::Stop => return false,
                Msg::Event(event) => on_event(event),
            }
        }
        self.emitter.is_alive()
    }
}

/// The running session's channel and alive flag, if one is running.
type Slot<E> = Option<(Sender<Msg<E>>, Arc<AtomicBool>)>;

/// One worker per started session. `start` on a running runner is a no-op, as
/// is `refresh` or `stop` on a stopped one.
pub struct Runner<E> {
    update: UpdateFn,
    slot: Mutex<Slot<E>>,
}

impl<E: Send + 'static> Runner<E> {
    pub fn new(update: UpdateFn) -> Self {
        Self {
            update,
            slot: Mutex::new(None),
        }
    }

    pub fn start(&self, name: &str, work: impl FnOnce(Session<E>) + Send + 'static) {
        let mut slot = self.slot.lock().unwrap();
        if slot.is_some() {
            return;
        }
        let (tx, rx) = channel();
        let alive = Arc::new(AtomicBool::new(true));
        let session = Session {
            rx,
            tx: tx.clone(),
            emitter: Emitter {
                alive: alive.clone(),
                update: self.update.clone(),
            },
        };
        std::thread::Builder::new()
            .name(format!("llm-usage-{name}"))
            .spawn(move || work(session))
            .expect("spawn provider thread");
        *slot = Some((tx, alive));
    }

    pub fn refresh(&self) {
        if let Some((tx, _)) = self.slot.lock().unwrap().as_ref() {
            let _ = tx.send(Msg::Refresh);
        }
    }

    pub fn stop(&self) {
        if let Some((tx, alive)) = self.slot.lock().unwrap().take() {
            alive.store(false, Ordering::SeqCst);
            let _ = tx.send(Msg::Stop);
        }
    }
}

impl<E> Drop for Runner<E> {
    fn drop(&mut self) {
        if let Some((tx, alive)) = self.slot.lock().unwrap().take() {
            alive.store(false, Ordering::SeqCst);
            let _ = tx.send(Msg::Stop);
        }
    }
}
