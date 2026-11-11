//! Tests d'intégration : le VRAI binaire `baluchon-core` contre un faux serveur HTTP
//! local (tiny_http), un HOME jetable et, sous macOS, un trousseau TEMPORAIRE.
//!
//! Garde-fous de ces tests :
//! - l'environnement du binaire est vidé (`env_clear`) puis reconstruit : aucun
//!   jeton, HOME ni Trousseau réel n'est atteignable ;
//! - `CCP_API_BASE` pointe vers 127.0.0.1 (seule valeur acceptée par le binaire) ;
//!   le banc exporte aussi `CCP_TOKEN_URL` pour les éditions qui renouvellent, le noyau
//!   public ne la lit pas ;
//! - les essais Trousseau passent TOUS par `CCP_KEYCHAIN=<fichier temporaire>`,
//!   détruit en fin de test ; le Trousseau par défaut n'est jamais ouvert.

// Le faux serveur, le bac à sable et les aides vivent dans `core/testkit`
// (partagés avec les tests de la couche privée) ; ici seulement l'enveloppe qui
// fixe le binaire testé, pour que les appels `Sandbox::new()` des tests restent tels quels.
use baluchon_testkit::{
    account, code, creds_json, healthy, now_ms, stderr, stdout, wait_for, Fake,
};
use serde_json::{json, Value};
use std::ops::{Deref, DerefMut};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const BIN: &str = env!("CARGO_BIN_EXE_baluchon-core");

struct Sandbox(baluchon_testkit::Sandbox);

impl Sandbox {
    fn new() -> Sandbox {
        Sandbox(baluchon_testkit::Sandbox::new(BIN))
    }
}

impl Deref for Sandbox {
    type Target = baluchon_testkit::Sandbox;
    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl DerefMut for Sandbox {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.0
    }
}

// ------------------------------------------------------------------ contrat

#[test]
fn contract_and_version() {
    let sb = Sandbox::new();
    let o = sb.run(None, &["--contract"]);
    assert_eq!(code(&o), 0);
    assert_eq!(stdout(&o), "1\n");
    let o = Command::new(BIN).arg("--version").output().unwrap();
    assert_eq!(code(&o), 0);
    assert!(
        stdout(&o).starts_with("baluchon-core "),
        "version : {}",
        stdout(&o)
    );
}

/// Le wizard choisit le noyau d'après `about --json` : le contrat d'interface est testé
/// sur le VRAI binaire (la valeur de `edition` dépend du binaire, pas son existence).
#[test]
fn about_json_gives_name_version_contract_and_edition() {
    let sb = Sandbox::new();
    let o = sb.run(None, &["about", "--json"]);
    assert_eq!(code(&o), 0, "{}", stderr(&o));
    let v: Value = serde_json::from_str(&stdout(&o)).expect("une ligne JSON");
    assert_eq!(v["name"], "baluchon-core");
    assert_eq!(v["version"], env!("CARGO_PKG_VERSION"));
    assert_eq!(v["built_on"], env!("CARGO_PKG_VERSION"));
    assert_eq!(v["contract"], 1);
    assert!(
        v["edition"].as_str().is_some_and(|e| !e.is_empty()),
        "édition : {v}"
    );
    // Sans --json : une ligne lisible.
    let o = sb.run(None, &["about"]);
    assert_eq!(code(&o), 0);
    assert!(stdout(&o).starts_with("baluchon-core "), "{}", stdout(&o));
}

#[test]
fn an_unknown_command_is_a_usage_error_with_its_name() {
    let sb = Sandbox::new();
    let o = sb.run(None, &["frobnicate", "--x"]);
    assert_eq!(code(&o), 2);
    assert!(stderr(&o).contains("frobnicate"), "{}", stderr(&o));
    assert!(stdout(&o).is_empty());
}

#[test]
fn usage_errors_exit_2_and_nothing_found_exits_3() {
    let sb = Sandbox::new();
    assert_eq!(
        code(&sb.run(None, &["accounts", "status", "--format", "xml"])),
        2
    );
    assert_eq!(code(&sb.run(None, &["accounts", "email", "../evil"])), 2);
    assert_eq!(
        code(&sb.run(
            None,
            &["accounts", "discover", "--missing", "--format", "json"]
        )),
        2
    );
    // `best` ne lit que le cache : rien en cache -> 3, sans réseau.
    sb.put_file_login("1", &creds_json("AT", "RT", now_ms() + 3_600_000, 0));
    assert_eq!(code(&sb.run(None, &["accounts", "best"])), 3);
    // email inconnu -> 3
    assert_eq!(code(&sb.run(None, &["accounts", "email", "1"])), 3);
}

// -------------------------------------------------------------------- status

