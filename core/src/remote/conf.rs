//! Réglages de `remote` : hôte et utilisateur (conf), confiance dans CET ordinateur
//! (marqueur du wizard) et nettoyage des jetons Cloudflare Access d'un ordinateur invité.

use crate::error::{CcpError, Result};
use crate::root::Root;
use crate::util::run_bounded;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

/// Fichier de réglages : `<racine>/config/remote.conf`, lignes `clé = valeur`, `#` pour les
/// commentaires, guillemets facultatifs. Clés : `host`, `user`, `host_key_type` + `host_key`
/// (la clé d'hôte du Mac, relevée côté Mac par `ssh-keyscan localhost`) et `label` (nom du
/// LaunchAgent du tunnel, côté Mac). Le public n'a AUCUNE valeur par défaut : le profil du
/// Mac vit dans la racine (la clé USB l'emporte avec elle), jamais dans le binaire.
pub const CONF_FILE: &str = "remote.conf";

/// Clé d'hôte épinglée pour l'hôte du profil : posée dans le known_hosts du portable AVANT
/// toute connexion, pour que la première ne repose pas sur « faire confiance au premier venu ».
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostPin {
    pub key_type: String,
    pub key_b64: String,
}

impl HostPin {
    /// Ligne `known_hosts` pour `host`.
    pub fn line(&self, host: &str) -> String {
        format!("{host} {} {}", self.key_type, self.key_b64)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Target {
    pub host: String,
    pub user: String,
    /// Présente seulement si `host` est l'hôte du profil ET que le profil porte sa clé.
    pub pin: Option<HostPin>,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct RawConf {
    pub host: Option<String>,
    pub user: Option<String>,
    pub host_key_type: Option<String>,
    pub host_key: Option<String>,
    pub label: Option<String>,
}

/// Message du public quand aucun Mac n'est configuré : il propose la mise en place pour
/// SON Mac, il ne se connecte jamais à un hôte par défaut.
pub const NO_MAC: &str = "aucun Mac n'est configuré dans ce portable. Pour relier ce PC à TON Mac : \
(1) sur le Mac, lance « baluchon-core remote setup-mac --host <nom-public-du-Mac> » (tunnel Cloudflare + Access) ; \
(2) écris config/remote.conf avec host, user, host_key_type et host_key (clé d'hôte du Mac : ssh-keyscan localhost) ; \
ou passe --host et --user (première connexion à un hôte inconnu : --accept-new-host-key).";

/// Type de clé d'hôte (`ssh-ed25519`, `ecdsa-sha2-nistp256`…) : il finit dans une option ssh
/// (`HostKeyAlgorithms=`) et dans une ligne `known_hosts`, donc rien d'autre que ce jeu.
pub fn valid_key_type(t: &str) -> bool {
    !t.is_empty()
        && t.len() <= 64
        && (t.starts_with("ssh-") || t.starts_with("ecdsa-") || t.starts_with("sk-"))
        && t.bytes().all(|b| {
            b.is_ascii_lowercase() || b.is_ascii_digit() || matches!(b, b'-' | b'@' | b'.')
        })
}

/// Clé publique en base64 (pas d'espace : une ligne `known_hosts` a trois champs).
pub fn valid_key_b64(k: &str) -> bool {
    !k.is_empty()
        && k.len() <= 8192
        && k.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'+' | b'/' | b'='))
}

/// Nom de LaunchAgent (domaine inversé) : sans espace ni métacaractère, il finit dans un nom
/// de fichier `.plist` et dans une commande `launchctl`.
pub fn valid_label(l: &str) -> bool {
    !l.is_empty()
        && l.len() <= 128
        && !l.starts_with(['-', '.'])
        && l.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// Nom d'hôte DNS sûr : jamais de tiret en tête (ssh y verrait une option), jamais
/// d'espace ni de métacaractère. C'est la seule barrière entre un fichier de conf
/// (ou un argument) et la ligne de commande de ssh.
pub fn valid_host(h: &str) -> bool {
    !h.is_empty()
        && h.len() <= 253
        && !h.starts_with(['-', '.'])
        && !h.ends_with('.')
        && !h.contains("..")
        && h.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
}

pub fn valid_user(u: &str) -> bool {
    !u.is_empty()
        && u.len() <= 64
        && !u.starts_with(['-', '.'])
        && u.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'_' || b == b'-')
}

fn unquote(v: &str) -> &str {
    let v = v.trim();
    for q in ['"', '\''] {
        if let Some(inner) = v.strip_prefix(q).and_then(|r| r.strip_suffix(q)) {
            return inner;
        }
    }
    v
}

pub fn parse_conf(text: &str, source: &str) -> Result<RawConf> {
    let mut conf = RawConf::default();
    for (i, raw) in text.lines().enumerate() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((k, v)) = line.split_once('=') else {
            return Err(CcpError::Usage(format!(
                "{source}, ligne {} : « {line} » n'est pas de la forme clé = valeur",
                i + 1
            )));
        };
        let v = unquote(v);
        match k.trim() {
            "host" => {
                if !valid_host(v) {
                    return Err(CcpError::Usage(format!(
                        "{source}, ligne {} : « {v} » n'est pas un nom d'hôte valide",
                        i + 1
                    )));
                }
                conf.host = Some(v.to_string());
            }
            "user" => {
                if !valid_user(v) {
                    return Err(CcpError::Usage(format!(
                        "{source}, ligne {} : « {v} » n'est pas un nom d'utilisateur valide",
                        i + 1
                    )));
                }
                conf.user = Some(v.to_string());
            }
            "host_key_type" => {
                if !valid_key_type(v) {
                    return Err(CcpError::Usage(format!(
                        "{source}, ligne {} : « {v} » n'est pas un type de clé d'hôte valide",
                        i + 1
                    )));
                }
                conf.host_key_type = Some(v.to_string());
            }
            "host_key" => {
                if !valid_key_b64(v) {
                    return Err(CcpError::Usage(format!(
                        "{source}, ligne {} : host_key n'est pas une clé publique en base64",
                        i + 1
                    )));
                }
                conf.host_key = Some(v.to_string());
            }
            "label" => {
                if !valid_label(v) {
                    return Err(CcpError::Usage(format!(
                        "{source}, ligne {} : « {v} » n'est pas un nom de LaunchAgent valide",
                        i + 1
                    )));
                }
                conf.label = Some(v.to_string());
            }
            // Clé inconnue : ignorée, pour qu'une conf plus récente reste lisible.
            _ => {}
        }
    }
    // Une clé sans son type (ou l'inverse) ne s'épingle pas : on refuse plutôt que de
    // laisser croire que l'hôte est protégé.
    if conf.host_key_type.is_some() != conf.host_key.is_some() {
        return Err(CcpError::Usage(format!(
            "{source} : host_key_type et host_key vont ensemble (l'un sans l'autre n'épingle rien)"
        )));
    }
    if conf.host_key.is_some() && conf.host.is_none() {
        return Err(CcpError::Usage(format!(
            "{source} : host_key sans host (on ne sait pas à quel Mac elle appartient)"
        )));
    }
    Ok(conf)
}

