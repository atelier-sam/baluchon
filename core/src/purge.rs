//! `accounts purge` : retire les identifiants de CE portable (Trousseau + fichiers).
//!
//! C'est une SUPPRESSION, demandée par l'utilisateur, de SES PROPRES identifiants : elle reste dans
//! le contrat « lecture seule » du public (TECHNICAL.md, décision P1) ; aucune écriture n'y a sa place.
//!
//! Garde-fous : seuls les services SUFFIXÉS (`Claude Code-credentials-<8 hex>`,
//! un par `CLAUDE_CONFIG_DIR`) sont supprimés. Le service sans suffixe est la
//! session Claude Code normale de la machine : `delete_all` le refuse, quoi
//! qu'on lui passe.
//!
//! Sur TOUTES les plateformes, tout ce qui contient un secret dans le dossier du
//! profil est effacé : `.credentials.json`, `oauth.token`, sa sauvegarde
//! `oauth.token.bak` (laissée par le wizard pendant un remplacement), le journal
//! de renouvellement `.ccp-pending` et sa réservation `.ccp-pending.reserve` (ils
//! contiennent les DERNIERS jetons valides) et les `.ccp-tmp-*` orphelins d'une
//! écriture interrompue. C'est ce que le wizard retire en quittant un PC client
//! marqué « invité ».
//!
//! Concurrence : la purge prend le verrou du profil (celui du renouvellement)
//! AVANT d'effacer et le garde jusqu'à la fin. Sans lui, la sonde `status` de fond
//! que le wizard lance à chaque retour au menu pourrait finir un renouvellement
//! juste après la purge et réécrire des identifiants. Un renouvellement en cours
//! est attendu ; une session Claude OUVERTE n'empêche pas la purge (un invité qui
//! part doit partir sans identifiants) mais est SIGNALÉE dans le rapport.
//!
//! Aucun échec n'est avalé : la purge continue sur les autres fichiers, puis
//! chaque échec figure dans le rapport (et le code de sortie n'est plus 0).

use crate::env::Env;
use crate::error::Result;
use crate::ext::Extension;
use crate::lock::{self, PurgeLock};
use crate::root::{Profile, ProfileDir, Root};
use std::path::Path;

#[derive(Debug, Default, PartialEq, Eq)]
pub struct PurgeReport {
    pub profiles: usize,
    pub removed: usize,
    /// Profils purgés alors qu'une session Claude ouverte tenait leur verrou :
    /// elle peut réécrire ses identifiants en se fermant.
    pub session_open: Vec<String>,
    /// Profils purgés alors qu'un renouvellement tenait encore le verrou (> 15 s).
    pub renewal_running: Vec<String>,
    /// Profils purgés sans verrou (le volume ne sait pas verrouiller) : `(profil, raison)`.
    pub unlocked: Vec<(String, String)>,
    /// Tout ce qui n'a PAS pu être effacé : `(ce qui, pourquoi)`. Vide = purge complète.
    pub failures: Vec<String>,
}

impl PurgeReport {
    pub fn complete(&self) -> bool {
        self.failures.is_empty()
    }
    /// Effacement fait sans le verrou du profil : un processus vivant peut encore
    /// réécrire des identifiants (code de sortie 11 de `accounts purge`).
    pub fn at_risk(&self) -> bool {
        !self.session_open.is_empty()
            || !self.renewal_running.is_empty()
            || !self.unlocked.is_empty()
    }
}