#[test]
fn status_json_schema_1_for_a_healthy_account() {
    let sb = Sandbox::new();
    sb.put_file_login("1", &creds_json("AT-OK", "RT-OK", now_ms() + 3_600_000, 0));
    let fake = Fake::start(healthy);
    let r = sb.status_json(&fake, &["--refresh"]);
    assert_eq!(r["schema"], 1);
    assert_eq!(r["recommended"], "1");
    let a = account(&r, "1");
    assert_eq!(a["state"], "ok");
    assert_eq!(a["usable"], true);
    assert_eq!(a["email"], "eve@x.fr");
    assert_eq!(a["plan"], "Max x20");
    assert_eq!(a["five_hour"]["pct"], 12);
    assert_eq!(a["seven_day"]["pct"], 40);
    assert_eq!(a["seven_day_sonnet"]["pct"], 3);
    assert_eq!(a["store"], "file");
    assert_eq!(a["stale"], false);
    // jeton valide : AUCUN renouvellement
    assert_eq!(fake.token_hits(), 0);
    // le jeton d'accès est celui du magasin
    assert!(fake
        .bearers("/api/oauth/usage")
        .contains(&Some("AT-OK".to_string())));
    // le JSON ne contient aucun jeton
    let raw = serde_json::to_string(&r).unwrap();
    assert!(!raw.contains("AT-OK") && !raw.contains("RT-OK"));
}

#[test]
fn status_table_has_no_box_drawing_and_respects_width() {
    let sb = Sandbox::new();
    sb.put_file_login("1", &creds_json("AT", "RT", now_ms() + 3_600_000, 0));
    let fake = Fake::start(healthy);
    for width in ["60", "100", "140"] {
        let o = sb.run(
            Some(&fake),
            &["accounts", "status", "--refresh", "--width", width],
        );
        assert_eq!(code(&o), 0);
        let out = stdout(&o);
        assert!(out.contains("Max x20"), "forfait absent :\n{out}");
        assert!(out.contains("12 %"), "quota absent :\n{out}");
        let w: usize = width.parse().unwrap();
        for line in out.lines() {
            assert!(
                line.chars().count() <= w,
                "ligne trop large ({w}) : {line:?}"
            );
            assert!(
                !line.chars().any(|c| ('\u{2500}'..='\u{257f}').contains(&c)),
                "caractère de tracé de boîte : {line:?}"
            );
        }
    }
}

#[test]
fn rate_limit_429_keeps_last_good_values_and_flags_the_state() {
    let sb = Sandbox::new();
    sb.put_file_login("1", &creds_json("AT", "RT", now_ms() + 3_600_000, 0));
    let ok = Fake::start(healthy);
    let first = sb.status_json(&ok, &["--refresh"]);
    assert_eq!(account(&first, "1")["state"], "ok");
    drop(ok);

    let limited = Fake::start(|h, _| match h.path.as_str() {
        "/api/oauth/usage" => (429, "{}".into()),
        _ => healthy(h, 0),
    });
    let r = sb.status_json(&limited, &["--refresh"]);
    let a = account(&r, "1");
    assert_eq!(a["state"], "rate_limited");
    assert_eq!(a["state_label"], "Statut limité");
    assert_eq!(a["usable"], true, "un 429 n'est pas un épuisement");
    assert_eq!(a["five_hour"]["pct"], 12, "dernière bonne valeur conservée");
    assert_eq!(a["stale"], true);
    assert_eq!(r["recommended"], "1");
    assert_eq!(
        limited.token_hits(),
        0,
        "un 429 ne déclenche jamais de renouvellement"
    );
}

#[test]
fn long_lived_token_403_is_valid_not_dead() {
    let sb = Sandbox::new();
    let d = sb.profile_dir("jeton");
    std::fs::write(d.join("oauth.token"), "sk-ant-oat01-factice\n").unwrap();
    std::fs::write(d.join("plan"), "Max x20\n").unwrap();
    let fake = Fake::start(|_, _| (403, "{}".into()));
    let r = sb.status_json(&fake, &["--refresh"]);
    let a = account(&r, "jeton");
    assert_eq!(a["state"], "token_long");
    assert_eq!(a["plan"], "Max x20 (déclaré)");
    assert_eq!(a["plan_declared"], true);
    assert_eq!(fake.token_hits(), 0);
}

#[test]
fn long_lived_token_401_is_dead() {
    let sb = Sandbox::new();
    let d = sb.profile_dir("jeton");
    std::fs::write(d.join("oauth.token"), "sk-ant-oat01-mort").unwrap();
    let fake = Fake::start(|_, _| (401, "{}".into()));
    let r = sb.status_json(&fake, &["--refresh"]);
    assert_ne!(account(&r, "jeton")["state"], "ok");
    assert_eq!(
        fake.token_hits(),
        0,
        "un jeton longue durée ne se renouvelle pas"
    );
}

#[test]
fn profile_without_login_is_not_connected_and_makes_no_request() {
    let sb = Sandbox::new();
    sb.profile_dir("vide");
    let fake = Fake::start(healthy);
    let r = sb.status_json(&fake, &["--refresh"]);
    assert_eq!(account(&r, "vide")["state"], "not_connected");
    assert_eq!(
        fake.count("GET", "/api/oauth/profile") + fake.count("GET", "/api/oauth/usage"),
        0
    );
}

