//! Trousseau macOS, via `/usr/bin/security` (pas de crate security-framework :
//! c'est exactement la porte que Claude lui-même emprunte, donc les mêmes ACL).
//!
//! La partie « nom de service » est pure et compilée partout (testée sur le
//! vecteur réel) ; les appels à `security` ne sont compilés que sous macOS.

use crate::util::hex_encode;
use sha2::{Digest, Sha256};
use unicode_normalization::UnicodeNormalization;

pub const SERVICE_BASE: &str = "Claude Code-credentials";

/// Service d'un profil : `Claude Code-credentials-` + sha256(NFC(cfg))[:8 hex].
/// Le chemin est celui donné TEL QUEL dans `CLAUDE_CONFIG_DIR`.
pub fn service_name(cfg: &str) -> String {
    let nfc: String = cfg.nfc().collect();
    let digest = Sha256::digest(nfc.as_bytes());
    format!("{SERVICE_BASE}-{}", hex_encode(&digest[..4]))
}

/// Vrai pour `Claude Code-credentials-<8 hex>` : un profil à `CLAUDE_CONFIG_DIR`.
/// Faux pour le service nu (la session de la machine) et pour tout autre nom.
pub fn is_portable_service(svc: &str) -> bool {
    svc.strip_prefix(SERVICE_BASE)
        .and_then(|rest| rest.strip_prefix('-'))
        .is_some_and(|h| h.len() == 8 && h.chars().all(|c| c.is_ascii_hexdigit()))
}

#[derive(Debug)]
pub enum KcError {
    /// Trousseau verrouillé / interaction refusée / autorisation en attente.
    Locked(String),
    Failed(String),
}

impl std::fmt::Display for KcError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            KcError::Locked(m) | KcError::Failed(m) => f.write_str(m),
        }
    }
}

/// Extrait `"acct"<blob>="…"` de la sortie d'attributs de `security`.
/// Gère la forme hexadécimale `0x… "texte"` des valeurs non ASCII.
pub fn parse_acct(attrs: &str) -> Option<String> {
    for line in attrs.lines() {
        let line = line.trim();
        let Some(rest) = line.strip_prefix("\"acct\"<blob>=") else {
            continue;
        };
        let rest = rest.trim();
        if rest.starts_with("<NULL>") {
            return None;
        }
        if let Some(h) = rest.strip_prefix("0x") {
            let digits: String = h.chars().take_while(|c| c.is_ascii_hexdigit()).collect();
            return crate::util::hex_decode(&digits).and_then(|b| String::from_utf8(b).ok());
        }
        let inner = rest.strip_prefix('"')?;
        let end = inner.rfind('"')?;
        return Some(inner[..end].to_string());
    }
    None
}

/// `-w` affiche en hexadécimal une donnée qui n'est pas du texte imprimable :
/// on rend le JSON dans les deux cas.
pub fn decode_password_output(out: &str) -> String {
    let t = out.trim_end_matches(['\n', '\r']);
    if serde_json::from_str::<serde_json::Value>(t).is_ok() {
        return t.to_string();
    }
    if let Some(bytes) = crate::util::hex_decode(t.trim()) {
        if let Ok(s) = String::from_utf8(bytes) {
            if serde_json::from_str::<serde_json::Value>(&s).is_ok() {
                return s;
            }
        }
    }
    t.to_string()
}

/// Compte que Claude utilise quand `$USER` est absent de son contexte.
pub const FALLBACK_ACCT: &str = "unknown";

/// Un item du Trousseau : le compte sous lequel il est rangé et son contenu JSON.
pub struct Item {
    pub acct: String,
    pub secret: String,
}

/// Parmi plusieurs items du MÊME service (compte `$USER`, compte `unknown`,
/// premier trouvé), retient celui dont le jeton d'accès expire le plus tard.
///
/// WHY (défaut #9) : Claude range parfois l'item sous `unknown` (variable `USER`
/// absente de son contexte) pendant que l'item `$USER` reste périmé. Lire
/// `$USER` d'abord faisait renouveler un login mort, voire écraser le bon.
///
/// Les candidats arrivent dans l'ordre historique de lecture (`$USER`, puis le
/// premier trouvé, puis `unknown`). Dès qu'UNE date est illisible on ne compare
/// rien : le premier candidat l'emporte, exactement comme avant le correctif.
/// À dates égales, le premier l'emporte aussi.
pub fn pick_freshest(candidates: Vec<Item>) -> Option<Item> {
    let dates: Vec<Option<i64>> = candidates
        .iter()
        .map(|c| {
            super::CredBlob::parse(&c.secret)
                .ok()
                .and_then(|b| b.expires_at_ms())
        })
        .collect();
    if dates.iter().any(Option::is_none) {
        return candidates.into_iter().next();
    }
    let mut best: Option<usize> = None;
    for (i, d) in dates.iter().enumerate() {
        if best.is_none_or(|b| d > &dates[b]) {
            best = Some(i);
        }
    }
    best.and_then(|i| candidates.into_iter().nth(i))
}

