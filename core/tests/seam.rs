//! La couture `Extension` : chacun des neuf points d'injection est réellement atteint,
//! et le comportement `ReadOnly` (celui que le public livrera) est celui qu'on croit.
//!
//! Pourquoi ce fichier. Les tests de comportement prouvent que « le même code, appelé
//! par un chemin de plus, fait la même chose ». Ils ne diraient RIEN d'un point oublié
//! et laissé en appel direct à `oauth::`. Ici une extension espionne (`Spy`) compte
//! ses appels, un par point de la table, et le balayage des sources interdit le retour
//! d'un appel direct. (Depuis le lot 2 le code de renouvellement n'est plus dans cette
//! crate ; les essais d'une édition qui renouvelle sont dans SA crate.)
//!
//! Hermétique : un HOME et une racine jetables, un `Env` construit à la main (aucune
//! variable du processus lue), le port 127.0.0.1:1 fermé pour tout réseau, jetons
//! factices, Trousseau désactivé, et un faux `claude` en script. Le vrai `claude` n'est
//! jamais lancé.
//!
//! Unix seulement : le faux `claude` est un script `#!/bin/sh`.
#![cfg(unix)]

use baluchon_core::api::Api;
use baluchon_core::cli::{about_text, build_report, dispatch_with, Cli};
use baluchon_core::discover;
use baluchon_core::doctor;
use baluchon_core::env::{Env, Overrides};
use baluchon_core::error::{CcpError, Result};
use baluchon_core::ext::{
    Extension, External, ExtraOrigin, ReadOnly, Recovery, Renewal, Session, Trigger,
};
use baluchon_core::http::UreqHttp;
use baluchon_core::model::State;
use baluchon_core::root::{Profile, ProfileDir, Root};
use baluchon_core::status::{Deps, ProbeOpts};
use baluchon_testkit::{creds_json, now_ms, Sandbox};
use clap::Parser;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicUsize;
use std::sync::{Arc, Mutex};
use std::time::Duration;

const BIN: &str = env!("CARGO_BIN_EXE_baluchon-core");

// ------------------------------------------------------------------- l'espion

/// Les neuf points d'injection. `recover` en fait deux : la reprise de la sonde de
/// statut (sans verrou tenu) et celle du lancement (verrou de session déjà tenu).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Point {
    Renew,
    RecoverStatus,
    RecoverRun,
    IsRevoked,
    SecretFiles,
    DoctorLines,
    ExtraOrigins,
    External,
    Edition,
}

const ALL: [Point; 9] = [
    Point::Renew,
    Point::RecoverStatus,
    Point::RecoverRun,
    Point::IsRevoked,
    Point::SecretFiles,
    Point::DoctorLines,
    Point::ExtraOrigins,
    Point::External,
    Point::Edition,
];

/// Extension qui n'agit pas (comme `ReadOnly`) mais note chaque appel, et sert des
/// valeurs préparées par le test pour prouver que le public les EXPLOITE.
struct Spy {
    calls: Mutex<Vec<Point>>,
    secrets: Mutex<Vec<PathBuf>>,
    origins: Mutex<Vec<ExtraOrigin>>,
}

impl Spy {
    fn new() -> Arc<Spy> {
        Arc::new(Spy {
            calls: Mutex::new(Vec::new()),
            secrets: Mutex::new(Vec::new()),
            origins: Mutex::new(Vec::new()),
        })
    }

    fn note(&self, p: Point) {
        self.calls.lock().unwrap().push(p);
    }

    fn count(&self, p: Point) -> usize {
        self.calls
            .lock()
            .unwrap()
            .iter()
            .filter(|c| **c == p)
            .count()
    }

    /// Les points qui n'ont JAMAIS été atteints (vide = tous atteints).
    fn missing(&self) -> Vec<Point> {
        ALL.into_iter().filter(|p| self.count(*p) == 0).collect()
    }
}