#[test]
fn network_down_is_unreachable_exit_4_when_everything_is_down() {
    let sb = Sandbox::new();
    sb.put_file_login("1", &creds_json("AT", "RT", now_ms() + 3_600_000, 0));
    // sans faux serveur : 127.0.0.1:1 refuse la connexion
    let o = sb.run(
        None,
        &["accounts", "status", "--refresh", "--format", "json"],
    );
    assert_eq!(code(&o), 4, "stderr : {}", stderr(&o));
    let r: Value = serde_json::from_slice(&o.stdout).unwrap();
    assert_eq!(account(&r, "1")["state"], "unreachable");
}

#[test]
fn offline_and_best_use_the_cache_without_network() {
    let sb = Sandbox::new();
    sb.put_file_login("1", &creds_json("AT", "RT", now_ms() + 3_600_000, 0));
    {
        let fake = Fake::start(healthy);
        sb.status_json(&fake, &["--refresh"]);
    }
    // plus aucun serveur : --offline et best répondent depuis le cache
    let o = sb.run(
        None,
        &["accounts", "status", "--offline", "--format", "json"],
    );
    assert_eq!(code(&o), 0, "{}", stderr(&o));
    let r: Value = serde_json::from_slice(&o.stdout).unwrap();
    assert_eq!(account(&r, "1")["state"], "ok");
    assert_eq!(account(&r, "1")["five_hour"]["pct"], 12);
    let b = sb.run(None, &["accounts", "best"]);
    assert_eq!(code(&b), 0);
    assert_eq!(stdout(&b), "1\n");
}

#[test]
fn best_picks_the_valid_account_with_the_most_margin() {
    let sb = Sandbox::new();
    for n in ["1", "2", "3"] {
        sb.put_file_login(
            n,
            &creds_json(
                &format!("AT-{n}"),
                &format!("RT-{n}"),
                now_ms() + 3_600_000,
                0,
            ),
        );
    }
    // 1 : 90 % de 5 h ; 2 : 10 % ; 3 : limité (100 %)
    let fake = Fake::start(|h, _| {
        if h.path == "/api/oauth/usage" {
            let pct = match h.bearer.as_deref() {
                Some("AT-1") => 90.0,
                Some("AT-2") => 10.0,
                _ => 100.0,
            };
            return (
                200,
                json!({"five_hour": {"utilization": pct, "resets_at": "2099-11-09T04:00:00Z"},
                       "seven_day": {"utilization": pct, "resets_at": "2099-11-12T10:00:00Z"}})
                .to_string(),
            );
        }
        healthy(h, 0)
    });
    let r = sb.status_json(&fake, &["--refresh"]);
    assert_eq!(account(&r, "3")["state"], "limited");
    assert_eq!(r["recommended"], "2");
    let b = sb.run(None, &["accounts", "best"]);
    assert_eq!(stdout(&b), "2\n");
}

// --------------------------------------------------------------------- discover

#[test]
fn discover_lists_machine_logins_read_only_and_missing_prints_emails_only() {
    let sb = Sandbox::new();
    // login de la machine
    let machine = sb.home.join(".claude");
    std::fs::create_dir_all(&machine).unwrap();
    std::fs::write(
        machine.join(".credentials.json"),
        creds_json("AT", "RT", now_ms() + 3_600_000, 0),
    )
    .unwrap();
    std::fs::write(
        sb.home.join(".claude.json"),
        r#"{"oauthAccount":{"emailAddress":"contact@example-ab.com"}}"#,
    )
    .unwrap();
    // un profil ancien (expiré) et un profil vide
    let old = sb.home.join(".claude-profiles/primary");
    std::fs::create_dir_all(&old).unwrap();
    std::fs::write(
        old.join(".credentials.json"),
        creds_json("AT", "RT", 1_000, 0),
    )
    .unwrap();
    std::fs::write(
        old.join(".claude.json"),
        r#"{"oauthAccount":{"emailAddress":"primary@x.fr"}}"#,
    )
    .unwrap();
    let empty = sb.home.join(".claude-profiles/secondary");
    std::fs::create_dir_all(&empty).unwrap();

    let before = tree(&sb.home);
    let o = sb.run(None, &["accounts", "discover", "--width", "100"]);
    assert_eq!(code(&o), 0, "{}", stderr(&o));
    let t = stdout(&o);
    assert!(
        t.contains("contact@example-ab.com") && t.contains("Max x20"),
        "{t}"
    );
    assert!(t.contains("aucun identifiant"), "{t}");
    for line in t.lines() {
        assert!(line.chars().count() <= 100, "ligne trop large : {line:?}");
    }

    let m = sb.run(None, &["accounts", "discover", "--missing"]);
    assert_eq!(code(&m), 0);
    // stdout : UN email par ligne et rien d'autre ; le login sans email passe par stderr
    let lines: Vec<String> = stdout(&m).lines().map(str::to_string).collect();
    assert_eq!(lines, ["contact@example-ab.com", "primary@x.fr"]);
    assert!(stderr(&m).contains("secondary"), "{}", stderr(&m));

    let j = sb.run(None, &["accounts", "discover", "--format", "json"]);
    let v: Value = serde_json::from_slice(&j.stdout).unwrap();
    assert_eq!(v["schema"], 1);
    assert!(v["logins"].as_array().unwrap().len() >= 3);
    assert!(
        !String::from_utf8_lossy(&j.stdout).contains("\"RT\""),
        "aucun jeton dans le JSON"
    );

    assert_eq!(before, tree(&sb.home), "discover n'écrit rien");
}

