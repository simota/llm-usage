//! Finds and runs command-line tools for a process that may never have seen a
//! shell. Port of `Sources/LLMUsage/CLI.swift`.
//!
//! A tray app started from a desktop session's autostart gets the session's
//! PATH, which commonly lacks `~/.local/bin` and anything a version manager
//! adds. Search the usual install prefixes first, since that resolves most
//! installs without spawning anything, and only ask the login shell when it does
//! not: a version manager's PATH exists nowhere else, but paying for a shell
//! startup at launch is not worth it until the cheap answer has failed.

use std::collections::{HashMap, HashSet};
use std::io::Read;
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::ExitStatusExt;
use std::process::{Child, Command, Stdio};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

pub type Env = HashMap<String, String>;

#[derive(Clone, Debug, PartialEq)]
pub struct Resolution {
    pub path: String,
    pub environment: Env,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RunFailure {
    NotRun,
    Cancelled,
    TimedOut,
    /// The exit status, or the signal number for a signalled process.
    ExitCode(i32),
    OutputTooLarge,
}

/// Where tools land when nobody chose a directory. Ordered by how likely the
/// tool is to be there.
fn default_prefixes() -> Vec<String> {
    let home = std::env::var("HOME").unwrap_or_default();
    vec![
        format!("{home}/.local/bin"), // pipx, uv, the Claude Code installer
        "/usr/local/bin".into(),
        format!("{home}/.bun/bin"),
        format!("{home}/.volta/bin"),
        format!("{home}/.npm-global/bin"),
        format!("{home}/.cargo/bin"),
        format!("{home}/bin"),
        "/home/linuxbrew/.linuxbrew/bin".into(),
        "/snap/bin".into(),
    ]
}

#[derive(Default)]
struct ResolverState {
    resolved: HashMap<String, Resolution>,
    shell_directories: Option<Vec<String>>,
}

pub struct Resolver {
    state: Mutex<ResolverState>,
    inherited: Env,
    prefixes: Vec<String>,
    read_shell_path: Box<dyn Fn() -> Vec<String> + Send + Sync>,
}

impl Resolver {
    pub fn new(
        environment: Env,
        prefixes: Vec<String>,
        read_shell_path: impl Fn() -> Vec<String> + Send + Sync + 'static,
    ) -> Self {
        Self {
            state: Mutex::new(ResolverState::default()),
            inherited: environment,
            prefixes,
            read_shell_path: Box::new(read_shell_path),
        }
    }

    pub fn resolve(&self, tool: &str) -> Option<Resolution> {
        let mut state = self.state.lock().unwrap();
        if let Some(cached) = state.resolved.get(tool) {
            return Some(cached.clone());
        }
        let usual = dedupe(
            self.inherited_path()
                .into_iter()
                .chain(self.prefixes.iter().cloned()),
        );
        let mut search_path = usual.clone();
        let mut hit = executable(tool, &search_path);
        if hit.is_none() {
            if state.shell_directories.is_none() {
                state.shell_directories = Some((self.read_shell_path)());
            }
            // A login shell's runtime must win over a different version in a default prefix.
            let shell = state.shell_directories.clone().unwrap_or_default();
            search_path = dedupe(shell.into_iter().chain(usual));
            hit = executable(tool, &search_path);
        }
        let hit = hit?;
        let mut environment = self.inherited.clone();
        environment.insert("PATH".into(), search_path.join(":"));
        let resolution = Resolution {
            path: hit,
            environment,
        };
        state.resolved.insert(tool.to_string(), resolution.clone());
        Some(resolution)
    }

    fn inherited_path(&self) -> Vec<String> {
        self.inherited
            .get("PATH")
            .map(|p| p.split(':').map(String::from).collect())
            .unwrap_or_default()
    }
}

fn dedupe(paths: impl Iterator<Item = String>) -> Vec<String> {
    let mut seen = HashSet::new();
    paths
        .filter(|p| !p.is_empty() && seen.insert(p.clone()))
        .collect()
}

fn executable(tool: &str, paths: &[String]) -> Option<String> {
    paths
        .iter()
        .map(|dir| format!("{dir}/{tool}"))
        .find(|candidate| {
            std::fs::metadata(candidate)
                .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
                .unwrap_or(false)
        })
}

fn resolver() -> &'static Resolver {
    static RESOLVER: OnceLock<Resolver> = OnceLock::new();
    RESOLVER.get_or_init(|| {
        Resolver::new(
            std::env::vars().collect(),
            default_prefixes(),
            read_login_shell_path,
        )
    })
}