impl Extension for Spy {
    fn edition(&self) -> &'static str {
        self.note(Point::Edition);
        "spy"
    }

    fn renew(&self, _s: &Session<'_>, _why: Trigger) -> Renewal {
        self.note(Point::Renew);
        Renewal::Unsupported
    }

    fn recover(&self, s: &Session<'_>) -> Recovery {
        self.note(if s.held().is_some() {
            Point::RecoverRun
        } else {
            Point::RecoverStatus
        });
        Recovery::Nothing
    }

    fn is_revoked(&self, _p: &ProfileDir, _fp: &str) -> bool {
        self.note(Point::IsRevoked);
        false
    }

    fn secret_files(&self, _p: &ProfileDir) -> Vec<PathBuf> {
        self.note(Point::SecretFiles);
        self.secrets.lock().unwrap().clone()
    }

    fn doctor_lines(&self, _p: &ProfileDir) -> Vec<String> {
        self.note(Point::DoctorLines);
        vec!["LIGNE-DE-L-ESPION".to_string()]
    }

    fn extra_origins(&self, _env: &Env) -> Vec<ExtraOrigin> {
        self.note(Point::ExtraOrigins);
        self.origins.lock().unwrap().clone()
    }

    fn external(&self, call: &External<'_>) -> Option<Result<i32>> {
        self.note(Point::External);
        (call.args.first().and_then(|a| a.to_str()) == Some("spy-cmd")).then_some(Ok(42))
    }
}

// --------------------------------------------------------------------- aides

fn env_of(sb: &Sandbox, claude: Option<String>) -> Env {
    Env {
        // Port fermé : aucune requête ne peut sortir de la machine.
        api_base: "http://127.0.0.1:1".into(),
        keychain: None,
        no_keychain: true,
        home: sb.home.clone(),
        user: "testeur".into(),
        claude,
        ovr: Overrides::default(),
    }
}

fn deps_of(spy: &Arc<Spy>, env: &Env) -> Deps {
    Deps {
        env: Arc::new(env.clone()),
        api: Api::new(Arc::new(UreqHttp::new()), &env.api_base),
        critical: Arc::new(AtomicUsize::new(0)),
        ext: spy.clone(),
    }
}

/// Un portable jetable avec un profil `p1` dont le login est `creds`.
fn sandbox_with(creds: &str) -> Sandbox {
    let sb = Sandbox::new(BIN);
    sb.put_file_login("p1", creds);
    sb
}

fn expired() -> String {
    creds_json("AT-faux", "RT-faux", 1_000, 0)
}

fn valid() -> String {
    creds_json("AT-faux", "RT-faux", now_ms() + 3_600_000, 0)
}

/// Passe par `cli::dispatch_with`, donc par le câblage réel commande -> `Deps` -> extension.
fn drive(spy: &Arc<Spy>, sb: &Sandbox, claude: Option<String>, args: &[&str]) -> Result<i32> {
    let mut argv = vec!["baluchon-core", "--root", sb.root.as_str()];
    argv.extend_from_slice(args);
    let cli = Cli::try_parse_from(argv).expect("arguments valides");
    let env = env_of(sb, claude);
    dispatch_with(spy.clone(), cli, move |_| env)
}

fn probe_opts() -> ProbeOpts {
    ProbeOpts {
        refresh: false,
        offline: false,
        max_age_s: 300,
        budget: Duration::from_secs(5),
    }
}

/// Faux `claude` : sort aussitôt avec 0. Plafond dur : il ne fait rien d'autre.
fn stub_claude(sb: &Sandbox) -> String {
    let path = sb.home.join("claude-faux");
    std::fs::write(&path, "#!/bin/sh\nexit 0\n").unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path.to_string_lossy().into_owned()
}

// --------------------------------------------------- les neuf points, un à un

#[test]
fn point_renew_is_reached_by_an_expired_login() {
    let spy = Spy::new();
    let sb = sandbox_with(&expired());
    let env = env_of(&sb, None);
    let root = Root::resolve(Some(&sb.root)).unwrap();
    let report = build_report(&deps_of(&spy, &env), &root, &probe_opts());
    assert_eq!(report.accounts[0].state, State::Expired);
    assert_eq!(spy.count(Point::Renew), 1, "une seule demande par sonde");
    assert_eq!(spy.count(Point::RecoverStatus), 1);
    assert_eq!(spy.count(Point::IsRevoked), 1);
    assert_eq!(spy.count(Point::RecoverRun), 0);
}

