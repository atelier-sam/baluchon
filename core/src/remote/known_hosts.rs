//! `known_hosts` PROPRE au portable : `<racine>/config/remote/known_hosts`.
//!
//! La clé d'hôte du Mac de l'utilisateur (profil `config/remote.conf`) y est pré-posée AVANT
//! la première connexion, et ssh tourne en `StrictHostKeyChecking=yes` : il n'existe aucun
//! « voulez-vous continuer ? » où un utilisateur pourrait taper « yes » sans savoir. Le
//! fichier du système et celui de l'utilisateur ne sont jamais lus (ni écrits) : le
//! portable ne dépend pas du PC.

use super::conf::HostPin;
use crate::atomic::write_atomic;
use crate::error::{CcpError, Result};
use std::fs;
use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostKnowledge {
    /// Hôte du profil : la clé épinglée par `config/remote.conf` est en place.
    Pinned,
    /// Un autre hôte, déjà présent dans le fichier.
    Known,
    /// Un autre hôte, absent : ssh refusera sans `--accept-new-host-key`.
    Unknown,
}

/// Les noms d'hôte listés en tête d'une ligne `known_hosts` (virgules), sans les
/// lignes de commentaire, les marqueurs (`@revoked`…) ni les entrées hachées.
fn line_hosts(line: &str) -> Vec<&str> {
    let line = line.trim();
    if line.is_empty() || line.starts_with('#') || line.starts_with('@') || line.starts_with('|') {
        return Vec::new();
    }
    line.split_whitespace()
        .next()
        .map(|f| f.split(',').collect())
        .unwrap_or_default()
}

fn mentions(line: &str, host: &str) -> bool {
    let bracketed = format!("[{host}]:22");
    line_hosts(line)
        .iter()
        .any(|h| h.eq_ignore_ascii_case(host) || h.eq_ignore_ascii_case(&bracketed))
}

/// Contenu voulu du fichier pour `host`, et ce qu'on sait de lui. `pin` : la clé que le
/// profil épingle pour CET hôte (`Target::pin`), sinon `None`.
pub fn render(existing: &str, host: &str, pin: Option<&HostPin>) -> (String, HostKnowledge) {
    if let Some(pin) = pin {
        // Le profil fait autorité pour son hôte : toute autre clé pour ce nom (ancienne, ou
        // posée par erreur) est retirée, jamais « mise à jour » par ssh.
        let mut out: String = existing
            .lines()
            .filter(|l| !mentions(l, host))
            .map(|l| format!("{l}\n"))
            .collect();
        out.push_str(&pin.line(host));
        out.push('\n');
        return (out, HostKnowledge::Pinned);
    }
    let known = existing.lines().any(|l| mentions(l, host));
    let mut out = existing.to_string();
    if !out.is_empty() && !out.ends_with('\n') {
        out.push('\n');
    }
    (
        out,
        if known {
            HostKnowledge::Known
        } else {
            HostKnowledge::Unknown
        },
    )
}

/// Met le fichier en état pour `host` (ne l'écrit que s'il change).
pub fn ensure_file(path: &Path, host: &str, pin: Option<&HostPin>) -> Result<HostKnowledge> {
    let existing = match fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(e) => {
            return Err(CcpError::Internal(format!(
                "known_hosts du portable illisible ({}) : {e}",
                path.display()
            )))
        }
    };
    let (want, knowledge) = render(&existing, host, pin);
    if want != existing {
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir).map_err(|e| {
                CcpError::Internal(format!(
                    "dossier {} impossible à créer : {e}",
                    dir.display()
                ))
            })?;
        }
        write_atomic(path, want.as_bytes()).map_err(|e| {
            CcpError::Internal(format!(
                "known_hosts du portable impossible à écrire ({}) : {e}",
                path.display()
            ))
        })?;
    }
    Ok(knowledge)
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOST: &str = "mac.example.com";

    fn pin() -> HostPin {
        HostPin {
            key_type: "ssh-ed25519".into(),
            key_b64: "AAAAC3NzaC1lZDI1NTE5AAAAIEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLE0".into(),
        }
    }

    #[test]
    fn empty_file_gets_the_pinned_line_for_the_profile_host() {
        let (t, k) = render("", HOST, Some(&pin()));
        assert_eq!(k, HostKnowledge::Pinned);
        assert_eq!(t, format!("{}\n", pin().line(HOST)));
    }

    #[test]
    fn a_wrong_key_for_the_profile_host_is_replaced_others_are_kept() {
        let old = format!(
            "# commentaire\n{HOST} ssh-ed25519 AAAAFAUSSECLE\n\
             {HOST},192.0.2.1 ssh-rsa AAAAAUTRE\n\
             autre.example ssh-ed25519 AAAAKEEP\n"
        );
        let (t, k) = render(&old, HOST, Some(&pin()));
        assert_eq!(k, HostKnowledge::Pinned);
        assert!(!t.contains("AAAAFAUSSECLE") && !t.contains("AAAAAUTRE"));
        assert!(t.contains("# commentaire\n"));
        assert!(t.contains("autre.example ssh-ed25519 AAAAKEEP\n"));
        assert_eq!(t.matches(&pin().line(HOST)).count(), 1);
    }

    #[test]
    fn rendering_twice_changes_nothing() {
        let (once, _) = render("autre ssh-ed25519 K\n", HOST, Some(&pin()));
        let (twice, _) = render(&once, HOST, Some(&pin()));
        assert_eq!(once, twice);
    }

    #[test]
    fn without_a_pin_the_profile_host_is_just_unknown_never_invented() {
        // Un hôte sans clé épinglée (profil sans host_key, ou --host autre) ne reçoit AUCUNE
        // ligne : ssh refusera sans --accept-new-host-key.
        let (t, k) = render("", HOST, None);
        assert_eq!(k, HostKnowledge::Unknown);
        assert_eq!(t, "");
    }

    #[test]
    fn other_hosts_are_known_or_unknown_but_never_rewritten() {
        let f = "autre.example ssh-ed25519 K\n[h2.example]:22 ssh-rsa R\n";
        assert_eq!(render(f, "autre.example", None).1, HostKnowledge::Known);
        assert_eq!(render(f, "h2.example", None).1, HostKnowledge::Known);
        let (t, k) = render(f, "inconnu.example", None);
        assert_eq!(k, HostKnowledge::Unknown);
        assert_eq!(t, f);
        // Un nom qui en CONTIENT un autre n'est pas ce nom.
        assert_eq!(render(f, "example", None).1, HostKnowledge::Unknown);
    }

    #[test]
    fn file_is_created_with_parents_and_rewritten_only_on_change() {
        let t = tempfile::tempdir().unwrap();
        let p = t.path().join("Ma clé/config/remote/known_hosts");
        assert_eq!(
            ensure_file(&p, HOST, Some(&pin())).unwrap(),
            HostKnowledge::Pinned
        );
        let m1 = fs::metadata(&p).unwrap().modified().unwrap();
        std::thread::sleep(std::time::Duration::from_millis(20));
        ensure_file(&p, HOST, Some(&pin())).unwrap();
        assert_eq!(fs::metadata(&p).unwrap().modified().unwrap(), m1);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&p).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
    }
}