fn tree(dir: &Path) -> Vec<String> {
    let mut out = vec![];
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        for e in std::fs::read_dir(&d).into_iter().flatten().flatten() {
            let p = e.path();
            if p.is_dir() {
                stack.push(p);
            } else {
                let m = std::fs::metadata(&p).unwrap();
                out.push(format!("{} {}", p.display(), m.len()));
            }
        }
    }
    out.sort();
    out
}

// -------------------------------------------------------------------------- run

#[cfg(unix)]
fn fake_claude(sb: &Sandbox, body: &str) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let n = std::fs::read_dir(&sb.home).unwrap().count();
    let p = sb.home.join(format!("claude-faux-{n}"));
    std::fs::write(&p, format!("#!/bin/sh\n{body}")).unwrap();
    std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
    p
}

#[cfg(unix)]
#[test]
fn run_sets_the_environment_propagates_the_exit_code_and_probes_after() {
    let sb = Sandbox::new();
    sb.put_file_login("1", &creds_json("AT", "RT", now_ms() + 3_600_000, 0));
    let out = sb.home.join("env.txt");
    let claude = fake_claude(
        &sb,
        &format!(
            "{{ echo \"cfg=$CLAUDE_CONFIG_DIR\"; echo \"upd=$DISABLE_AUTOUPDATER\"; echo \"tok=${{CLAUDE_CODE_OAUTH_TOKEN:-absent}}\"; echo \"args=$*\"; }} > '{}'\nexit 7\n",
            out.display()
        ),
    );
    let fake = Fake::start(healthy);
    let o = sb
        .cmd(Some(&fake))
        // un jeton hérité de l'environnement ne doit pas atteindre un profil à login
        .env("CLAUDE_CODE_OAUTH_TOKEN", "HERITE")
        .args([
            "run",
            "1",
            "--claude",
            claude.to_str().unwrap(),
            "--",
            "--resume",
            "x y",
        ])
        .output()
        .unwrap();
    assert_eq!(
        code(&o),
        7,
        "le code de Claude est propagé : {}",
        stderr(&o)
    );
    let seen = std::fs::read_to_string(&out).unwrap();
    assert!(seen.contains(&format!("cfg={}\n", sb.cfg("1"))), "{seen}");
    assert!(seen.contains("upd=1"));
    assert!(seen.contains("tok=absent"), "{seen}");
    assert!(seen.contains("args=--resume x y"));
    // sonde rapide après la session
    assert!(fake.count("GET", "/api/oauth/usage") >= 1);
}

#[cfg(unix)]
#[test]
fn run_gives_the_long_lived_token_only_to_token_only_profiles() {
    let sb = Sandbox::new();
    std::fs::write(
        sb.profile_dir("jeton").join("oauth.token"),
        "sk-ant-oat01-LONG\n",
    )
    .unwrap();
    let out = sb.home.join("tok.txt");
    let claude = fake_claude(
        &sb,
        &format!(
            "echo \"${{CLAUDE_CODE_OAUTH_TOKEN:-absent}}\" > '{}'\n",
            out.display()
        ),
    );
    let fake = Fake::start(|_, _| (403, "{}".into()));
    let o = sb.run(
        Some(&fake),
        &["run", "jeton", "--claude", claude.to_str().unwrap()],
    );
    assert_eq!(code(&o), 0, "{}", stderr(&o));
    assert_eq!(
        std::fs::read_to_string(&out).unwrap().trim(),
        "sk-ant-oat01-LONG"
    );

    // même profil, mais avec un login : le jeton n'est plus transmis
    sb.put_file_login("jeton", &creds_json("AT", "RT", now_ms() + 3_600_000, 0));
    let o = sb.run(
        Some(&fake),
        &["run", "jeton", "--claude", claude.to_str().unwrap()],
    );
    assert_eq!(code(&o), 0);
    assert_eq!(std::fs::read_to_string(&out).unwrap().trim(), "absent");
}