#[test]
fn points_recover_and_is_revoked_are_reached_even_when_offline() {
    let spy = Spy::new();
    let sb = sandbox_with(&expired());
    // `accounts best` ne sonde jamais le réseau : la reprise et le marqueur de refus
    // doivent pourtant être consultés avant de lire le statut.
    // (Ok ou « aucun compte » : ce que `best` recommande n'est pas l'objet de cet essai.)
    let r = drive(&spy, &sb, None, &["accounts", "best"]);
    assert!(matches!(r, Ok(0) | Err(CcpError::NotFound(_))), "{r:?}");
    assert_eq!(spy.count(Point::RecoverStatus), 1);
    assert_eq!(spy.count(Point::IsRevoked), 1);
    assert_eq!(
        spy.count(Point::Renew),
        0,
        "hors ligne : aucun renouvellement"
    );
}

#[test]
fn point_recover_runs_under_the_held_session_lock_at_launch() {
    let spy = Spy::new();
    let sb = sandbox_with(&valid());
    let claude = stub_claude(&sb);
    let r = drive(&spy, &sb, Some(claude), &["run", "p1"]);
    assert!(matches!(r, Ok(0)), "le faux claude sort avec 0 ({r:?})");
    assert_eq!(
        spy.count(Point::RecoverRun),
        1,
        "une reprise, verrou de session tenu"
    );
    assert!(
        spy.count(Point::RecoverStatus) >= 1,
        "la sonde d'après-session passe aussi par la reprise sans verrou"
    );
}

#[test]
fn point_secret_files_adds_to_the_purge_but_never_outside_the_profile() {
    let spy = Spy::new();
    let sb = sandbox_with(&valid());
    let inside = sb.profile_dir("p1").join(".fichier-de-l-espion");
    std::fs::write(&inside, "secret factice").unwrap();
    spy.secrets.lock().unwrap().push(inside.clone());
    let r = drive(&spy, &sb, None, &["accounts", "purge"]);
    assert!(matches!(r, Ok(0)), "{r:?}");
    assert_eq!(spy.count(Point::SecretFiles), 1);
    assert!(!inside.exists(), "le fichier de l'extension est effacé");
    assert!(
        !sb.profile_dir("p1").join(".credentials.json").exists(),
        "la liste du public est toujours effacée"
    );
}

#[test]
fn purge_refuses_extension_paths_outside_the_profile_and_says_so() {
    let spy = Spy::new();
    let sb = sandbox_with(&valid());
    let outside = sb.home.join("hors-profil.txt");
    std::fs::write(&outside, "à garder").unwrap();
    // Un chemin qui commence par le dossier du profil mais en remonte par `..`.
    let sneaky = sb
        .profile_dir("p1")
        .join("..")
        .join("..")
        .join("..")
        .join("home");
    let sneaky = sneaky.join("hors-profil.txt");
    {
        let mut s = spy.secrets.lock().unwrap();
        s.push(outside.clone());
        s.push(sneaky);
    }
    let r = drive(&spy, &sb, None, &["accounts", "purge"]);
    assert!(
        matches!(r, Err(CcpError::Internal(_))),
        "purge INCOMPLÈTE annoncée, jamais « effacé » ({r:?})"
    );
    assert!(
        outside.exists(),
        "un chemin hors du profil n'est jamais supprimé"
    );
    assert!(
        !sb.profile_dir("p1").join(".credentials.json").exists(),
        "le reste de la purge a bien eu lieu"
    );
}

#[test]
fn point_extra_origins_feeds_the_inventory() {
    let spy = Spy::new();
    let sb = sandbox_with(&valid());
    let other = sb.home.join("autre-outil").join("work");
    std::fs::create_dir_all(&other).unwrap();
    std::fs::write(other.join(".credentials.json"), valid()).unwrap();
    spy.origins.lock().unwrap().push(ExtraOrigin {
        origin: discover::Origin::Extension,
        label: "espion/work".into(),
        dir: other,
    });
    // Par la commande : prouve le câblage cli -> discover -> extension.
    let r = drive(&spy, &sb, None, &["accounts", "discover", "--missing"]);
    assert!(matches!(r, Ok(0)), "{r:?}");
    assert_eq!(spy.count(Point::ExtraOrigins), 1);
    // Et le contenu : l'inventaire montre bien ce que l'extension a nommé.
    let env = env_of(&sb, None);
    let root = Root::resolve(Some(&sb.root)).unwrap();
    let inv = discover::scan(&env, &*spy, &root);
    assert!(
        inv.logins
            .iter()
            .any(|l| l.label == "espion/work" && l.origin == discover::Origin::Extension),
        "inventaire : {:?}",
        inv.logins.iter().map(|l| &l.label).collect::<Vec<_>>()
    );
}

