// Ubuntu Public Shield — desktop backend.
//
// The desktop app is the only "mover": it reaches each server over the OS SSH
// client (keys stay in ssh-agent — we never hold raw key material) to read the
// agent's state and to run confirmed actions. Servers open no port.
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use tauri::Manager;

// Serializes read-modify-write access to servers.json so two concurrent Tauri
// command invocations can't clobber each other's write.
static CONFIG_LOCK: Mutex<()> = Mutex::new(());

#[derive(Serialize, Deserialize, Clone)]
struct Server {
    name: String,
    host: String,
    user: String,
    #[serde(default = "default_port")]
    port: u16,
}
fn default_port() -> u16 {
    22
}

// Only these action scripts may be invoked — a fixed allowlist so a bad value
// can never be interpolated into a remote command.
const ACTIONS: &[&str] = &[
    "apply-security-updates.sh",
    "run-webshell-scan.sh",
    "run-lynis-audit.sh",
];

// host/user become part of an ssh argv element (`user@host`). A value starting
// with '-' would be parsed by ssh as an OPTION (e.g. -oProxyCommand=…), which is
// remote-code-exec on the operator's machine — so reject leading '-' and any
// character outside a conservative hostname/username set (blocks spaces and
// shell/ssh metacharacters). This guards typed input AND a tampered servers.json.
fn valid_field(s: &str) -> bool {
    let s = s.trim();
    !s.is_empty()
        && !s.starts_with('-')
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_' | ':'))
}

// Wrap a value as a single-quoted shell token (escaping embedded single quotes)
// so it passes through the remote shell as one literal argument, never parsed.
fn sh_squote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('\'');
    for c in s.chars() {
        if c == '\'' {
            out.push_str("'\\''");
        } else {
            out.push(c);
        }
    }
    out.push('\'');
    out
}

fn config_path(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    let dir = app.path().app_config_dir().map_err(|e| e.to_string())?;
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    Ok(dir.join("servers.json"))
}

fn load(app: &tauri::AppHandle) -> Vec<Server> {
    let p = match config_path(app) {
        Ok(p) => p,
        Err(_) => return Vec::new(),
    };
    let s = match fs::read_to_string(&p) {
        Ok(s) => s,
        Err(_) => return Vec::new(), // absent == empty fleet, which is fine
    };
    match serde_json::from_str(&s) {
        Ok(v) => v,
        Err(_) => {
            // Never silently discard a present-but-unparseable file — back it up
            // so a later save() can't erase a recoverable server list.
            let ts = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_millis())
                .unwrap_or(0);
            let _ = fs::rename(&p, p.with_extension(format!("corrupt-{ts}.json")));
            eprintln!("servers.json was unparseable; backed up and starting with an empty list");
            Vec::new()
        }
    }
}

// Atomic write: serialize to a temp file in the same dir, then rename over the
// target (rename is atomic within a filesystem), so a crash mid-write can never
// leave a truncated servers.json.
fn save(app: &tauri::AppHandle, servers: &[Server]) -> Result<(), String> {
    let p = config_path(app)?;
    let tmp = p.with_extension("json.tmp");
    let json = serde_json::to_string_pretty(servers).map_err(|e| e.to_string())?;
    fs::write(&tmp, json).map_err(|e| e.to_string())?;
    fs::rename(&tmp, &p).map_err(|e| e.to_string())
}

fn find_server(app: &tauri::AppHandle, name: &str) -> Result<Server, String> {
    load(app)
        .into_iter()
        .find(|s| s.name == name)
        .ok_or_else(|| format!("no such server: {name}"))
}