#[cfg(unix)]
#[test]
fn a_second_run_on_an_open_profile_exits_5() {
    let sb = Sandbox::new();
    sb.put_file_login("1", &creds_json("AT", "RT", now_ms() + 3_600_000, 0));
    let started = sb.home.join("demarre");
    let release = sb.home.join("fin");
    let claude = fake_claude(
        &sb,
        &format!(
            "touch '{}'\nwhile [ ! -e '{}' ]; do sleep 0.05; done\nexit 0\n",
            started.display(),
            release.display()
        ),
    );
    let fake = Fake::start(healthy);
    let first = sb
        .cmd(Some(&fake))
        .args(["run", "1", "--claude", claude.to_str().unwrap()])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    assert!(wait_for(&started, 10));

    let second = sb.run(
        Some(&fake),
        &["run", "1", "--claude", claude.to_str().unwrap()],
    );
    assert_eq!(code(&second), 5, "{}", stderr(&second));
    assert!(stderr(&second).contains("déjà ouvert"));

    // pendant la session : un renouvellement ne peut pas se faire (verrou tenu)
    let st = sb.status_json(&fake, &["--refresh"]);
    assert_eq!(account(&st, "1")["running"], true);

    std::fs::write(&release, "").unwrap();
    let o = first.wait_with_output().unwrap();
    assert_eq!(code(&o), 0);
}

#[cfg(unix)]
#[test]
fn run_restores_sigint_for_claude_even_when_the_wizard_ignores_it() {
    let sb = Sandbox::new();
    sb.put_file_login("1", &creds_json("AT", "RT", now_ms() + 3_600_000, 0));
    // Claude (faux) s'envoie SIGINT : avec SIGINT hérité « ignoré » il survivrait.
    let claude = fake_claude(&sb, "kill -INT $$\nsleep 2\nexit 0\n");
    let fake = Fake::start(healthy);
    // `trap '' INT` comme le wizard bash, puis exec : SIG_IGN est hérité par baluchon-core.
    let o = Command::new("/bin/sh")
        .arg("-c")
        .arg("trap '' INT; exec \"$0\" \"$@\"")
        .arg(BIN)
        .args([
            "--root",
            &sb.root,
            "run",
            "1",
            "--claude",
            claude.to_str().unwrap(),
        ])
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", &sb.home)
        .env("USER", "testeur")
        .env("CCP_NO_KEYCHAIN", "1")
        .env("CCP_API_BASE", fake.api())
        .output()
        .unwrap();
    assert_eq!(
        code(&o),
        130,
        "Claude doit mourir de SIGINT (128+2) : {}",
        stderr(&o)
    );
}

#[cfg(unix)]
#[test]
fn run_on_a_missing_claude_binary_exits_3() {
    let sb = Sandbox::new();
    sb.put_file_login("1", &creds_json("AT", "RT", now_ms() + 3_600_000, 0));
    let o = sb.run(None, &["run", "1", "--claude", "/nonexistent/claude"]);
    assert_eq!(code(&o), 3, "{}", stderr(&o));
}

// -------------------------------------------------------------------- doctor

#[cfg(unix)]
#[test]
fn doctor_flags_a_divergence_with_claude_auth_status() {
    let sb = Sandbox::new();
    // baluchon-core lit un login ; le faux claude jure qu'il n'y en a pas
    sb.put_file_login("1", &creds_json("AT", "RT", now_ms() + 3_600_000, 0));
    let claude = fake_claude(&sb, "echo '{\"loggedIn\":false}'\n");
    let o = sb.run(None, &["doctor", "1", "--claude", claude.to_str().unwrap()]);
    assert_eq!(code(&o), 6, "{}{}", stdout(&o), stderr(&o));
    assert!(
        stdout(&o).to_lowercase().contains("indéterminé"),
        "{}",
        stdout(&o)
    );

    // accord : même verdict des deux côtés
    let claude = fake_claude(
        &sb,
        "echo '{\"loggedIn\":true,\"email\":\"eve@x.fr\",\"planTier\":\"max_20x\"}'\n",
    );
    let o = sb.run(None, &["doctor", "1", "--claude", claude.to_str().unwrap()]);
    assert_eq!(code(&o), 0, "{}{}", stdout(&o), stderr(&o));
}

/// M7 : un journal de renouvellement laissé par une autre édition. Le public le DIT et n'y
/// touche pas (ni rejeu, ni effacement) : ni le journal ni le magasin ne changent d'un octet.
#[cfg(unix)]
#[test]
fn doctor_reports_an_orphan_journal_and_touches_nothing() {
    let sb = Sandbox::new();
    sb.put_file_login("1", &creds_json("AT", "RT", now_ms() + 3_600_000, 0));
    std::fs::write(sb.journal("1"), b"{\"orphelin\":true}").unwrap();
    let login = sb.profile_dir("1").join(".credentials.json");
    let (j0, l0) = (
        std::fs::read(sb.journal("1")).unwrap(),
        std::fs::read(&login).unwrap(),
    );
    let claude = fake_claude(
        &sb,
        "echo '{\"loggedIn\":true,\"email\":\"a@example.com\",\"planTier\":\"max_20x\"}'\n",
    );
    let o = sb.run(None, &["doctor", "1", "--claude", claude.to_str().unwrap()]);
    let t = stdout(&o);
    assert!(
        t.contains("Journal de renouvellement orphelin dans 1")
            && t.contains("Le public ne le rejoue pas."),
        "{t}"
    );
    assert_eq!(std::fs::read(sb.journal("1")).unwrap(), j0);
    assert_eq!(std::fs::read(&login).unwrap(), l0);

    // Sans journal, la phrase n'apparaît pas.
    std::fs::remove_file(sb.journal("1")).unwrap();
    let o = sb.run(None, &["doctor", "1", "--claude", claude.to_str().unwrap()]);
    assert!(!stdout(&o).contains("orphelin"), "{}", stdout(&o));
}