#[test]
fn point_doctor_lines_and_edition_show_up_in_the_diagnostic() {
    let spy = Spy::new();
    let sb = sandbox_with(&valid());
    let env = env_of(&sb, Some("/nonexistent/claude".into()));
    let root = Root::resolve(Some(&sb.root)).unwrap();
    let report = doctor::run(&env, &deps_of(&spy, &env), &root, None).unwrap();
    assert!(
        report.text.contains("\n  LIGNE-DE-L-ESPION\n"),
        "{}",
        report.text
    );
    assert!(report.text.contains("édition spy"), "{}", report.text);
    assert_eq!(spy.count(Point::DoctorLines), 1);
    assert_eq!(spy.count(Point::IsRevoked), 1);
    // Et par la commande (câblage cmd_doctor -> Deps -> extension).
    let spy2 = Spy::new();
    let _ = drive(&spy2, &sb, Some("/nonexistent/claude".into()), &["doctor"]);
    assert_eq!(spy2.count(Point::DoctorLines), 1);
    assert!(spy2.count(Point::Edition) >= 1);
}

#[test]
fn point_external_is_offered_to_the_extension_before_the_public_says_usage() {
    let spy = Spy::new();
    let sb = sandbox_with(&valid());
    let r = drive(&spy, &sb, None, &["spy-cmd", "arg"]);
    assert!(matches!(r, Ok(42)), "{r:?}");
    let r = drive(&spy, &sb, None, &["frobnicate"]);
    match r {
        Err(CcpError::Usage(m)) => assert!(m.contains("frobnicate"), "{m}"),
        other => panic!("usage attendu : {other:?}"),
    }
    assert_eq!(spy.count(Point::External), 2);
}

#[test]
fn point_edition_is_reported_by_about() {
    let spy = Spy::new();
    let sb = sandbox_with(&valid());
    let r = drive(&spy, &sb, None, &["about", "--json"]);
    assert!(matches!(r, Ok(0)), "{r:?}");
    assert!(spy.count(Point::Edition) >= 1);
    let v: serde_json::Value =
        serde_json::from_str(&about_text(&*spy, true).unwrap()).expect("JSON");
    assert_eq!(v["edition"], "spy");
}

/// Le tableau en entier sur UNE extension : si un point n'est plus atteint par
/// aucune commande, le test nomme celui qui manque.
#[test]
fn every_injection_point_of_the_table_is_reached() {
    let spy = Spy::new();
    let sb = sandbox_with(&expired());
    let claude = stub_claude(&sb);
    let env = env_of(&sb, Some(claude.clone()));
    let root = Root::resolve(Some(&sb.root)).unwrap();
    let inside = sb.profile_dir("p1").join(".fichier-de-l-espion");
    std::fs::write(&inside, "x").unwrap();
    spy.secrets.lock().unwrap().push(inside);
    let other = sb.home.join("autre-outil");
    std::fs::create_dir_all(&other).unwrap();
    spy.origins.lock().unwrap().push(ExtraOrigin {
        origin: discover::Origin::Extension,
        label: "espion/x".into(),
        dir: other,
    });

    let _ = build_report(&deps_of(&spy, &env), &root, &probe_opts());
    // `run` demande un login valide pour ne pas sonder un jeton expiré en fin de session.
    sb.put_file_login("p1", &valid());
    let _ = drive(&spy, &sb, Some(claude), &["run", "p1"]);
    let _ = drive(&spy, &sb, None, &["accounts", "discover", "--missing"]);
    let _ = drive(&spy, &sb, None, &["spy-cmd"]);
    let _ = drive(&spy, &sb, None, &["about"]);
    let _ = drive(&spy, &sb, Some("/nonexistent/claude".into()), &["doctor"]);
    let _ = drive(&spy, &sb, None, &["accounts", "purge"]);
    assert_eq!(spy.missing(), Vec::<Point>::new(), "points jamais atteints");
}

// ------------------------------------------------------- le comportement ReadOnly