pub fn conf_path(root: &Root) -> PathBuf {
    root.path().join("config").join(CONF_FILE)
}

pub fn load(root: &Root) -> Result<RawConf> {
    let p = conf_path(root);
    match fs::read_to_string(&p) {
        Ok(t) => parse_conf(&t, &p.display().to_string()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(RawConf::default()),
        Err(e) => Err(CcpError::Internal(format!(
            "{} illisible : {e}",
            p.display()
        ))),
    }
}

/// Argument de la ligne de commande > fichier de conf. AUCUNE valeur par défaut : sans
/// profil, on refuse avec la marche à suivre (`NO_MAC`) au lieu de viser un hôte codé en dur.
pub fn resolve(cli_host: Option<&str>, cli_user: Option<&str>, conf: RawConf) -> Result<Target> {
    let host = cli_host
        .map(str::to_string)
        .or_else(|| conf.host.clone())
        .ok_or_else(|| CcpError::Usage(NO_MAC.to_string()))?;
    let user = cli_user.map(str::to_string).or(conf.user.clone()).ok_or_else(|| {
        CcpError::Usage(
            "utilisateur du Mac inconnu : passe --user ou écris « user = … » dans config/remote.conf"
                .into(),
        )
    })?;
    if !valid_host(&host) {
        return Err(CcpError::Usage(format!(
            "« {host} » n'est pas un nom d'hôte valide"
        )));
    }
    if !valid_user(&user) {
        return Err(CcpError::Usage(format!(
            "« {user} » n'est pas un nom d'utilisateur valide"
        )));
    }
    // La clé du profil ne vaut QUE pour l'hôte du profil : `--host autre` ne la reprend pas.
    let pin = match (&conf.host, conf.host_key_type, conf.host_key) {
        (Some(h), Some(key_type), Some(key_b64)) if h.eq_ignore_ascii_case(&host) => {
            Some(HostPin { key_type, key_b64 })
        }
        _ => None,
    };
    Ok(Target { host, user, pin })
}

// ------------------------------------------------------------ confiance (wizard)

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Trust {
    Trusted,
    /// Ordinateur qui n'est pas celui de l'utilisateur : on ne laisse rien de sa session dessus.
    Guest,
    /// Aucun marqueur : le wizard n'a pas posé la question (Windows, ou lancement direct).
    Unknown,
}

/// Même calcul que `host_key()` du wizard : `hostname | tr -c 'a-zA-Z0-9_.-' '_'`.
/// Le saut de ligne final de `hostname` devient lui aussi un `_` : c'est le nom réel du
/// marqueur. Deux variantes (par caractère / par octet) car `tr` dépend de la locale.
pub fn host_keys(hostname: &str) -> Vec<String> {
    let allowed = |c: char| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-');
    let with_nl = format!("{hostname}\n");
    let per_char: String = with_nl
        .chars()
        .map(|c| if allowed(c) { c } else { '_' })
        .collect();
    let per_byte: String = with_nl
        .bytes()
        .map(|b| {
            if b.is_ascii() && allowed(b as char) {
                b as char
            } else {
                '_'
            }
        })
        .collect();
    let mut v = vec![per_char];
    if v[0] != per_byte {
        v.push(per_byte);
    }
    v
}

pub fn read_trust(root: &Root, hostname: &str) -> Trust {
    for key in host_keys(hostname) {
        let p = root.path().join("config").join(".hosts").join(key);
        if let Ok(t) = fs::read_to_string(p) {
            return match t.trim() {
                "guest" => Trust::Guest,
                "trusted" => Trust::Trusted,
                _ => Trust::Unknown,
            };
        }
    }
    Trust::Unknown
}

/// Nom de cet ordinateur, lu comme le wizard le lit (`hostname`).
pub fn local_hostname() -> Option<String> {
    let out = run_bounded(&mut Command::new("hostname"), None, Duration::from_secs(3)).ok()?;
    let name = out.stdout_str().trim().to_string();
    (out.code() == Some(0) && !name.is_empty()).then_some(name)
}

// ------------------------------------------------------- jetons Cloudflare Access

fn is_hex(s: &str) -> bool {
    s.len() >= 32 && s.bytes().all(|b| b.is_ascii_hexdigit())
}

/// Fichier de jeton Access que cloudflared range dans `~/.cloudflared/` :
/// - `<hôte>-<aud>-token` : l'application (ici `mac.example.com`) ;
/// - `<équipe>.cloudflareaccess.com-org-token` : l'IDENTITÉ de l'équipe, qui ouvrirait
///   aussi les autres applications Access de l'équipe tant qu'elle vit.
///
/// Le suffixe `.lock` est l'ombre que cloudflared laisse à côté. Reconnaissance STRICTE :
/// rien d'autre du dossier (certificat, jeton du tunnel côté Mac) n'est jamais touché.
pub fn is_access_token_name(name: &str, host: &str) -> bool {
    let base = name.strip_suffix(".lock").unwrap_or(name);
    if let Some(mid) = base
        .strip_prefix(host)
        .and_then(|r| r.strip_prefix('-'))
        .and_then(|r| r.strip_suffix("-token"))
    {
        if is_hex(mid) {
            return true;
        }
    }
    base.strip_suffix(".cloudflareaccess.com-org-token")
        .is_some_and(|team| {
            !team.is_empty() && team.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
        })
}

/// Efface les jetons Access de `<home>/.cloudflared` ; renvoie leurs noms (jamais leur contenu).
pub fn purge_access_tokens(home: &Path, host: &str) -> Vec<String> {
    let dir = home.join(".cloudflared");
    let mut removed = Vec::new();
    let Ok(rd) = fs::read_dir(&dir) else {
        return removed;
    };
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        if is_access_token_name(&name, host)
            && e.path().is_file()
            && fs::remove_file(e.path()).is_ok()
        {
            removed.push(name);
        }
    }
    removed.sort();
    removed
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::root::PathStyle;

    const AUD: &str = "00d26537aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    #[test]
    fn hosts_and_users_cannot_smuggle_ssh_options() {
        for ok in ["mac.example.com", "h", "a-b.c", "10.0.0.1"] {
            assert!(valid_host(ok), "{ok}");
        }
        for bad in [
            "",
            "-oProxyCommand=x",
            ".x",
            "x.",
            "a..b",
            "a b",
            "a;b",
            "a/b",
            "é.fr",
            "a@b",
            "a:22",
        ] {
            assert!(!valid_host(bad), "{bad:?}");
        }
        assert!(valid_user("alice") && valid_user("a.b_c-d"));
        for bad in ["", "-x", ".x", "a b", "a@b", "é", "a;b"] {
            assert!(!valid_user(bad), "{bad:?}");
        }
    }

    #[test]
    fn conf_parses_comments_quotes_and_unknown_keys() {
        let c = parse_conf(
            "# mon Mac\nhost = \"h.example\"\n\nuser='alice'\nfutur = 1\n",
            "remote.conf",
        )
        .unwrap();
        assert_eq!(c.host.as_deref(), Some("h.example"));
        assert_eq!(c.user.as_deref(), Some("alice"));
    }

    const KEY: &str = "AAAAC3NzaC1lZDI1NTE5AAAAIEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLE0";

    #[test]
    fn the_profile_carries_host_user_pin_and_label() {
        let text = format!(
            "host = mac.example.com\nuser = alice\nhost_key_type = ssh-ed25519\n\
             host_key = {KEY}\nlabel = com.example.tunnel\n"
        );
        let c = parse_conf(&text, "remote.conf").unwrap();
        assert_eq!(c.host_key_type.as_deref(), Some("ssh-ed25519"));
        assert_eq!(c.host_key.as_deref(), Some(KEY));
        assert_eq!(c.label.as_deref(), Some("com.example.tunnel"));
        let t = resolve(None, None, c).unwrap();
        let pin = t.pin.expect("le profil épingle la clé de son hôte");
        assert_eq!(
            pin.line(&t.host),
            format!("mac.example.com ssh-ed25519 {KEY}")
        );
    }

    #[test]
    fn a_half_pin_or_a_pin_without_host_is_refused_not_ignored() {
        // Un profil qui CROIT épingler et n'épingle rien est pire qu'un profil sans clé.
        for bad in [
            format!("host = h.example\nhost_key = {KEY}\n"),
            "host = h.example\nhost_key_type = ssh-ed25519\n".to_string(),
            format!("host_key_type = ssh-ed25519\nhost_key = {KEY}\n"),
        ] {
            let e = parse_conf(&bad, "remote.conf").unwrap_err();
            assert_eq!(e.exit_code(), 2, "{bad}");
        }
    }

    #[test]
    fn key_type_key_and_label_cannot_smuggle_anything() {
        for bad in [
            "host_key_type = ssh-ed25519 -oProxyCommand=x",
            "host_key_type = rsa",
            "host_key_type = SSH-ED25519",
            "host_key_type = ssh-ed25519\nhost_key = AAAA BBBB",
            "host = h.example\nhost_key_type = ssh-ed25519\nhost_key = AAAA\nBBBB",
            "label = ../evil",
            "label = a b",
            "label = -x",
            "label = a;b",
            "label = ",
        ] {
            assert!(parse_conf(bad, "f").is_err(), "{bad:?}");
        }
        assert!(
            valid_key_type("ecdsa-sha2-nistp256") && valid_key_type("sk-ssh-ed25519@openssh.com")
        );
        assert!(valid_label("com.example.mon-tunnel_1"));
    }

    #[test]
    fn conf_errors_name_the_file_and_line() {
        let e = parse_conf(
            "host = ok.example\nhost = -oProxyCommand=x\n",
            "C:\\r\\remote.conf",
        )
        .unwrap_err();
        assert!(e.to_string().contains("remote.conf, ligne 2"), "{e}");
        assert_eq!(e.exit_code(), 2);
        assert!(parse_conf("n'importe quoi\n", "f").is_err());
    }

    #[test]
    fn precedence_is_cli_then_conf_and_there_is_no_default() {
        let conf = || RawConf {
            host: Some("conf.example".into()),
            user: Some("confuser".into()),
            ..RawConf::default()
        };
        let t = resolve(Some("cli.example"), None, conf()).unwrap();
        assert_eq!(
            (t.host.as_str(), t.user.as_str()),
            ("cli.example", "confuser")
        );
        let t = resolve(Some("cli.example"), Some("cliuser"), conf()).unwrap();
        assert_eq!(t.user, "cliuser");
        let from_conf = resolve(None, None, conf()).unwrap();
        assert_eq!(from_conf.host, "conf.example");
        assert!(resolve(Some("-bad"), None, conf()).is_err());
    }

    #[test]
    fn without_a_profile_the_public_refuses_cleanly_and_names_the_way_forward() {
        // Aucun hôte codé en dur : ni hôte, ni utilisateur -> refus de code 2 qui explique
        // comment mettre en place SON Mac. Un hôte seul ne suffit pas non plus.
        let e = resolve(None, None, RawConf::default()).unwrap_err();
        assert_eq!(e.exit_code(), 2);
        let m = e.to_string();
        assert!(m.contains("aucun Mac n'est configuré"), "{m}");
        assert!(
            m.contains("setup-mac") && m.contains("config/remote.conf"),
            "{m}"
        );
        let e = resolve(Some("h.example"), None, RawConf::default()).unwrap_err();
        assert_eq!(e.exit_code(), 2);
        assert!(e.to_string().contains("utilisateur du Mac inconnu"), "{e}");
        // --host et --user suffisent sans aucun fichier (première connexion à un hôte inconnu).
        let t = resolve(Some("h.example"), Some("u"), RawConf::default()).unwrap();
        assert!(t.pin.is_none());
    }

    #[test]
    fn the_pin_belongs_to_the_profile_host_only() {
        let conf = || RawConf {
            host: Some("Mac.Example.Com".into()),
            user: Some("alice".into()),
            host_key_type: Some("ssh-ed25519".into()),
            host_key: Some(KEY.into()),
            label: None,
        };
        // Même hôte (casse comprise) : la clé suit.
        assert!(resolve(Some("mac.example.com"), None, conf())
            .unwrap()
            .pin
            .is_some());
        // Autre hôte : la clé du profil ne doit JAMAIS valoir pour lui.
        assert!(resolve(Some("autre.example"), None, conf())
            .unwrap()
            .pin
            .is_none());
    }

    #[test]
    fn load_reads_the_file_under_config() {
        let t = tempfile::tempdir().unwrap();
        let root = Root::new(t.path().to_str().unwrap(), PathStyle::Unix).unwrap();
        assert_eq!(load(&root).unwrap(), RawConf::default());
        fs::create_dir_all(t.path().join("config")).unwrap();
        fs::write(t.path().join("config/remote.conf"), "host = a.example\n").unwrap();
        assert_eq!(load(&root).unwrap().host.as_deref(), Some("a.example"));
    }

    #[test]
    fn host_key_matches_the_wizard_including_the_trailing_underscore() {
        // `hostname` imprime « Mac-mini.local\n » ; tr -c remplace aussi le saut de ligne.
        assert_eq!(
            host_keys("Mac-mini.local"),
            vec!["Mac-mini.local_".to_string()]
        );
        assert_eq!(host_keys("PC de Jo")[0], "PC_de_Jo_");
        // Accent : « é » = 1 caractère mais 2 octets -> deux variantes plausibles.
        let k = host_keys("Café");
        assert_eq!(k, vec!["Caf__".to_string(), "Caf___".to_string()]);
    }

    #[test]
    fn trust_is_read_from_the_marker_written_by_the_wizard() {
        let t = tempfile::tempdir().unwrap();
        let root = Root::new(t.path().to_str().unwrap(), PathStyle::Unix).unwrap();
        assert_eq!(read_trust(&root, "Mac-mini.local"), Trust::Unknown);
        let dir = t.path().join("config/.hosts");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("Mac-mini.local_"), "guest\n").unwrap();
        assert_eq!(read_trust(&root, "Mac-mini.local"), Trust::Guest);
        fs::write(dir.join("Mac-mini.local_"), "trusted\n").unwrap();
        assert_eq!(read_trust(&root, "Mac-mini.local"), Trust::Trusted);
        fs::write(dir.join("Mac-mini.local_"), "??\n").unwrap();
        assert_eq!(read_trust(&root, "Mac-mini.local"), Trust::Unknown);
    }

    #[test]
    fn only_real_access_token_files_are_recognised() {
        let h = "mac.example.com";
        assert!(is_access_token_name(&format!("{h}-{AUD}-token"), h));
        assert!(is_access_token_name(&format!("{h}-{AUD}-token.lock"), h));
        assert!(is_access_token_name(
            "example.cloudflareaccess.com-org-token",
            h
        ));
        assert!(is_access_token_name(
            "example.cloudflareaccess.com-org-token.lock",
            h
        ));
        for no in [
            "cert.pem",
            "ccp-mac.token",
            "config.yml",
            "autre.example-00d26537aaaaaaaaaaaaaaaaaaaaaaaaaaaa-token",
            &format!("{h}-nonhex-token"),
            &format!("x{h}-{AUD}-token"),
            ".cloudflareaccess.com-org-token",
        ] {
            assert!(!is_access_token_name(no, h), "{no}");
        }
    }

    #[test]
    fn purge_removes_tokens_and_nothing_else() {
        let t = tempfile::tempdir().unwrap();
        let cf = t.path().join(".cloudflared");
        fs::create_dir_all(&cf).unwrap();
        let h = "mac.example.com";
        for (n, keep) in [
            (format!("{h}-{AUD}-token"), false),
            (
                "example.cloudflareaccess.com-org-token.lock".to_string(),
                false,
            ),
            ("ccp-mac.token".to_string(), true),
            ("cert.pem".to_string(), true),
        ] {
            fs::write(cf.join(&n), "secret").unwrap();
            let _ = keep;
        }
        let gone = purge_access_tokens(t.path(), h);
        assert_eq!(gone.len(), 2, "{gone:?}");
        assert!(cf.join("ccp-mac.token").exists() && cf.join("cert.pem").exists());
        assert!(!cf.join(format!("{h}-{AUD}-token")).exists());
        // Dossier absent : rien, sans erreur.
        assert!(purge_access_tokens(&t.path().join("vide"), h).is_empty());
    }
}