/// M7 : `doctor` dit ce qu'il voit sous `overlay/` (absente, utilisable, contrat périmé) sans
/// jamais rien y écrire.
#[cfg(unix)]
#[test]
fn doctor_says_what_it_sees_of_the_layer_and_writes_nothing() {
    let sb = Sandbox::new();
    sb.put_file_login("1", &creds_json("AT", "RT", now_ms() + 3_600_000, 0));
    let claude = fake_claude(
        &sb,
        "echo '{\"loggedIn\":true,\"email\":\"a@example.com\",\"planTier\":\"max_20x\"}'\n",
    );
    let doctor = |sb: &Sandbox| {
        stdout(&sb.run(None, &["doctor", "1", "--claude", claude.to_str().unwrap()]))
    };
    assert!(doctor(&sb).contains("Couche : absente"), "{}", doctor(&sb));
    assert!(!Path::new(&sb.root).join("overlay").exists());

    let layer = Path::new(&sb.root).join("overlay");
    std::fs::create_dir_all(&layer).unwrap();
    let version = env!("CARGO_PKG_VERSION");
    let manifest = |contract: u32| {
        format!(
            "name = essai\nversion = {version}+essai.1\nbuilt_on = {version}\ncontract = {contract}\n\
             platforms = darwin-*,linux-*\n"
        )
    };
    std::fs::write(layer.join("LAYER"), manifest(1)).unwrap();
    let t = doctor(&sb);
    assert!(
        t.contains("Couche : essai") && t.contains("utilisable"),
        "{t}"
    );
    // Couche utilisable mais c'est le noyau public qui répond : le repli est dit.
    assert!(t.contains("noyau PUBLIC qui répond"), "{t}");

    std::fs::write(layer.join("LAYER"), manifest(2)).unwrap();
    let t = doctor(&sb);
    assert!(t.contains("contrat périmé (couche 2, noyau 1)"), "{t}");
    assert!(
        !layer.join("overlay.tmp").exists() && std::fs::read_dir(&layer).unwrap().count() == 1,
        "doctor n'écrit rien sous overlay/"
    );
}

/// Générations (re-revue Codex) : `doctor` lit la couche par le pointeur `overlay/CURRENT`, pas par
/// l'ancien manifeste à plat resté à côté, dit un pointeur illisible sans retomber sur le plat, et
/// n'écrit rien.
#[cfg(unix)]
#[test]
fn doctor_reads_the_layer_through_the_generation_pointer() {
    let sb = Sandbox::new();
    sb.put_file_login("1", &creds_json("AT", "RT", now_ms() + 3_600_000, 0));
    let claude = fake_claude(
        &sb,
        "echo '{\"loggedIn\":true,\"email\":\"a@example.com\",\"planTier\":\"max_20x\"}'\n",
    );
    let doctor = |sb: &Sandbox| {
        stdout(&sb.run(None, &["doctor", "1", "--claude", claude.to_str().unwrap()]))
    };
    let version = env!("CARGO_PKG_VERSION");
    let manifest = |name: &str| {
        format!(
            "name = {name}\nversion = {version}+essai.1\nbuilt_on = {version}\ncontract = 1\n\
             platforms = darwin-*,linux-*\n"
        )
    };
    let overlay = Path::new(&sb.root).join("overlay");
    std::fs::create_dir_all(overlay.join("gen/g1")).unwrap();
    std::fs::write(overlay.join("LAYER"), manifest("ancienne-a-plat")).unwrap();
    std::fs::write(overlay.join("gen/g1/LAYER"), manifest("generation-un")).unwrap();
    std::fs::write(overlay.join("CURRENT"), "gen/g1\n").unwrap();
    let t = doctor(&sb);
    assert!(
        t.contains("Couche : generation-un") && !t.contains("ancienne-a-plat"),
        "{t}"
    );
    // Un pointeur illisible : dit, sans repli sur la couche à plat (qui reste valide à côté).
    std::fs::write(overlay.join("CURRENT"), "gen/../..\n").unwrap();
    let t = doctor(&sb);
    assert!(
        t.contains("manifeste inutilisable") && !t.contains("ancienne-a-plat"),
        "{t}"
    );
    std::fs::write(overlay.join("CURRENT"), "gen/g1\n").unwrap();
    let before = std::fs::read_dir(&overlay).unwrap().count();
    let _ = doctor(&sb);
    assert_eq!(
        std::fs::read_dir(&overlay).unwrap().count(),
        before,
        "doctor n'écrit rien sous overlay/"
    );
}

