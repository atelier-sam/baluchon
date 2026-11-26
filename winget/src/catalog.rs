//! Catalogue des logiciels Windows : TOML embarqué + fusion de fichiers de surcharge.
//! Lire la surcharge sur le disque (le noyau : `<racine>/config/catalog.toml`) est l'affaire
//! de l'appelant ; cette crate ne touche aucun fichier.
//!
//! Le wizard passe la sortie `lines` telle quelle à `gum choose --no-limit`, donc :
//! une ligne par logiciel, `clé<TAB>libellé<TAB>coché(0|1)`, jamais de virgule dans
//! un libellé (gum sépare `--selected` par des virgules) ni de tabulation.
//!
//! Fusion PAR CLÉ, champ par champ : l'utilisateur peut décocher `chrome` d'une ligne
//! (`default = false`) sans recopier l'entrée entière, retirer une entrée
//! (`remove = true`) ou en ajouter une (label + winget obligatoires).

use crate::Erreur;
use serde::{Deserialize, Serialize};

/// Catalogue livré avec le binaire. Il vit ICI (et non dans le noyau) pour qu'il n'y en ait
/// qu'un : tout programme qui lie cette crate part de la même base, sans copie.
pub const EMBEDDED: &str = include_str!("catalog.toml");

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct App {
    pub key: String,
    pub label: String,
    pub category: String,
    /// Identifiant winget (`Éditeur.Paquet`).
    pub winget: String,
    pub default: bool,
}

/// Une entrée telle qu'écrite dans un fichier TOML : tout est optionnel pour
/// qu'une surcharge puisse ne changer qu'un champ. Opaque hors de la crate : on la reçoit de
/// [`parse_file`] et on la rend à [`merge`], jamais construite à la main.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RawApp {
    key: String,
    label: Option<String>,
    category: Option<String>,
    winget: Option<String>,
    default: Option<bool>,
    #[serde(default)]
    remove: bool,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawFile {
    #[serde(default)]
    app: Vec<RawApp>,
}

/// Clé de catalogue : minuscules, chiffres, `-`, `_`, `.` ; jamais d'espace ni de
/// tabulation (elle sort telle quelle sur stdout et revient en argument de `install`).
pub fn valid_key(k: &str) -> bool {
    let mut chars = k.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_lowercase() || c.is_ascii_digit())
        && k.len() <= 40
        && chars
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '-' | '_' | '.'))
}

/// Identifiant winget : jamais de tiret initial (ce serait pris pour une option de
/// `winget`) ni d'espace. Le `+` existe (`Microsoft.VCRedist.2015+.x64`).
pub fn valid_winget_id(id: &str) -> bool {
    let mut chars = id.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_alphanumeric())
        && id.contains('.')
        && id.len() <= 120
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '+' | '-' | '_'))
}

