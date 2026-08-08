// Ubuntu Public Shield — desktop backend.
//
// The desktop app is the only "mover": it reaches each server over the OS SSH
// client (keys stay in ssh-agent — we never hold raw key material) to read the
// agent's state and to run confirmed actions. Servers open no port.
use std::fs;
use std::path::PathBuf;
use std::process::Command;

use serde::{Deserialize, Serialize};
use tauri::Manager;

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
    "rebaseline-drift.sh",
    "run-webshell-scan.sh",
    "run-lynis-audit.sh",
];

fn config_path(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    let dir = app.path().app_config_dir().map_err(|e| e.to_string())?;
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    Ok(dir.join("servers.json"))
}

fn load(app: &tauri::AppHandle) -> Vec<Server> {
    match config_path(app) {
        Ok(p) => fs::read_to_string(p)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default(),
        Err(_) => Vec::new(),
    }
}

fn save(app: &tauri::AppHandle, servers: &[Server]) -> Result<(), String> {
    let p = config_path(app)?;
    let json = serde_json::to_string_pretty(servers).map_err(|e| e.to_string())?;
    fs::write(p, json).map_err(|e| e.to_string())
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
    let target = format!("{}@{}", server.user, server.host);
    let output = Command::new("ssh")
        .args(["-o", "BatchMode=yes"])
        .args(["-o", "ConnectTimeout=10"])
        .args(["-o", "StrictHostKeyChecking=accept-new"])
        .args(["-p", &server.port.to_string()])
        .arg(&target)
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
    if server.name.trim().is_empty() || server.host.trim().is_empty() || server.user.trim().is_empty() {
        return Err("name, host and user are required".into());
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
    serde_json::from_str(&out).map_err(|e| format!("agent state was not valid JSON: {e}"))
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
    serde_json::from_str(&out).map_err(|e| format!("action did not return valid JSON: {e}"))
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
            run_action
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