/// `ext` ajoute ses propres fichiers secrets à la liste du public : la purge efface
/// toujours AU MOINS la liste ci-dessous, quelle que soit l'extension.
pub fn purge(
    env: &Env,
    ext: &dyn Extension,
    root: &Root,
    only: Option<&Profile>,
) -> Result<PurgeReport> {
    let mut report = PurgeReport::default();
    // Un LIEN n'est jamais suivi : `config/` redirigé, ou `config/pro -> ~/.claude`,
    // ferait purger les identifiants d'un Claude HORS de l'installation. Chaque lien
    // est consigné en échec (exit 10) et l'utilisateur le retire lui-même. Le contrôle
    // précède tout verrou, toute lecture de dossier et toute suppression.
    if root.profiles_dir_is_link() {
        report.failures.push(format!(
            "{} : lien symbolique, non suivi — rien n'est effacé (retire ce lien toi-même)",
            root.profiles_dir().display()
        ));
        return Ok(report);
    }
    let profiles: Vec<Profile> = match only {
        Some(p) => vec![p.clone()],
        None => {
            for n in root.linked_entries() {
                report.failures.push(format!(
                    "{} : lien symbolique, non suivi — rien n'est effacé dedans (retire ce lien toi-même)",
                    root.profiles_dir().join(n).display()
                ));
            }
            root.list_profiles()
        }
    };
    report.profiles = profiles.len();
    for name in &profiles {
        let pd = root.profile(name);
        if is_link(&pd.dir) {
            // Profil demandé par son nom : même refus que s'il était listé.
            report.profiles -= 1;
            report.failures.push(format!(
                "{} (profil {name}) : lien symbolique, non suivi — rien n'est effacé dedans",
                pd.dir.display()
            ));
            continue;
        }
        // Le garde vit jusqu'à la fin de l'itération : fichiers ET Trousseau sont
        // effacés verrou en main.
        let _guard = match lock::acquire_for_purge(&pd) {
            PurgeLock::Held(g) => Some(g),
            PurgeLock::NoFolder => None,
            PurgeLock::SessionOpen => {
                report.session_open.push(name.to_string());
                None
            }
            PurgeLock::RenewalStuck => {
                report.renewal_running.push(name.to_string());
                None
            }
            PurgeLock::Unsupported(why) => {
                report.unlocked.push((name.to_string(), why));
                None
            }
        };
        report.removed += purge_files(ext, &pd, &mut report.failures);
        report.removed += purge_keychain(env, &pd, &mut report.failures);
    }
    Ok(report)
}

/// Fichiers qui contiennent un secret dans le dossier d'un profil.
fn secret_files(pd: &ProfileDir) -> Vec<std::path::PathBuf> {
    let mut v = vec![
        pd.credentials_file(),
        pd.token_file(),
        pd.token_backup(),
        pd.pending_journal(),
        // Place réservée du journal : contient les jetons entre l'écriture et le rename.
        pd.pending_reserve(),
    ];
    // Reste d'une `write_atomic` tuée net : `..credentials.json.ccp-tmp-<pid>-…`.
    if let Ok(rd) = std::fs::read_dir(&pd.dir) {
        for e in rd.flatten() {
            let n = e.file_name().to_string_lossy().into_owned();
            if n.starts_with('.')
                && n.contains(".ccp-tmp-")
                && ["credentials.json", "ccp-pending", "oauth.token"]
                    .iter()
                    .any(|k| n.contains(k))
            {
                v.push(e.path());
            }
        }
    }
    v
}

/// Efface les secrets en fichier ; un fichier absent n'est pas une erreur (purge
/// idempotente), tout autre échec est consigné.
fn purge_files(ext: &dyn Extension, pd: &ProfileDir, failures: &mut Vec<String>) -> usize {
    let mut n = 0;
    let mut files = secret_files(pd);
    // Une extension ne choisit pas ce que la purge supprime hors du profil : un
    // chemin hors du dossier du profil (ou qui en remonte par `..`) est refusé et
    // consigné, jamais effacé.
    for f in ext.secret_files(pd) {
        let escapes = f
            .components()
            .any(|c| matches!(c, std::path::Component::ParentDir));
        if f.starts_with(&pd.dir) && !escapes {
            // Un sous-dossier LIEN entre le profil et le fichier ferait sortir
            // l'effacement du profil : refusé et consigné, comme un chemin hors profil.
            if let Some(l) = link_between(&pd.dir, &f) {
                failures.push(format!(
                    "{} (profil {}) : passe par le lien {}, non suivi, refusé",
                    f.display(),
                    pd.name,
                    l.display()
                ));
                continue;
            }
            files.push(f);
        } else {
            failures.push(format!(
                "{} (profil {}) : chemin hors du dossier du profil, refusé",
                f.display(),
                pd.name
            ));
        }
    }
    for f in files {
        match remove_secret(&f) {
            Ok(true) => n += 1,
            Ok(false) => {}
            Err(e) => failures.push(format!("{} (profil {}) : {e}", f.display(), pd.name)),
        }
    }
    n
}

