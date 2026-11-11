//! Banc d'essai partagé des tests d'intégration de Baluchon.
//!
//! Ce que les tests lancent, c'est un VRAI binaire contre un faux serveur HTTP
//! local (tiny_http), un HOME jetable et, sous macOS, un trousseau TEMPORAIRE.
//!
//! Garde-fous (identiques pour tout binaire lancé par ce banc) :
//! - l'environnement du binaire est vidé (`env_clear`) puis reconstruit : aucun
//!   jeton, HOME ni Trousseau réel n'est atteignable ;
//! - `CCP_API_BASE` / `CCP_TOKEN_URL` pointent vers 127.0.0.1 (seules valeurs
//!   acceptées par le binaire ; le noyau public ne lit pas `CCP_TOKEN_URL`, seules les
//!   éditions qui renouvellent la lisent) ;
//! - les essais Trousseau passent TOUS par `CCP_KEYCHAIN=<fichier temporaire>`,
//!   détruit en fin de test ; le Trousseau par défaut n'est jamais ouvert ;
//! - tout jeton fabriqué ici est factice.

use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

// ------------------------------------------------------------- faux serveur

#[derive(Clone, Debug)]
pub struct Hit {
    pub method: String,
    pub path: String,
    pub bearer: Option<String>,
}

type Handler = dyn Fn(&Hit, usize) -> (u16, String) + Send + Sync;

pub struct Fake {
    server: Arc<tiny_http::Server>,
    hits: Arc<Mutex<Vec<Hit>>>,
    join: Option<JoinHandle<()>>,
    port: u16,
}

impl Fake {
    /// `handler(requête, rang de cette requête dans la même route)`.
    pub fn start(handler: impl Fn(&Hit, usize) -> (u16, String) + Send + Sync + 'static) -> Fake {
        let server = Arc::new(tiny_http::Server::http("127.0.0.1:0").expect("port local"));
        let port = server.server_addr().to_ip().expect("adresse IP").port();
        let hits: Arc<Mutex<Vec<Hit>>> = Arc::new(Mutex::new(vec![]));
        let handler: Arc<Handler> = Arc::new(handler);
        let (s2, h2) = (server.clone(), hits.clone());
        let join = std::thread::spawn(move || {
            for mut req in s2.incoming_requests() {
                let mut body = String::new();
                let _ = req.as_reader().read_to_string(&mut body);
                let bearer = req
                    .headers()
                    .iter()
                    .find(|h| h.field.equiv("authorization"))
                    .map(|h| h.value.as_str().trim_start_matches("Bearer ").to_string());
                let hit = Hit {
                    method: req.method().as_str().to_string(),
                    path: req.url().split('?').next().unwrap_or("").to_string(),
                    bearer,
                };
                let rank = {
                    let mut g = h2.lock().unwrap();
                    let n = g
                        .iter()
                        .filter(|x| x.method == hit.method && x.path == hit.path)
                        .count();
                    g.push(hit.clone());
                    n
                };
                let (code, out) = handler(&hit, rank);
                let resp = tiny_http::Response::from_string(out)
                    .with_status_code(code)
                    .with_header(
                        tiny_http::Header::from_bytes("Content-Type", "application/json").unwrap(),
                    );
                let _ = req.respond(resp);
            }
        });
        Fake {
            server,
            hits,
            join: Some(join),
            port,
        }
    }

    pub fn api(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }

    pub fn token_url(&self) -> String {
        format!("http://127.0.0.1:{}/token", self.port)
    }

    pub fn count(&self, method: &str, path: &str) -> usize {
        self.hits
            .lock()
            .unwrap()
            .iter()
            .filter(|h| h.method == method && h.path == path)
            .count()
    }

    pub fn token_hits(&self) -> usize {
        self.count("POST", "/token")
    }

    /// Nombre total de requêtes reçues, toutes routes confondues.
    pub fn total(&self) -> usize {
        self.hits.lock().unwrap().len()
    }

    pub fn bearers(&self, path: &str) -> Vec<Option<String>> {
        self.hits
            .lock()
            .unwrap()
            .iter()
            .filter(|h| h.path == path)
            .map(|h| h.bearer.clone())
            .collect()
    }
}

impl Drop for Fake {
    fn drop(&mut self) {
        self.server.unblock();
        if let Some(j) = self.join.take() {
            let _ = j.join();
        }
    }
}

pub const PROFILE_OK: &str = r#"{"account":{"uuid":"u","email":"eve@x.fr","has_claude_max":true,"has_claude_pro":false},"organization":{"rate_limit_tier":"default_claude_max_20x"}}"#;
pub const USAGE_OK: &str = r#"{"five_hour":{"utilization":12.7,"resets_at":"2099-11-09T04:00:00+00:00"},"seven_day":{"utilization":40.0,"resets_at":"2099-11-12T10:00:00Z"},"seven_day_sonnet":{"utilization":3.0,"resets_at":"2099-11-12T10:00:00Z"}}"#;
pub const RENEWED: &str =
    r#"{"access_token":"NEW-AT","refresh_token":"NEW-RT","expires_in":28800}"#;