/// Canari de contrat avec le VRAI Claude (aucun réseau, aucun vrai jeton) : sur un
/// dossier de config neuf, baluchon-core et `claude auth status` doivent lire la même
/// chose. Casse si une mise à jour de Claude change le magasin ou son nom de service.
/// Lancement : `CCP_REAL_CLAUDE=$(whence -p claude) cargo test -- --ignored real_claude`
#[test]
#[ignore = "exige CCP_REAL_CLAUDE=<chemin du vrai claude>"]
fn real_claude_reads_the_same_store_as_baluchon_core() {
    let Some(claude) = std::env::var_os("CCP_REAL_CLAUDE") else {
        panic!("CCP_REAL_CLAUDE absent");
    };
    let sb = Sandbox::new();
    sb.put_file_login(
        "faux",
        &creds_json(
            "sk-ant-oat01-FACTICE",
            "sk-ant-ort01-FACTICE",
            now_ms() + 3_600_000,
            0,
        ),
    );
    sb.profile_dir("vide");
    let o = sb
        .cmd(None)
        .env_remove("CCP_CLAUDE_BIN")
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .args(["doctor", "--claude"])
        .arg(&claude)
        .output()
        .unwrap();
    let out = stdout(&o);
    assert_eq!(code(&o), 0, "{out}{}", stderr(&o));
    assert_eq!(out.matches("verdict : cohérent").count(), 2, "{out}");
}

// ------------------------------------------------------- Trousseau (macOS)

#[cfg(target_os = "macos")]
mod keychain {
    use super::*;
    use baluchon_core::creds::keychain::service_name;

    const SECURITY: &str = "/usr/bin/security";

    /// Trousseau temporaire détruit à la fin du test.
    struct TempKeychain {
        path: PathBuf,
    }

    impl TempKeychain {
        fn create(dir: &Path) -> TempKeychain {
            let path = dir.join("essai.keychain");
            let st = Command::new(SECURITY)
                .args(["create-keychain", "-p", "pw-essai"])
                .arg(&path)
                .status()
                .unwrap();
            assert!(st.success(), "création du trousseau temporaire");
            // pas de verrouillage automatique pendant le test
            let _ = Command::new(SECURITY)
                .args(["set-keychain-settings"])
                .arg(&path)
                .status();
            let _ = Command::new(SECURITY)
                .args(["unlock-keychain", "-p", "pw-essai"])
                .arg(&path)
                .status();
            TempKeychain { path }
        }

        fn add(&self, acct: &str, svc: &str, secret: &str) {
            let st = Command::new(SECURITY)
                .args(["add-generic-password", "-a", acct, "-s", svc, "-w", secret])
                .arg(&self.path)
                .status()
                .unwrap();
            assert!(st.success(), "ajout de l'item d'essai");
        }

        /// `None` = absent (code 44).
        fn read(&self, acct: &str, svc: &str) -> Option<String> {
            let o = Command::new(SECURITY)
                .args(["find-generic-password", "-a", acct, "-s", svc, "-w"])
                .arg(&self.path)
                .output()
                .unwrap();
            match o.status.code() {
                Some(0) => Some(baluchon_core::creds::keychain::decode_password_output(
                    &String::from_utf8_lossy(&o.stdout),
                )),
                Some(44) => None,
                c => panic!("lecture Trousseau : code {c:?}"),
            }
        }
    }

    impl Drop for TempKeychain {
        fn drop(&mut self) {
            let _ = Command::new(SECURITY)
                .arg("delete-keychain")
                .arg(&self.path)
                .status();
        }
    }

    fn sandbox_with_keychain() -> (Sandbox, TempKeychain) {
        let mut sb = Sandbox::new();
        let kc = TempKeychain::create(&sb.home);
        sb.keychain = Some(kc.path.clone());
        (sb, kc)
    }

    fn refresh_of(blob: &str) -> String {
        let v: Value = serde_json::from_str(blob).unwrap();
        v["claudeAiOauth"]["refreshToken"]
            .as_str()
            .unwrap()
            .to_string()
    }

    /// Défaut #9 : Claude écrit parfois l'item sous le compte `unknown` (variable
    /// `USER` absente dans son contexte) ; il coexiste alors avec l'item `$USER`
    /// resté périmé. Lire `$USER` d'abord faisait renouveler un login mort alors
    /// que l'item `unknown` était frais, voire écraser le bon.
    #[test]
    fn the_freshest_item_wins_over_a_stale_user_item() {
        let (sb, kc) = sandbox_with_keychain();
        let svc = service_name(&sb.cfg("1"));
        // $USER = « testeur » : périmé depuis longtemps ; `unknown` : frais.
        kc.add(
            "testeur",
            &svc,
            &creds_json("AT-STALE", "RT-STALE", 1_000, 0),
        );
        kc.add(
            "unknown",
            &svc,
            &creds_json("AT-FRESH", "RT-FRESH", now_ms() + 3_600_000, 0),
        );
        sb.profile_dir("1");
        let fake = Fake::start(healthy);
        let r = sb.status_json(&fake, &["--refresh"]);
        assert_eq!(account(&r, "1")["state"], "ok");
        assert_eq!(
            fake.bearers("/api/oauth/usage"),
            vec![Some("AT-FRESH".to_string())],
            "le jeton de l'item le plus frais est celui qui part au serveur"
        );
        assert_eq!(
            fake.token_hits(),
            0,
            "aucun renouvellement : l'item frais n'est pas périmé"
        );
        // L'item périmé n'est ni renouvelé ni réécrit.
        assert_eq!(refresh_of(&kc.read("testeur", &svc).unwrap()), "RT-STALE");
        assert_eq!(refresh_of(&kc.read("unknown", &svc).unwrap()), "RT-FRESH");
    }