#[cfg(target_os = "macos")]
pub use mac::*;

#[cfg(target_os = "macos")]
mod mac {
    use super::*;
    use crate::env::Env;
    use crate::util::run_bounded;
    use std::process::Command;
    use std::time::Duration;

    pub const SECURITY: &str = "/usr/bin/security";
    /// Au-delà, une fenêtre d'autorisation attend sans doute un clic de l'utilisateur.
    pub const TIMEOUT: Duration = Duration::from_secs(8);

    /// Traduit le code de sortie de `security` (partagé avec l'édition qui écrit).
    pub fn classify(code: Option<i32>, stderr: &str) -> KcError {
        let first = stderr.lines().next().unwrap_or("").trim().to_string();
        match code {
            // 36 = interaction non permise, 51 = trousseau absent/verrouillé selon macOS.
            Some(36) | Some(51) => KcError::Locked("Trousseau verrouillé".into()),
            None => KcError::Locked("Trousseau : autorisation en attente (délai dépassé)".into()),
            Some(c) => KcError::Failed(format!("security a échoué (code {c}) : {first}")),
        }
    }

    fn base(env: &Env, args: &[&str]) -> Command {
        let mut c = Command::new(SECURITY);
        c.args(args);
        if let Some(kc) = &env.keychain {
            c.arg(kc);
        }
        c
    }

    pub fn read_secret(env: &Env, acct: &str, svc: &str) -> Result<Option<String>, KcError> {
        let mut c = base(env, &["find-generic-password", "-a", acct, "-s", svc, "-w"]);
        let out = run_bounded(&mut c, None, TIMEOUT)
            .map_err(|e| KcError::Failed(format!("security : {e}")))?;
        match out.code() {
            Some(0) => Ok(Some(decode_password_output(&out.stdout_str()))),
            Some(44) => Ok(None),
            c => Err(classify(c, &out.stderr_str())),
        }
    }

    fn lookup_acct(env: &Env, svc: &str) -> Result<Option<String>, KcError> {
        let mut c = base(env, &["find-generic-password", "-s", svc]);
        let out = run_bounded(&mut c, None, TIMEOUT)
            .map_err(|e| KcError::Failed(format!("security : {e}")))?;
        match out.code() {
            Some(0) => Ok(parse_acct(&out.stdout_str())),
            Some(44) => Ok(None),
            c => Err(classify(c, &out.stderr_str())),
        }
    }

    /// Lit l'item du service. Compte attendu = `$USER` (comme Claude) ; on
    /// retrouve aussi le compte `unknown` et le premier item du service, puis on
    /// retient le plus frais (voir [`pick_freshest`], défaut #9). L'item retenu
    /// donne son compte à la réécriture : aucun doublon n'est créé.
    pub fn find(env: &Env, svc: &str) -> Result<Option<Item>, KcError> {
        // Ordre historique : `$USER`, puis le premier item du service, puis `unknown`.
        let mut accts: Vec<String> = vec![env.user.clone()];
        if let Some(first) = lookup_acct(env, svc)? {
            accts.push(first);
        }
        accts.push(FALLBACK_ACCT.to_string());
        let mut candidates: Vec<Item> = Vec::new();
        for acct in accts {
            if candidates.iter().any(|c| c.acct == acct) {
                continue;
            }
            if let Some(secret) = read_secret(env, &acct, svc)? {
                candidates.push(Item { acct, secret });
            }
        }
        Ok(pick_freshest(candidates))
    }