/// Ce chemin est-il un lien (lu SANS le suivre) ? Absent ou illisible : non.
fn is_link(p: &Path) -> bool {
    std::fs::symlink_metadata(p).is_ok_and(|m| m.file_type().is_symlink())
}

/// Premier composant de `f` sous `base` (exclu) qui est un lien, dernier composant
/// exclu : un fichier-lien se supprime lui-même (`remove_file` ne suit pas), un
/// DOSSIER-lien au milieu du chemin redirigerait la suppression. `None` = chemin sûr.
fn link_between(base: &Path, f: &Path) -> Option<std::path::PathBuf> {
    let rel = f.strip_prefix(base).ok()?;
    let mut cur = base.to_path_buf();
    let mut comps: Vec<_> = rel.components().collect();
    comps.pop();
    for c in comps {
        cur.push(c.as_os_str());
        if is_link(&cur) {
            return Some(cur);
        }
    }
    None
}

/// `Ok(true)` effacé, `Ok(false)` déjà absent. Un FICHIER seulement : si un
/// répertoire occupe ce nom, c'est un échec (on ne supprime pas d'arborescence).
fn remove_secret(f: &Path) -> std::io::Result<bool> {
    match std::fs::remove_file(f) {
        Ok(()) => Ok(true),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e),
    }
}

#[cfg(target_os = "macos")]
fn purge_keychain(env: &Env, pd: &ProfileDir, failures: &mut Vec<String>) -> usize {
    use crate::creds::keychain;
    if env.no_keychain {
        return 0;
    }
    let svc = keychain::service_name(&pd.cfg);
    match keychain::delete_all(env, &svc) {
        Ok(n) => n,
        Err(e) => {
            failures.push(format!("Trousseau (profil {}) : {e}", pd.name));
            0
        }
    }
}