    #[test]
    fn purge_removes_portable_services_and_never_the_unsuffixed_machine_one() {
        let (sb, kc) = sandbox_with_keychain();
        let svc1 = service_name(&sb.cfg("1"));
        let svc2 = service_name(&sb.cfg("2"));
        sb.profile_dir("1");
        sb.profile_dir("2");
        kc.add("testeur", &svc1, &creds_json("A", "R", 1, 0));
        kc.add("testeur", &svc2, &creds_json("A", "R", 1, 0));
        kc.add(
            "testeur",
            "Claude Code-credentials",
            &creds_json("MACHINE", "MACHINE", 1, 0),
        );

        let o = sb.run(None, &["accounts", "purge", "1"]);
        assert_eq!(code(&o), 0, "{}", stderr(&o));
        assert!(kc.read("testeur", &svc1).is_none());
        assert!(
            kc.read("testeur", &svc2).is_some(),
            "seul le profil demandé est purgé"
        );

        let o = sb.run(None, &["accounts", "purge"]);
        assert_eq!(code(&o), 0, "{}", stderr(&o));
        assert!(kc.read("testeur", &svc2).is_none());
        assert!(
            kc.read("testeur", "Claude Code-credentials").is_some(),
            "la session de la machine (service sans suffixe) n'est JAMAIS supprimée"
        );
    }

    #[test]
    fn discover_reads_the_keychain_without_writing_it() {
        let (sb, kc) = sandbox_with_keychain();
        let svc = service_name(&sb.cfg("1"));
        let blob = creds_json("AT", "RT", now_ms() + 3_600_000, 0);
        kc.add("testeur", &svc, &blob);
        sb.profile_dir("1");
        let o = sb.run(None, &["accounts", "discover", "--format", "json"]);
        assert_eq!(code(&o), 0, "{}", stderr(&o));
        assert_eq!(kc.read("testeur", &svc).as_deref(), Some(blob.as_str()));
    }
}

// -------------------------------------------------------------------- purge

#[test]
fn purge_erases_every_secret_and_says_so_when_a_claude_session_is_open() {
    let sb = Sandbox::new();
    let d = sb.profile_dir("client");
    for f in [
        ".credentials.json",
        "oauth.token",
        "oauth.token.bak",
        ".ccp-pending",
    ] {
        std::fs::write(d.join(f), "secret").unwrap();
    }
    std::fs::write(d.join("settings.json"), "{}").unwrap();
    // Une « session Claude ouverte » : le verrou de session est tenu par ce test.
    let held = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(d.join(".ccp-session.lock"))
        .unwrap();
    held.try_lock().expect("verrou de test");

    let o = sb.run(None, &["accounts", "purge"]);
    // 11 : tout est effacé, mais une session vivante pourrait réécrire.
    assert_eq!(code(&o), 11, "{}", stderr(&o));
    let out = stdout(&o);
    assert!(out.contains("Attention") && out.contains("client"), "{out}");
    assert!(out.contains("ouvert"), "{out}");
    for f in [
        ".credentials.json",
        "oauth.token",
        "oauth.token.bak",
        ".ccp-pending",
    ] {
        assert!(!d.join(f).exists(), "{f} devait être effacé");
    }
    assert!(d.join("settings.json").exists());
    drop(held);
}

#[test]
fn purge_that_cannot_erase_something_exits_10_and_names_it() {
    let sb = Sandbox::new();
    let d = sb.profile_dir("client");
    std::fs::write(d.join(".credentials.json"), "secret").unwrap();
    // Un répertoire occupe le nom du jeton : impossible à effacer comme fichier.
    std::fs::create_dir(d.join("oauth.token")).unwrap();

    let o = sb.run(None, &["accounts", "purge"]);
    assert_eq!(code(&o), 10, "{}", stdout(&o));
    assert!(
        stdout(&o).contains("ÉCHEC") && stdout(&o).contains("oauth.token"),
        "{}",
        stdout(&o)
    );
    assert!(stderr(&o).contains("INCOMPLÈTE"), "{}", stderr(&o));
    assert!(
        !d.join(".credentials.json").exists(),
        "le reste est tout de même effacé"
    );
}