// Run a fixed command on the server over SSH. `remote_cmd` is always built from
// constants + allowlisted values, never free-form user input.
fn ssh_run(server: &Server, remote_cmd: &str) -> Result<String, String> {
    if !valid_field(&server.user) || !valid_field(&server.host) {
        return Err("server user/host contains invalid characters".into());
    }
    let target = format!("{}@{}", server.user, server.host);
    let output = Command::new("ssh")
        .args(["-o", "BatchMode=yes"])
        .args(["-o", "ConnectTimeout=10"])
        .args(["-o", "StrictHostKeyChecking=accept-new"])
        .args(["-p", &server.port.to_string()])
        .arg(&target) // safe: valid_field() rejects a leading '-' so this can't be an option
        .arg(remote_cmd)
        .output()
        .map_err(|e| format!("failed to launch ssh (is the OpenSSH client installed?): {e}"))?;

    if !output.status.success() {
        let err = String::from_utf8_lossy(&output.stderr);
        return Err(format!("ssh to {target} failed: {}", err.trim()));
    }
    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

#[tauri::command]
fn list_servers(app: tauri::AppHandle) -> Vec<Server> {
    load(&app)
}

#[tauri::command]
fn add_server(app: tauri::AppHandle, server: Server) -> Result<Vec<Server>, String> {
    let _guard = CONFIG_LOCK.lock().map_err(|_| "config lock poisoned")?;
    if server.name.trim().is_empty() {
        return Err("name is required".into());
    }
    if !valid_field(&server.host) {
        return Err("host contains invalid characters (letters, digits, . - _ : only)".into());
    }
    if !valid_field(&server.user) {
        return Err("ssh user contains invalid characters (letters, digits, . - _ only)".into());
    }
    let mut servers = load(&app);
    if servers.iter().any(|s| s.name == server.name) {
        return Err(format!("a server named '{}' already exists", server.name));
    }
    servers.push(server);
    save(&app, &servers)?;
    Ok(servers)
}

#[tauri::command]
fn remove_server(app: tauri::AppHandle, name: String) -> Result<Vec<Server>, String> {
    let _guard = CONFIG_LOCK.lock().map_err(|_| "config lock poisoned")?;
    let mut servers = load(&app);
    servers.retain(|s| s.name != name);
    save(&app, &servers)?;
    Ok(servers)
}

// Read the agent's state document. latest.json is world-readable, so no sudo.
#[tauri::command]
fn fetch_state(app: tauri::AppHandle, name: String) -> Result<serde_json::Value, String> {
    let server = find_server(&app, &name)?;
    let out = ssh_run(&server, "cat /var/lib/shield/state/latest.json")?;
    parse_json_lenient(&out).map_err(|e| format!("agent state was not valid JSON: {e}"))
}

// Run a confirmed action. `apply=false` previews (read-only); `apply=true`
// performs the change. The action must be on the allowlist.
#[tauri::command]
fn run_action(
    app: tauri::AppHandle,
    name: String,
    action: String,
    apply: bool,
) -> Result<serde_json::Value, String> {
    if !ACTIONS.contains(&action.as_str()) {
        return Err(format!("unknown action: {action}"));
    }
    let server = find_server(&app, &name)?;
    let flag = if apply { "--apply" } else { "--preview" };
    let cmd = format!("sudo -n /opt/shield/actions/{action} {flag}");
    let out = ssh_run(&server, &cmd)?;
    parse_json_lenient(&out).map_err(|e| format!("action did not return valid JSON: {e}"))
}

// Acknowledge one persistence-drift item: confirm it as yours (folds into the
// trusted baseline so it stops alarming) or flag it suspicious (stays visible,
// logged). The fingerprint is validated to a known kind and single-quoted for
// the remote shell; verdict is allowlisted. Replaces blanket accept-all.
#[tauri::command]
fn acknowledge_drift(
    app: tauri::AppHandle,
    name: String,
    fp: String,
    verdict: String,
    apply: bool,
) -> Result<serde_json::Value, String> {
    if verdict != "mine" && verdict != "suspicious" {
        return Err("verdict must be 'mine' or 'suspicious'".into());
    }
    const KINDS: &[&str] = &["authkey:", "cron:", "usercron:", "unit:", "suid:"];
    if !KINDS.iter().any(|k| fp.starts_with(k)) {
        return Err("invalid drift fingerprint".into());
    }
    let server = find_server(&app, &name)?;
    let flag = if apply { "--apply" } else { "--preview" };
    let cmd = format!(
        "sudo -n /opt/shield/actions/acknowledge-drift.sh --fp {} --verdict {} {}",
        sh_squote(&fp),
        verdict,
        flag
    );
    let out = ssh_run(&server, &cmd)?;
    parse_json_lenient(&out).map_err(|e| format!("action did not return valid JSON: {e}"))
}

// Some SSH sessions prepend a shell/MOTD banner to stdout even for a single
// remote command. Extract the JSON object (first '{' … last '}') before parsing
// so a benign banner doesn't break an otherwise-valid document.
fn parse_json_lenient(out: &str) -> Result<serde_json::Value, serde_json::Error> {
    let slice = match (out.find('{'), out.rfind('}')) {
        (Some(a), Some(b)) if b >= a => &out[a..=b],
        _ => out,
    };
    serde_json::from_str(slice)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            list_servers,
            add_server,
            remove_server,
            fetch_state,
            run_action,
            acknowledge_drift
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_off_allowlist_action() {
        assert!(!ACTIONS.contains(&"rm-rf.sh"));
        assert!(!ACTIONS.contains(&"apply-security-updates.sh; rm -rf /"));
        assert!(ACTIONS.contains(&"apply-security-updates.sh"));
    }

    #[test]
    fn sh_squote_neutralizes_shell_metachars() {
        assert_eq!(sh_squote("authkey:/a/b:hash"), "'authkey:/a/b:hash'");
        // an embedded single quote is closed, escaped, and reopened
        assert_eq!(sh_squote("a'b"), "'a'\\''b'");
        // a command-injection attempt stays inside the quotes as literal text
        assert_eq!(sh_squote("x; rm -rf /"), "'x; rm -rf /'");
        assert_eq!(sh_squote("$(id)"), "'$(id)'");
    }

    #[test]
    fn valid_field_blocks_ssh_option_injection() {
        assert!(!valid_field("-oProxyCommand=touch /tmp/x"));
        assert!(!valid_field("")); // empty
        assert!(!valid_field("a b")); // space
        assert!(!valid_field("a;b")); // shell metachar
        assert!(!valid_field("$(id)"));
        assert!(valid_field("web01.example.com"));
        assert!(valid_field("root"));
        assert!(valid_field("2001:db8::1"));
    }

    #[test]
    fn parse_json_lenient_strips_banner() {
        let v = parse_json_lenient("MOTD: welcome\n{\"a\":1}\n").unwrap();
        assert_eq!(v["a"], 1);
    }
}