#[cfg(not(target_os = "macos"))]
fn purge_keychain(_env: &Env, _pd: &ProfileDir, _failures: &mut Vec<String>) -> usize {
    0
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ext::ReadOnly;
    use crate::root::PathStyle;

    /// Ces essais portent sur la liste du public : l'extension y est `ReadOnly`
    /// (l'ajout de fichiers par une extension est couvert par `tests/seam.rs`).
    fn purge(env: &Env, root: &Root, only: Option<&Profile>) -> Result<PurgeReport> {
        super::purge(env, &ReadOnly, root, only)
    }

    #[test]
    fn hermetic_env_never_touches_the_keychain() {
        let t = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(t.path().join("config").join("1")).unwrap();
        let root = Root::new(t.path().to_str().unwrap(), PathStyle::Unix).unwrap();
        let env = Env::for_tests(t.path().to_path_buf());
        let r = purge(&env, &root, None).unwrap();
        assert_eq!(
            r,
            PurgeReport {
                profiles: 1,
                ..PurgeReport::default()
            }
        );
    }

    #[test]
    fn file_credentials_are_erased_and_purge_is_idempotent() {
        let t = tempfile::tempdir().unwrap();
        let d = t.path().join("config").join("client");
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join(".credentials.json"), "{}").unwrap();
        std::fs::write(d.join("oauth.token"), "sk-ant-oat-factice").unwrap();
        std::fs::write(d.join("settings.json"), "{}").unwrap();
        let root = Root::new(t.path().to_str().unwrap(), PathStyle::Unix).unwrap();
        let env = Env::for_tests(t.path().to_path_buf());
        assert_eq!(purge(&env, &root, None).unwrap().removed, 2);
        assert!(!d.join(".credentials.json").exists());
        assert!(!d.join("oauth.token").exists());
        assert!(d.join("settings.json").exists(), "les réglages restent");
        assert_eq!(purge(&env, &root, None).unwrap().removed, 0);
    }

    #[test]
    fn a_purge_without_the_lock_is_complete_but_at_risk() {
        let mut r = PurgeReport::default();
        assert!(r.complete() && !r.at_risk());
        r.session_open.push("client".into());
        assert!(r.complete() && r.at_risk());
    }

    #[test]
    fn explicit_profile_is_purged_even_if_its_folder_is_gone() {
        let t = tempfile::tempdir().unwrap();
        let root = Root::new(t.path().to_str().unwrap(), PathStyle::Unix).unwrap();
        let env = Env::for_tests(t.path().to_path_buf());
        let p = Profile::parse("ancien").unwrap();
        assert_eq!(purge(&env, &root, Some(&p)).unwrap().profiles, 1);
    }

    use crate::lock::{self, Acquire, RenewingMark};

    fn sandbox(profile: &str) -> (tempfile::TempDir, Root, Env, std::path::PathBuf) {
        let t = tempfile::tempdir().unwrap();
        let d = t.path().join("config").join(profile);
        std::fs::create_dir_all(&d).unwrap();
        let root = Root::new(t.path().to_str().unwrap(), PathStyle::Unix).unwrap();
        let env = Env::for_tests(t.path().to_path_buf());
        (t, root, env, d)
    }

    #[test]
    fn every_secret_in_the_profile_is_erased_not_only_the_credentials() {
        let (_t, root, env, d) = sandbox("client");
        for f in [
            ".credentials.json",
            "oauth.token",
            "oauth.token.bak",
            ".ccp-pending",
            ".ccp-pending.reserve",
            // reste d'une `write_atomic` tuée net (nom réel : ".{nom}.ccp-tmp-…")
            "..credentials.json.ccp-tmp-1-2-3",
            "..ccp-pending.ccp-tmp-1-2-4",
        ] {
            std::fs::write(d.join(f), "secret").unwrap();
        }
        // à NE PAS toucher : réglages, état non secret, verrou
        for f in ["settings.json", ".status.json", ".ccp-revoked"] {
            std::fs::write(d.join(f), "{}").unwrap();
        }
        let r = purge(&env, &root, None).unwrap();
        assert!(r.complete(), "{r:?}");
        assert_eq!(r.removed, 7);
        for f in [
            ".credentials.json",
            "oauth.token",
            "oauth.token.bak",
            ".ccp-pending",
            ".ccp-pending.reserve",
            "..credentials.json.ccp-tmp-1-2-3",
            "..ccp-pending.ccp-tmp-1-2-4",
        ] {
            assert!(!d.join(f).exists(), "{f} devait disparaître");
        }
        for f in ["settings.json", ".status.json", ".ccp-revoked"] {
            assert!(d.join(f).exists(), "{f} doit rester");
        }
    }

    #[test]
    fn purge_waits_for_a_running_renewal_so_nothing_is_rewritten_after_it() {
        // Le renouvellement de fond tient le verrou, pose son marqueur puis ÉCRIT
        // les identifiants : la purge doit attendre, puis les effacer.
        let (_t, root, env, d) = sandbox("client");
        let pd = root.profile(&Profile::parse("client").unwrap());
        let cred = d.join(".credentials.json");
        let c2 = cred.clone();
        let (ready_tx, ready_rx) = std::sync::mpsc::channel();
        let bg = std::thread::spawn(move || {
            let Acquire::Got(guard) = lock::try_acquire(&pd) else {
                panic!("verrou attendu")
            };
            let mark = RenewingMark::set(&pd);
            ready_tx.send(()).unwrap();
            std::thread::sleep(std::time::Duration::from_millis(500));
            std::fs::write(&c2, "jetons-renouvelés").unwrap();
            drop(mark);
            drop(guard);
        });
        ready_rx.recv().unwrap();
        let t0 = std::time::Instant::now();
        let r = purge(&env, &root, None).unwrap();
        bg.join().unwrap();
        assert!(
            t0.elapsed() >= std::time::Duration::from_millis(400),
            "la purge n'a pas attendu le renouvellement"
        );
        assert!(!cred.exists(), "identifiants réécrits APRÈS la purge");
        assert_eq!(r.removed, 1);
        assert!(r.session_open.is_empty() && r.renewal_running.is_empty());
        assert!(r.complete());
    }

    #[test]
    fn an_open_claude_session_does_not_block_the_purge_but_is_reported() {
        let (_t, root, env, d) = sandbox("client");
        std::fs::write(d.join(".credentials.json"), "{}").unwrap();
        std::fs::write(d.join(".ccp-pending"), "{}").unwrap();
        let pd = root.profile(&Profile::parse("client").unwrap());
        let Acquire::Got(_claude) = lock::try_acquire(&pd) else {
            panic!("verrou attendu")
        };
        let r = purge(&env, &root, None).unwrap();
        assert_eq!(r.session_open, vec!["client".to_string()]);
        assert_eq!(r.removed, 2);
        assert!(r.complete(), "une session ouverte n'est pas un échec");
        assert!(!d.join(".credentials.json").exists());
    }

    #[test]
    fn a_deletion_failure_is_reported_and_the_rest_is_still_erased() {
        let (_t, root, env, d) = sandbox("client");
        std::fs::write(d.join(".credentials.json"), "{}").unwrap();
        // Un RÉPERTOIRE occupe le nom du jeton : remove_file échoue.
        std::fs::create_dir(d.join("oauth.token")).unwrap();
        std::fs::write(d.join("oauth.token").join("x"), "x").unwrap();
        std::fs::write(d.join(".ccp-pending"), "{}").unwrap();
        let r = purge(&env, &root, None).unwrap();
        assert!(!r.complete());
        assert_eq!(r.failures.len(), 1, "{r:?}");
        assert!(r.failures[0].contains("oauth.token"), "{r:?}");
        assert!(r.failures[0].contains("client"), "{r:?}");
        assert!(!d.join(".credentials.json").exists(), "le reste est effacé");
        assert!(!d.join(".ccp-pending").exists(), "le reste est effacé");
        assert!(d.join("oauth.token").exists());
    }

    /// Dossier TÉMOIN hors de l'installation, avec les fichiers qu'un Claude normal y
    /// garde : la purge n'a le droit d'y toucher ni de loin ni de près.
    #[cfg(unix)]
    fn temoin(t: &tempfile::TempDir) -> std::path::PathBuf {
        let w = t.path().join("hors-installation").join("claude-normal");
        std::fs::create_dir_all(&w).unwrap();
        for f in [".credentials.json", "oauth.token", ".ccp-pending"] {
            std::fs::write(w.join(f), "temoin").unwrap();
        }
        w
    }

    #[cfg(unix)]
    fn temoin_intact(w: &std::path::Path) {
        for f in [".credentials.json", "oauth.token", ".ccp-pending"] {
            assert!(
                w.join(f).exists(),
                "le témoin {f} a été supprimé par la purge"
            );
        }
        assert!(
            !w.join(".ccp-lock").exists(),
            "un verrou a été créé dans la cible d'un lien"
        );
    }

    /// Revue Codex 4e passe, point 5 : `config/pro -> ~/.claude` — la purge suivait le
    /// lien et supprimait les identifiants du Claude normal, hors de l'installation.
    #[cfg(unix)]
    #[test]
    fn a_profile_link_is_never_followed_and_is_reported_as_a_failure() {
        let (t, root, env, d) = sandbox("1");
        std::fs::write(d.join(".credentials.json"), "{}").unwrap();
        let w = temoin(&t);
        std::os::unix::fs::symlink(&w, t.path().join("config").join("pro")).unwrap();
        let r = purge(&env, &root, None).unwrap();
        temoin_intact(&w);
        assert!(
            !d.join(".credentials.json").exists(),
            "le vrai profil est purgé"
        );
        assert_eq!(r.profiles, 1, "le lien n'est pas un profil : {r:?}");
        assert!(!r.complete(), "un lien laissé = purge incomplète");
        assert_eq!(r.failures.len(), 1, "{r:?}");
        assert!(
            r.failures[0].contains("pro") && r.failures[0].contains("lien"),
            "{r:?}"
        );
    }

    /// Même refus quand le profil-lien est NOMMÉ (`accounts purge pro`) : le
    /// contrôle ne dépend pas de la liste.
    #[cfg(unix)]
    #[test]
    fn a_named_profile_that_is_a_link_is_refused_too() {
        let (t, root, env, _d) = sandbox("1");
        let w = temoin(&t);
        std::os::unix::fs::symlink(&w, t.path().join("config").join("pro")).unwrap();
        let p = Profile::parse("pro").unwrap();
        let r = purge(&env, &root, Some(&p)).unwrap();
        temoin_intact(&w);
        assert_eq!(r.removed, 0);
        assert_eq!(r.profiles, 0, "{r:?}");
        assert!(!r.complete() && r.failures[0].contains("lien"), "{r:?}");
    }

    /// `config` lui-même est un lien : plus rien n'est lu ni effacé, pas même les
    /// profils réels qu'il contient.
    #[cfg(unix)]
    #[test]
    fn a_config_dir_that_is_a_link_is_never_followed() {
        let t = tempfile::tempdir().unwrap();
        let ailleurs = t.path().join("ailleurs");
        std::fs::create_dir_all(ailleurs.join("1")).unwrap();
        std::fs::write(ailleurs.join("1").join(".credentials.json"), "temoin").unwrap();
        let inst = t.path().join("inst");
        std::fs::create_dir_all(&inst).unwrap();
        std::os::unix::fs::symlink(&ailleurs, inst.join("config")).unwrap();
        let root = Root::new(inst.to_str().unwrap(), PathStyle::Unix).unwrap();
        let env = Env::for_tests(t.path().to_path_buf());
        let r = purge(&env, &root, None).unwrap();
        assert!(ailleurs.join("1").join(".credentials.json").exists());
        assert!(!ailleurs.join("1").join(".ccp-lock").exists());
        assert_eq!(r.removed, 0);
        assert!(!r.complete() && r.failures[0].contains("lien"), "{r:?}");
        let p = Profile::parse("1").unwrap();
        let r = purge(&env, &root, Some(&p)).unwrap();
        assert!(ailleurs.join("1").join(".credentials.json").exists());
        assert!(!r.complete(), "{r:?}");
    }

    /// Un fichier-lien DANS un vrai profil se supprime lui-même : la cible reste.
    #[cfg(unix)]
    #[test]
    fn a_secret_file_that_is_a_link_is_unlinked_not_followed() {
        let (t, root, env, d) = sandbox("1");
        let w = temoin(&t);
        std::os::unix::fs::symlink(w.join(".credentials.json"), d.join(".credentials.json"))
            .unwrap();
        let r = purge(&env, &root, None).unwrap();
        temoin_intact(&w);
        assert!(std::fs::symlink_metadata(d.join(".credentials.json")).is_err());
        assert!(r.complete(), "{r:?}");
    }

    #[test]
    fn a_missing_profile_folder_is_not_resurrected_by_the_lock() {
        let t = tempfile::tempdir().unwrap();
        let root = Root::new(t.path().to_str().unwrap(), PathStyle::Unix).unwrap();
        let env = Env::for_tests(t.path().to_path_buf());
        let p = Profile::parse("fantome").unwrap();
        let r = purge(&env, &root, Some(&p)).unwrap();
        assert!(r.complete());
        assert!(!root.profile(&p).dir.exists());
    }
}
