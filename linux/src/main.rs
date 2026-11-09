//! LLM Usage for Linux: how much of your Claude Code, Codex and Antigravity
//! usage limits you have burned through, in the system tray. The Rust + gpui
//! counterpart of the macOS app in `Sources/LLMUsage`.

mod agy;
mod assets;
mod claude;
mod cli;
mod codex;
mod daemon;
mod demo;
mod icon;
mod ipc;
mod model;
mod panel;
mod probe;
mod provider;
mod store;
mod tray;
mod ui;

const HELP: &str = "\
usage: llm-usage [--panel | --probe | --demo <fixture> | --icon <dir> | --version]

  (no flags)        run in the system tray
  --panel           also open the panel at launch
  --probe           print every source's normalised usage and exit, no GUI
  --demo <fixture>  open the panel on fixed data: baseline, states or severity
  --icon <dir>      write the tray artwork to PNGs in <dir> and exit
";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        None => daemon::run(false),
        Some("--panel") => daemon::run(true),
        // Internal: the panel window, spawned by the daemon.
        Some("--panel-view") => panel::run(panel::Link::Daemon),
        Some("--demo") => match args.get(1).and_then(|name| demo::fixture(name)) {
            Some(sources) => panel::run(panel::Link::Demo(sources)),
            None => {
                eprintln!("llm-usage: --demo takes one of: {}", demo::NAMES.join(", "));
                std::process::exit(2);
            }
        },
        Some("--probe") => std::process::exit(probe::run()),
        Some("--icon") => {
            let Some(dir) = args.get(1) else {
                eprint!("{HELP}");
                std::process::exit(2);
            };
            if let Err(error) = std::fs::create_dir_all(dir).and_then(|()| icon::dump(dir)) {
                eprintln!("llm-usage: {error}");
                std::process::exit(1);
            }
        }
        Some("--version") => println!("llm-usage {}", env!("CARGO_PKG_VERSION")),
        Some("--help" | "-h") => print!("{HELP}"),
        Some(other) => {
            eprintln!("llm-usage: unknown argument {other}");
            eprint!("{HELP}");
            std::process::exit(2);
        }
    }
}