/// Serveur sain : profil, quotas, renouvellement qui réussit.
pub fn healthy(h: &Hit, _rank: usize) -> (u16, String) {
    match (h.method.as_str(), h.path.as_str()) {
        ("GET", "/api/oauth/profile") => (200, PROFILE_OK.into()),
        ("GET", "/api/oauth/usage") => (200, USAGE_OK.into()),
        ("POST", "/token") => (200, RENEWED.into()),
        _ => (404, "{}".into()),
    }
}

// ----------------------------------------------------------------- bac à sable

/// HOME + racine portable jetables, et le binaire à lancer (paramètre : le même banc
/// sert au noyau public et, plus tard, à la couche privée).
pub struct Sandbox {
    _t: tempfile::TempDir,
    bin: &'static str,
    pub home: PathBuf,
    pub root: String,
    pub keychain: Option<PathBuf>,
}

pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

/// Magasin de login : jetons factices, clés inconnues à préserver.
pub fn creds_json(access: &str, refresh: &str, expires_ms: i64, padding: usize) -> String {
    json!({
        "claudeAiOauth": {
            "accessToken": access,
            "refreshToken": refresh,
            "expiresAt": expires_ms,
            "scopes": ["user:inference", "user:profile"],
            "subscriptionType": "max",
            "rateLimitTier": "default_claude_max_20x",
            "extraInconnu": {"a": [1, 2, 3]}
        },
        "mcpOAuth": {"srv|abc": {"accessToken": "MCPTOK", "pad": "x".repeat(padding)}},
        "autreCle": 42
    })
    .to_string()
}

impl Sandbox {
    /// `bin` : chemin du binaire à lancer (`env!("CARGO_BIN_EXE_...")` chez l'appelant).
    pub fn new(bin: &'static str) -> Sandbox {
        let t = tempfile::tempdir().unwrap();
        let home = t.path().join("home");
        let root = t.path().join("portable");
        std::fs::create_dir_all(&home).unwrap();
        std::fs::create_dir_all(root.join("config")).unwrap();
        Sandbox {
            home,
            root: root.to_string_lossy().into_owned(),
            keychain: None,
            bin,
            _t: t,
        }
    }

    pub fn profile_dir(&self, name: &str) -> PathBuf {
        let d = Path::new(&self.root).join("config").join(name);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    /// Chaîne exacte que le noyau donnerait à `CLAUDE_CONFIG_DIR`.
    #[cfg_attr(not(any(unix, target_os = "macos")), allow(dead_code))]
    pub fn cfg(&self, name: &str) -> String {
        format!("{}/config/{name}", self.root)
    }

    pub fn put_file_login(&self, name: &str, json: &str) {
        std::fs::write(self.profile_dir(name).join(".credentials.json"), json).unwrap();
    }

    pub fn read_file_login(&self, name: &str) -> Value {
        let s = std::fs::read_to_string(self.profile_dir(name).join(".credentials.json")).unwrap();
        serde_json::from_str(&s).unwrap()
    }

    pub fn journal(&self, name: &str) -> PathBuf {
        self.profile_dir(name).join(".ccp-pending")
    }

    pub fn cmd(&self, fake: Option<&Fake>) -> Command {
        let mut c = Command::new(self.bin);
        c.env_clear()
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .env("HOME", &self.home)
            .env("USER", "testeur")
            .env("NO_COLOR", "1")
            .env("CCP_CLAUDE_BIN", "/nonexistent/claude");
        if let Some(f) = fake {
            c.env("CCP_API_BASE", f.api())
                .env("CCP_TOKEN_URL", f.token_url());
        } else {
            // Aucune requête réseau ne doit partir : port fermé.
            c.env("CCP_API_BASE", "http://127.0.0.1:1")
                .env("CCP_TOKEN_URL", "http://127.0.0.1:1/token");
        }
        match &self.keychain {
            Some(k) => {
                c.env("CCP_KEYCHAIN", k);
            }
            None => {
                c.env("CCP_NO_KEYCHAIN", "1");
            }
        }
        c.arg("--root").arg(&self.root);
        c
    }

    pub fn run(&self, fake: Option<&Fake>, args: &[&str]) -> Output {
        self.cmd(fake)
            .args(args)
            .output()
            .expect("lancement du binaire")
    }

    pub fn status_json(&self, fake: &Fake, extra: &[&str]) -> Value {
        let mut args = vec!["accounts", "status", "--format", "json"];
        args.extend_from_slice(extra);
        let o = self.run(Some(fake), &args);
        assert!(
            o.status.success(),
            "status a échoué : {}",
            String::from_utf8_lossy(&o.stderr)
        );
        serde_json::from_slice(&o.stdout).expect("JSON de status")
    }
}

pub fn account<'a>(report: &'a Value, name: &str) -> &'a Value {
    report["accounts"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["name"] == name)
        .unwrap_or_else(|| panic!("compte {name} absent"))
}

/// Attend l'apparition d'un fichier. Plafond dur : `secs` secondes, puis `false`.
pub fn wait_for(path: &Path, secs: u64) -> bool {
    let end = Instant::now() + Duration::from_secs(secs);
    while Instant::now() < end {
        if path.exists() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    false
}

pub fn stdout(o: &Output) -> String {
    String::from_utf8_lossy(&o.stdout).into_owned()
}

pub fn stderr(o: &Output) -> String {
    String::from_utf8_lossy(&o.stderr).into_owned()
}

pub fn code(o: &Output) -> i32 {
    o.status.code().unwrap_or(-1)
}