pub fn resolve(tool: &str) -> Option<Resolution> {
    resolver().resolve(tool)
}

fn read_login_shell_path() -> Vec<String> {
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".into());
    let Ok(output) = run(
        &shell,
        &["-lic", "printf '\\nLLM_USAGE_PATH=%s\\n' \"$PATH\""],
        None,
        Duration::from_secs(5),
        &[0],
        &|| false,
    ) else {
        return Vec::new();
    };
    output
        .lines()
        .rev()
        .find_map(|line| line.strip_prefix("LLM_USAGE_PATH="))
        .map(|path| {
            path.split(':')
                .filter(|p| p.starts_with('/'))
                .map(String::from)
                .collect()
        })
        .unwrap_or_default()
}

const MAX_OUTPUT: usize = 1_048_576;

/// Runs a tool and returns its stdout. Nonblocking reads keep a child (or a
/// descendant holding stdout open) from defeating the deadline. Output is
/// bounded and never written to disk; stdin and stderr are the null device.
pub fn run(
    executable: &str,
    arguments: &[&str],
    environment: Option<&Env>,
    timeout: Duration,
    accepted_exit_codes: &[i32],
    is_cancelled: &dyn Fn() -> bool,
) -> Result<String, RunFailure> {
    if is_cancelled() {
        return Err(RunFailure::Cancelled);
    }
    let mut command = Command::new(executable);
    command
        .args(arguments)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .stdout(Stdio::piped());
    if let Some(environment) = environment {
        command.env_clear().envs(environment);
    }
    let mut child = command.spawn().map_err(|_| RunFailure::NotRun)?;
    let mut stdout = child.stdout.take().expect("stdout is piped");
    let fd = stdout.as_raw_fd();
    // SAFETY: fd is owned by `stdout` and stays open for the duration of the loop.
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL);
        libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
    }

    let deadline = Instant::now() + timeout;
    let mut output = Vec::new();
    let mut buffer = [0u8; 8192];
    let mut exit = None;
    let failure = loop {
        if is_cancelled() {
            break Some(RunFailure::Cancelled);
        }
        if Instant::now() >= deadline {
            break Some(RunFailure::TimedOut);
        }
        match stdout.read(&mut buffer) {
            Ok(count) if count > 0 => {
                output.extend_from_slice(&buffer[..count]);
                if output.len() > MAX_OUTPUT {
                    break Some(RunFailure::OutputTooLarge);
                }
                continue;
            }
            Ok(_) => {
                if let Some(status) = child.try_wait().ok().flatten() {
                    exit = Some(status);
                    break None;
                }
                // A process may close stdout and keep running. POLLHUP would spin.
                std::thread::sleep(Duration::from_millis(20));
            }
            Err(_) => {
                if let Some(status) = child.try_wait().ok().flatten() {
                    exit = Some(status);
                    break None;
                }
                let mut descriptor = libc::pollfd {
                    fd,
                    events: libc::POLLIN,
                    revents: 0,
                };
                // SAFETY: one valid pollfd, bounded wait.
                unsafe { libc::poll(&mut descriptor, 1, 20) };
            }
        }
    };
    drop(stdout);

    if let Some(failure) = failure {
        terminate(&mut child);
        return Err(failure);
    }
    let status = exit.expect("loop exits with a status when it does not fail");
    let code = status.code().or(status.signal()).unwrap_or(-1);
    if status.code().is_none() || !accepted_exit_codes.contains(&code) {
        return Err(RunFailure::ExitCode(code));
    }
    Ok(String::from_utf8_lossy(&output).into_owned())
}