#[test]
fn readonly_does_nothing_and_says_it_is_public() {
    let sb = sandbox_with(&valid());
    let root = Root::resolve(Some(&sb.root)).unwrap();
    let p = root.profile(&Profile::parse("p1").unwrap());
    let env = env_of(&sb, None);
    let ro = ReadOnly;
    assert_eq!(ro.edition(), "public");
    assert!(!ro.is_revoked(&p, "empreinte"));
    assert!(ro.secret_files(&p).is_empty());
    assert!(ro.doctor_lines(&p).is_empty());
    assert!(ro.extra_origins(&env).is_empty());
}

#[test]
fn readonly_about_json_has_the_contract_fields() {
    let v: serde_json::Value =
        serde_json::from_str(&about_text(&ReadOnly, true).unwrap()).expect("JSON");
    assert_eq!(v["name"], "baluchon-core");
    assert_eq!(v["version"], env!("CARGO_PKG_VERSION"));
    assert_eq!(v["built_on"], env!("CARGO_PKG_VERSION"));
    assert_eq!(v["contract"], 1);
    assert_eq!(v["edition"], "public");
}

#[test]
fn readonly_answers_usage_to_an_unknown_command_without_needing_a_root() {
    let sb = sandbox_with(&valid());
    let cli = Cli::try_parse_from(["baluchon-core", "--root", "/n/existe/pas", "frobnicate"])
        .expect("clap accepte toute sous-commande");
    let env = env_of(&sb, None);
    let r = dispatch_with(Arc::new(ReadOnly), cli, move |_| env);
    match r {
        Err(e @ CcpError::Usage(_)) => assert_eq!(e.exit_code(), 2),
        other => panic!("usage attendu : {other:?}"),
    }
}

// --------------------------------------------------- aucun appel direct ne revient

fn rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
    for e in std::fs::read_dir(dir).unwrap().flatten() {
        let p = e.path();
        if p.is_dir() {
            rust_files(&p, out);
        } else if p.extension().is_some_and(|x| x == "rs") {
            out.push(p);
        }
    }
}

/// Depuis le lot 2 le code de renouvellement (`oauth.rs`) n'est plus dans cette crate :
/// le compilateur refuse déjà un `oauth::renew` dans le public. Ce balayage reste, pour
/// qu'un module du même nom qui reviendrait par mégarde, ou un appel écrit dans un
/// fichier non compilé (cfg), soit nommé. Seul `ext.rs` (la documentation) a le droit de
/// citer ces noms.
fn offends(line: &str) -> bool {
    const FORBIDDEN: [&str; 4] = [
        "oauth::renew",
        "oauth::replay_pending",
        "oauth::is_revoked",
        "oauth::mark_revoked",
    ];
    const NAMES: [&str; 4] = ["renew", "replay_pending", "is_revoked", "mark_revoked"];
    let direct = FORBIDDEN.iter().any(|p| line.contains(p));
    let imported =
        line.trim_start().starts_with("use crate::oauth") && NAMES.iter().any(|n| line.contains(n));
    direct || imported
}

#[test]
fn no_public_source_calls_the_renewal_code_directly() {
    // Contrôle positif : le motif VOIT ces écritures, il n'est pas aveugle.
    for sample in [
        "let r = oauth::renew(env, api, p, seen, why, c);",
        "oauth::replay_pending(env, p)",
        "if oauth::is_revoked(p, fp) {",
        "use crate::oauth::{renew, Trigger};",
    ] {
        assert!(offends(sample), "le motif ne voit plus : {sample}");
    }
    assert!(!offends("let r = ext.renew(&session, why);"));

    let mut files = Vec::new();
    rust_files(
        &Path::new(env!("CARGO_MANIFEST_DIR")).join("src"),
        &mut files,
    );
    assert!(
        files.len() > 20,
        "balayage aveugle : {} fichiers",
        files.len()
    );

    let mut offenders = Vec::new();
    for f in &files {
        let name = f.file_name().unwrap().to_string_lossy().into_owned();
        if name == "ext.rs" {
            continue;
        }
        let text = std::fs::read_to_string(f).unwrap();
        for (i, line) in text.lines().enumerate() {
            if offends(line) {
                offenders.push(format!("{}:{}: {}", f.display(), i + 1, line.trim()));
            }
        }
    }
    assert!(offenders.is_empty(), "appels directs : {offenders:#?}");
}