    /// Supprime tous les items du service (un appel de `security` en retire un).
    /// Renvoie le nombre supprimé.
    pub fn delete_all(env: &Env, svc: &str) -> Result<usize, KcError> {
        // Garde-fou ABSOLU : le service SANS suffixe est la session de la machine
        // (le Claude Code normal de la machine). On ne supprime que des services suffixés.
        if !is_portable_service(svc) {
            return Err(KcError::Failed(
                "refus de supprimer un service qui n'est pas celui d'un profil portable".into(),
            ));
        }
        let mut n = 0;
        for _ in 0..8 {
            let mut c = base(env, &["delete-generic-password", "-s", svc]);
            let out = run_bounded(&mut c, None, TIMEOUT)
                .map_err(|e| KcError::Failed(format!("security : {e}")))?;
            match out.code() {
                Some(0) => n += 1,
                Some(44) => break,
                c => return Err(classify(c, &out.stderr_str())),
            }
        }
        Ok(n)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_suffixed_services_are_portable() {
        assert!(is_portable_service("Claude Code-credentials-72588510"));
        assert!(!is_portable_service("Claude Code-credentials"));
        assert!(!is_portable_service("Claude Code-credentials-"));
        assert!(!is_portable_service("Claude Code-credentials-zzzzzzzz"));
        assert!(!is_portable_service("Claude Code-credentials-725885100"));
        assert!(!is_portable_service("autre-72588510"));
    }

    #[test]
    fn known_vector() {
        // Le suffixe est sha256(chemin NFC)[:8], recalculé ici avec un outil INDÉPENDANT :
        //   printf '%s' '/Users/alice/.config/outil/profiles/work' | shasum -a 256 | cut -c1-8
        // Un vecteur mesuré sur un item réel de Claude Code (qui prouve que c'est bien ce
        // nom que `claude` lit) est vérifié à part, dans l'édition qui dispose de cet item.
        assert_eq!(
            service_name("/Users/alice/.config/outil/profiles/work"),
            "Claude Code-credentials-79af15cc"
        );
    }

    #[test]
    fn trailing_slash_changes_the_hash_so_it_is_stripped_upstream() {
        // Le hash porte sur la chaîne exacte : `Root` retire le slash final AVANT.
        assert_ne!(service_name("/a/b"), service_name("/a/b/"));
    }

    #[test]
    fn nfd_and_nfc_give_the_same_service() {
        let nfc = "/Volumes/Clé/été/config/1";
        let nfd = "/Volumes/Cle\u{301}/e\u{301}te\u{301}/config/1";
        assert_ne!(nfc, nfd);
        assert_eq!(service_name(nfc), service_name(nfd));
    }

    #[test]
    fn spaces_are_hashed_verbatim() {
        assert_ne!(service_name("/a b/c"), service_name("/a  b/c"));
        assert!(service_name("/a b/c").starts_with("Claude Code-credentials-"));
        assert_eq!(
            service_name("/a b/c").len(),
            "Claude Code-credentials-".len() + 8
        );
    }

    #[test]
    fn parses_acct_plain_and_hex() {
        let plain = "class: \"genp\"\nattributes:\n    \"acct\"<blob>=\"alice\"\n    \"svce\"<blob>=\"x\"\n";
        assert_eq!(parse_acct(plain).as_deref(), Some("alice"));
        let hexed = "    \"acct\"<blob>=0x73616DC3A9  \"samé\"\n";
        assert_eq!(parse_acct(hexed).as_deref(), Some("samé"));
        assert_eq!(parse_acct("    \"acct\"<blob>=<NULL>\n"), None);
        assert_eq!(parse_acct("rien"), None);
    }

    fn item(acct: &str, expires_at: &str) -> Item {
        Item {
            acct: acct.into(),
            secret: format!(
                r#"{{"claudeAiOauth":{{"accessToken":"a","expiresAt":{expires_at}}}}}"#
            ),
        }
    }

    fn picked(items: Vec<Item>) -> Option<String> {
        pick_freshest(items).map(|i| i.acct)
    }

    #[test]
    fn a_fresh_unknown_item_beats_a_stale_user_item() {
        let got = picked(vec![item("alice", "1000"), item("unknown", "5000")]);
        assert_eq!(got.as_deref(), Some("unknown"));
    }

    #[test]
    fn a_fresher_user_item_still_wins() {
        let got = picked(vec![item("alice", "9000"), item("unknown", "5000")]);
        assert_eq!(got.as_deref(), Some("alice"));
    }

    #[test]
    fn a_single_item_is_returned_and_no_item_gives_none() {
        assert_eq!(picked(vec![item("seul", "1")]).as_deref(), Some("seul"));
        assert!(pick_freshest(vec![]).is_none());
    }

    #[test]
    fn equal_dates_keep_the_historical_order() {
        let got = picked(vec![
            item("alice", "7"),
            item("autre", "7"),
            item("unknown", "7"),
        ]);
        assert_eq!(got.as_deref(), Some("alice"));
    }

    #[test]
    fn three_candidates_the_latest_expiry_wins_wherever_it_sits() {
        let got = picked(vec![
            item("alice", "100"),
            item("premier", "900"),
            item("unknown", "300"),
        ]);
        assert_eq!(got.as_deref(), Some("premier"));
    }

    #[test]
    fn an_unreadable_date_means_no_comparison_and_the_first_candidate() {
        // JSON corrompu, date absente ou textuelle : on ne devine pas.
        let broken = Item {
            acct: "alice".into(),
            secret: "pas du json".into(),
        };
        assert_eq!(
            picked(vec![broken, item("unknown", "5000")]).as_deref(),
            Some("alice")
        );
        let textual = Item {
            acct: "alice".into(),
            secret: r#"{"claudeAiOauth":{"expiresAt":"demain"}}"#.into(),
        };
        assert_eq!(
            picked(vec![textual, item("unknown", "5000")]).as_deref(),
            Some("alice")
        );
        let missing = Item {
            acct: "alice".into(),
            secret: r#"{"claudeAiOauth":{}}"#.into(),
        };
        assert_eq!(
            picked(vec![item("unknown", "5000"), missing]).as_deref(),
            Some("unknown")
        );
    }

    #[test]
    fn decodes_hex_password_output() {
        let json = "{\"claudeAiOauth\":{\"accessToken\":\"é\"}}";
        let hex = crate::util::hex_encode(json.as_bytes());
        assert_eq!(decode_password_output(&format!("{hex}\n")), json);
        assert_eq!(decode_password_output(&format!("{json}\n")), json);
    }
}