/// SIGTERM, then SIGKILL if it is ignored, and reap either way.
pub fn terminate(child: &mut Child) {
    if child.try_wait().ok().flatten().is_some() {
        return;
    }
    // SAFETY: signalling our own child by pid.
    unsafe { libc::kill(child.id() as libc::pid_t, libc::SIGTERM) };
    let until = Instant::now() + Duration::from_millis(200);
    while Instant::now() < until {
        if child.try_wait().ok().flatten().is_some() {
            return;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let _ = child.kill();
    let _ = child.wait();
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

    const T: Duration = Duration::from_secs(5);

    fn sh(script: &str, accepted: &[i32]) -> Result<String, RunFailure> {
        run("/bin/sh", &["-c", script], None, T, accepted, &|| false)
    }

    #[test]
    fn nonzero_exit_is_failure_even_with_output() {
        for code in [1, 2, 127] {
            let result = sh(&format!("printf expected; exit {code}"), &[0]);
            assert_eq!(result, Err(RunFailure::ExitCode(code)));
        }
    }

    #[test]
    fn explicitly_accepted_exit_codes_preserve_output() {
        for code in [0, 1] {
            assert_eq!(
                sh(&format!("printf expected; exit {code}"), &[0, 1]),
                Ok("expected".into())
            );
        }
    }

    #[test]
    fn signal_termination_is_failure_even_when_its_status_is_accepted() {
        assert_eq!(
            sh("printf expected; kill -HUP $$", &[0, 1]),
            Err(RunFailure::ExitCode(1))
        );
    }

    #[test]
    fn timeout_terminates_process_that_ignores_term() {
        let start = Instant::now();
        let result = run(
            "/bin/sh",
            &["-c", "trap '' TERM; sleep 5"],
            None,
            Duration::from_millis(200),
            &[0],
            &|| false,
        );
        assert_eq!(result, Err(RunFailure::TimedOut));
        assert!(start.elapsed() < Duration::from_millis(1500));
    }

    #[test]
    fn cancelled_command_is_not_launched() {
        let result = run("/bin/sh", &["-c", "exit 0"], None, T, &[0], &|| true);
        assert_eq!(result, Err(RunFailure::Cancelled));
    }

    #[test]
    fn cancellation_terminates_running_process_that_ignores_term() {
        let cancelled = Arc::new(AtomicBool::new(false));
        let flag = cancelled.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(150));
            flag.store(true, Ordering::SeqCst);
        });
        let start = Instant::now();
        let result = run(
            "/bin/sh",
            &["-c", "trap '' TERM; sleep 5"],
            None,
            T,
            &[0],
            &|| cancelled.load(Ordering::SeqCst),
        );
        assert_eq!(result, Err(RunFailure::Cancelled));
        assert!(start.elapsed() < Duration::from_millis(1500));
    }

    #[test]
    fn descendant_holding_stdout_does_not_block_completed_command() {
        let start = Instant::now();
        assert_eq!(sh("(sleep 3) & printf done", &[0]), Ok("done".into()));
        assert!(start.elapsed() < Duration::from_millis(800));
    }

    #[test]
    fn inherited_path_does_not_consult_login_shell() {
        let probes = Arc::new(AtomicUsize::new(0));
        let counter = probes.clone();
        let env: Env = [("PATH".to_string(), "/bin:/usr/bin".to_string())].into();
        let resolver = Resolver::new(env, vec![], move || {
            counter.fetch_add(1, Ordering::SeqCst);
            vec![]
        });
        let resolution = resolver.resolve("sh").unwrap();
        assert_eq!(resolution.path, "/bin/sh");
        assert_eq!(resolution.environment["PATH"], "/bin:/usr/bin");
        assert_eq!(probes.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn login_shell_path_is_consulted_when_the_usual_search_misses() {
        let dir = std::env::temp_dir().join(format!("llm-usage-cli-{}", std::process::id()));
        let login = dir.join("login");
        std::fs::create_dir_all(&login).unwrap();
        let file = login.join("fixture-cli");
        std::fs::write(&file, "#!/bin/sh\nprintf expected\n").unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o755)).unwrap();
        let login_path = login.to_string_lossy().into_owned();
        let shell_dirs = vec![login_path.clone()];
        let env: Env = [("PATH".to_string(), "/usr/bin:/bin".to_string())].into();
        // Not on the inherited PATH, so only the login shell can find it.
        let resolver = Resolver::new(env, vec![], move || shell_dirs.clone());
        let resolution = resolver.resolve("fixture-cli").unwrap();
        let output = run(
            &resolution.path,
            &[],
            Some(&resolution.environment),
            T,
            &[0],
            &|| false,
        );
        assert_eq!(output, Ok("expected".into()));
        assert_eq!(
            resolution.environment["PATH"].split(':').next(),
            Some(login_path.as_str())
        );
        let _ = std::fs::remove_dir_all(dir);
    }
}