/// Libellé sûr pour une ligne `clé<TAB>libellé<TAB>0|1` consommée par gum.
pub fn clean_label(s: &str) -> String {
    let replaced: String = s
        .chars()
        .map(|c| if c == ',' || c.is_control() { ' ' } else { c })
        .collect();
    replaced.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Lit un fichier de catalogue (embarqué ou de surcharge). `origin` nomme la source dans le message.
pub fn parse_file(text: &str, origin: &str) -> Result<Vec<RawApp>, Erreur> {
    let f: RawFile =
        toml::from_str(text).map_err(|e| Erreur::Invalide(format!("{origin} invalide : {e}")))?;
    Ok(f.app)
}

/// Fusionne `over` dans `base` (voir la documentation du module). Publique : un appelant qui
/// ajoute ses propres entrées au catalogue embarqué (un second fichier, une surcharge) passe
/// par ICI, jamais par une seconde fusion écrite de son côté. `origin` nomme la surcharge dans
/// les messages ; une entrée de `base` fautive est signalée comme le catalogue embarqué.
pub fn merge(base: Vec<RawApp>, over: Vec<RawApp>, origin: &str) -> Result<Vec<App>, Erreur> {
    let mut out: Vec<App> = Vec::new();
    let mut apply = |raw: RawApp, is_base: bool| -> Result<(), Erreur> {
        if !valid_key(&raw.key) {
            return Err(Erreur::Invalide(format!(
                "{origin} : clé invalide « {} »",
                raw.key
            )));
        }
        let pos = out.iter().position(|a| a.key == raw.key);
        if raw.remove {
            if let Some(i) = pos {
                out.remove(i);
            }
            return Ok(());
        }
        match pos {
            Some(i) => {
                let a = &mut out[i];
                if let Some(l) = raw.label {
                    a.label = clean_label(&l);
                }
                if let Some(c) = raw.category {
                    a.category = clean_label(&c);
                }
                if let Some(w) = raw.winget {
                    a.winget = w.trim().to_string();
                }
                if let Some(d) = raw.default {
                    a.default = d;
                }
            }
            None => {
                let (Some(label), Some(winget)) = (raw.label, raw.winget) else {
                    let who = if is_base {
                        "le catalogue embarqué"
                    } else {
                        origin
                    };
                    return Err(Erreur::Invalide(format!(
                        "{who} : « {} » est une entrée nouvelle, elle doit avoir label et winget",
                        raw.key
                    )));
                };
                out.push(App {
                    key: raw.key,
                    label: clean_label(&label),
                    category: raw
                        .category
                        .map(|c| clean_label(&c))
                        .unwrap_or_else(|| "Divers".to_string()),
                    winget: winget.trim().to_string(),
                    default: raw.default.unwrap_or(false),
                });
            }
        }
        Ok(())
    };
    for r in base {
        apply(r, true)?;
    }
    for r in over {
        apply(r, false)?;
    }
    for a in &out {
        if a.label.is_empty() {
            return Err(Erreur::Invalide(format!(
                "{origin} : libellé vide pour « {} »",
                a.key
            )));
        }
        if !valid_winget_id(&a.winget) {
            return Err(Erreur::Invalide(format!(
                "{origin} : identifiant winget invalide pour « {} » : « {} »",
                a.key, a.winget
            )));
        }
    }
    Ok(out)
}

/// Catalogue embarqué seul (celui des tests et du repli).
pub fn embedded() -> Result<Vec<App>, Erreur> {
    let base = parse_file(EMBEDDED, "catalogue embarqué")?;
    merge(base, Vec::new(), "catalogue embarqué")
}

/// `clé<TAB>libellé<TAB>coché`, une ligne par logiciel.
pub fn render_lines(apps: &[App]) -> String {
    let mut s = String::new();
    for a in apps {
        s.push_str(&format!(
            "{}\t{}\t{}\n",
            a.key,
            a.label,
            if a.default { 1 } else { 0 }
        ));
    }
    s
}

/// Résout des clés demandées ; les inconnues sont listées TOUTES d'un coup.
pub fn resolve<'a>(apps: &'a [App], keys: &[String]) -> Result<Vec<&'a App>, Erreur> {
    let mut found = Vec::new();
    let mut unknown: Vec<String> = Vec::new();
    for k in keys {
        match apps.iter().find(|a| &a.key == k) {
            Some(a) => {
                if !found.iter().any(|f: &&App| f.key == a.key) {
                    found.push(a);
                }
            }
            None => unknown.push(k.clone()),
        }
    }
    if unknown.is_empty() {
        Ok(found)
    } else {
        Err(Erreur::Inconnu(unknown))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embedded_catalog_is_valid_and_has_the_required_entries() {
        let apps = embedded().unwrap();
        for k in [
            "chrome",
            "firefox",
            "libreoffice",
            "winrar",
            "7zip",
            "vlc",
            "acrobat-reader",
            "anydesk",
            "teamviewer",
            "notepadpp",
            "thunderbird",
            "zoom",
            "teams",
            "onedrive",
            "java",
            "dotnet-desktop",
            "vcredist",
            "powertoys",
            "keepassxc",
            "malwarebytes",
        ] {
            assert!(apps.iter().any(|a| a.key == k), "clé manquante : {k}");
        }
        // Retirés après vérification contre winget-pkgs, ou écartés pour leur licence.
        for k in ["rustdesk", "ccleaner", "ccleaner-free"] {
            assert!(
                !apps.iter().any(|a| a.key == k),
                "ne doit pas figurer : {k}"
            );
        }
        assert!(!apps.iter().any(|a| a.winget == "RustDesk.RustDesk"));
        assert!(!apps.iter().any(|a| a.winget == "KeePassXC.KeePassXC"));
        assert_eq!(
            apps.iter().find(|a| a.key == "chrome").unwrap().winget,
            "Google.Chrome"
        );
    }

    #[test]
    fn embedded_labels_are_gum_safe_and_keys_unique() {
        let apps = embedded().unwrap();
        let mut seen = std::collections::HashSet::new();
        for a in &apps {
            assert!(!a.label.contains(','), "virgule dans « {} »", a.label);
            assert!(!a.label.contains(['\t', '\n', '\r']));
            assert!(valid_key(&a.key), "{}", a.key);
            assert!(valid_winget_id(&a.winget), "{}", a.winget);
            assert!(seen.insert(a.key.clone()), "clé en double : {}", a.key);
        }
    }

    #[test]
    fn lines_format_is_key_label_checked() {
        let apps = embedded().unwrap();
        let out = render_lines(&apps);
        let first: Vec<&str> = out.lines().next().unwrap().split('\t').collect();
        assert_eq!(first, ["chrome", "Google Chrome", "1"]);
        for l in out.lines() {
            let f: Vec<&str> = l.split('\t').collect();
            assert_eq!(f.len(), 3, "{l}");
            assert!(f[2] == "0" || f[2] == "1");
        }
    }

    /// Fusionne `over` (un fichier de surcharge) sur le catalogue embarqué, comme le font les
    /// appelants : la fonction publique `merge`, jamais une copie.
    fn fused(over: &str) -> Result<Vec<App>, Erreur> {
        let base = parse_file(EMBEDDED, "catalogue embarqué")?;
        merge(base, parse_file(over, "surcharge")?, "surcharge")
    }

    #[test]
    fn merge_changes_one_field_without_copying_the_entry() {
        let apps = fused(
            "[[app]]\nkey = \"chrome\"\ndefault = false\n\n[[app]]\nkey = \"firefox\"\ndefault = true\n",
        )
        .unwrap();
        let chrome = apps.iter().find(|a| a.key == "chrome").unwrap();
        assert!(!chrome.default);
        assert_eq!(chrome.winget, "Google.Chrome");
        assert_eq!(chrome.label, "Google Chrome");
        assert!(apps.iter().find(|a| a.key == "firefox").unwrap().default);
        // L'ordre du catalogue de base est conservé.
        assert_eq!(apps[0].key, "chrome");
    }

    #[test]
    fn merge_can_add_and_remove_entries() {
        let apps = fused(
            "[[app]]\nkey = \"gimp\"\nlabel = \"GIMP, retouche\"\nwinget = \"GIMP.GIMP.3\"\n\n\
             [[app]]\nkey = \"winrar\"\nremove = true\n",
        )
        .unwrap();
        assert!(!apps.iter().any(|a| a.key == "winrar"));
        let gimp = apps.iter().find(|a| a.key == "gimp").unwrap();
        // La virgule du libellé est neutralisée (gum), la catégorie par défaut posée.
        assert_eq!(gimp.label, "GIMP retouche");
        assert_eq!(gimp.category, "Divers");
        assert!(!gimp.default);
        assert_eq!(apps.last().unwrap().key, "gimp");
    }

    #[test]
    fn merge_refuses_a_bad_entry_and_names_its_origin() {
        for bad in [
            "ceci n'est pas du toml [[",
            "[[app]]\nkey = \"nouveau\"\nlabel = \"Sans winget\"\n",
            "[[app]]\nkey = \"chrome\"\nwinget = \"-oEvil\"\n",
            "[[app]]\nkey = \"Majuscule\"\nlabel = \"x\"\nwinget = \"A.B\"\n",
            "[[app]]\nkey = \"chrome\"\ninconnu = 1\n",
        ] {
            match fused(bad) {
                Err(Erreur::Invalide(m)) => assert!(m.contains("surcharge"), "{bad:?} : {m}"),
                autre => panic!("refus attendu pour {bad:?}, reçu {autre:?}"),
            }
        }
    }

    #[test]
    fn merge_applies_a_second_file_on_top_of_the_first_by_key() {
        // Le cas d'un appelant qui ajoute SON catalogue au catalogue embarqué : la même clé
        // la dernière gagne, champ par champ ; une clé neuve s'ajoute à la fin, dans l'ordre.
        let base = parse_file(EMBEDDED, "catalogue embarqué").unwrap();
        let ajout = parse_file(
            "[[app]]\nkey = \"outil-a\"\nlabel = \"Outil A\"\nwinget = \"Editeur.OutilA\"\n\n\
             [[app]]\nkey = \"outil-b\"\nlabel = \"Outil B\"\nwinget = \"Editeur.OutilB\"\n\n\
             [[app]]\nkey = \"outil-a\"\nlabel = \"Outil A bis\"\n",
            "ajout",
        )
        .unwrap();
        let apps = merge(base, ajout, "ajout").unwrap();
        let n = apps.len();
        assert_eq!(apps[n - 2].key, "outil-a");
        assert_eq!(apps[n - 2].label, "Outil A bis");
        assert_eq!(apps[n - 2].winget, "Editeur.OutilA");
        assert_eq!(apps[n - 1].key, "outil-b");
    }

    #[test]
    fn resolve_lists_every_unknown_key_at_once() {
        let apps = embedded().unwrap();
        let keys: Vec<String> = ["chrome", "nope", "vlc", "chrome", "zzz"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let e = resolve(&apps, &keys).unwrap_err();
        assert_eq!(e, Erreur::Inconnu(vec!["nope".into(), "zzz".into()]));
        let m = e.to_string();
        assert!(
            m.contains("nope") && m.contains("zzz") && !m.contains("vlc"),
            "{m}"
        );
        let ok = resolve(&apps, &keys[..1]).unwrap();
        assert_eq!(ok.len(), 1);
        // Doublons : une seule installation.
        let dup: Vec<String> = vec!["vlc".into(), "vlc".into()];
        assert_eq!(resolve(&apps, &dup).unwrap().len(), 1);
    }

    #[test]
    fn winget_ids_cannot_look_like_options() {
        assert!(valid_winget_id("Microsoft.VCRedist.2015+.x64"));
        assert!(valid_winget_id("Notepad++.Notepad++"));
        assert!(!valid_winget_id("-oEvil.x"));
        assert!(!valid_winget_id("Sans point"));
        assert!(!valid_winget_id("A.B C"));
        assert!(!valid_winget_id(""));
    }
}
