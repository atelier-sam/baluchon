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
//!
//! PACKS (`[[pack]]`) : un pack est une liste NOMMÉE de logiciels, jamais recopiée. Il a une clé, un
//! libellé et EXACTEMENT UNE source : `apps = [clés]` (liste explicite), `category = "X"` (toute une
//! catégorie) ou `defaults = true` (les entrées cochées par défaut). Les deux dernières se DÉRIVENT du
//! catalogue final : une surcharge qui décoche `chrome` ou ajoute une appli de la catégorie change le
//! pack sans qu'on le recopie. Un pack ne cite jamais un pack. Les packs se fusionnent par clé comme
//! les applis (`remove = true` compris) et se valident APRÈS la fusion des applis (voir
//! [`merge_catalogue`]).
//!
//! DEUX NIVEAUX D'API, UNE SEULE FUSION. [`parse_catalogue`] et [`merge_catalogue`] lisent et fusionnent
//! applis ET packs : c'est LA logique. [`parse_file`] et [`merge`], l'API d'avant les packs, gardent leur
//! signature et n'en sont que de minces enveloppes (applis seules) : un programme qui lie cette crate
//! sans connaître les packs continue de compiler et de se comporter comme avant.

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

/// Un pack tel qu'écrit dans un fichier TOML : une seule source parmi `apps`, `category`,
/// `defaults` (vérifié à la lecture), tout le reste optionnel pour qu'une surcharge puisse ne
/// changer que le libellé. Opaque hors de la crate, comme [`RawApp`].
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RawPack {
    key: String,
    label: Option<String>,
    apps: Option<Vec<String>>,
    category: Option<String>,
    defaults: Option<bool>,
    #[serde(default)]
    remove: bool,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawFile {
    #[serde(default)]
    app: Vec<RawApp>,
    #[serde(default)]
    pack: Vec<RawPack>,
}

/// Un fichier de catalogue lu : ses applis ET ses packs. Opaque hors de la crate : on le reçoit
/// de [`parse_catalogue`] et on le rend à [`merge_catalogue`].
#[derive(Debug, Default)]
pub struct Fichier {
    apps: Vec<RawApp>,
    packs: Vec<RawPack>,
}

/// Un pack RÉSOLU : sa liste de clés d'applis, dans l'ordre où elles s'affichent (l'ordre écrit
/// pour une liste explicite, l'ordre du catalogue pour une catégorie ou les cochées par défaut).
/// Il n'est JAMAIS écrit à la main sous cette forme : il sort de [`merge_catalogue`].
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Pack {
    pub key: String,
    pub label: String,
    /// Clés d'applis du catalogue (toutes existent, aucune n'est répétée, la liste n'est jamais vide).
    pub apps: Vec<String>,
}

/// Ce que rend [`merge_catalogue`] : les applis fusionnées et les packs résolus contre elles.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Catalogue {
    pub apps: Vec<App>,
    pub packs: Vec<Pack>,
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

/// Lit un fichier de catalogue (embarqué ou de surcharge), applis ET packs. `origin` nomme la
/// source dans le message. Ce qui se juge sur UNE entrée ou sur UN fichier se juge ici (plusieurs
/// sources dans un pack, `defaults = false`, clé de pack en double dans ce fichier) ; ce qui dépend
/// du catalogue final (clés citées, pack vide) se juge dans [`merge_catalogue`].
pub fn parse_catalogue(text: &str, origin: &str) -> Result<Fichier, Erreur> {
    let f: RawFile =
        toml::from_str(text).map_err(|e| Erreur::Invalide(format!("{origin} invalide : {e}")))?;
    let mut vues: Vec<&str> = Vec::new();
    for p in &f.pack {
        // Deux fois la même clé de pack DANS UN fichier est une faute (copier-coller). La même clé
        // dans la base et dans la surcharge, elle, est la fusion voulue : elle se joue plus loin.
        if vues.contains(&p.key.as_str()) {
            return Err(Erreur::Invalide(format!(
                "{origin} : clé de pack en double « {} »",
                p.key
            )));
        }
        vues.push(&p.key);
        let sources = usize::from(p.apps.is_some())
            + usize::from(p.category.is_some())
            + usize::from(p.defaults.is_some());
        if sources > 1 {
            return Err(Erreur::Invalide(format!(
                "{origin} : pack « {} » : plusieurs sources (apps, category, defaults) : une seule par pack",
                p.key
            )));
        }
        if p.defaults == Some(false) {
            return Err(Erreur::Invalide(format!(
                "{origin} : pack « {} » : `defaults = false` n'est pas une source (mets `true`, ou retire la ligne)",
                p.key
            )));
        }
    }
    Ok(Fichier {
        apps: f.app,
        packs: f.pack,
    })
}

/// Lit les APPLIS d'un fichier de catalogue : l'API d'avant les packs, gardée telle quelle.
/// WHY une enveloppe et pas une seconde lecture : [`parse_catalogue`] est l'unique lecteur. Ici on
/// ne garde que les applis ; les `[[pack]]` du fichier sont lus (et leurs fautes de forme refusées)
/// mais jetés : cet appelant ne sait pas les employer. Pour les packs, [`parse_catalogue`].
pub fn parse_file(text: &str, origin: &str) -> Result<Vec<RawApp>, Erreur> {
    parse_catalogue(text, origin).map(|f| f.apps)
}

/// Fusionne `over` dans `base` (voir la documentation du module) : les applis d'abord, puis les
/// packs, résolus contre les applis FINALES. C'est l'UNIQUE logique de fusion de la crate. Publique :
/// un appelant qui ajoute ses propres entrées au catalogue embarqué (un second fichier, une
/// surcharge) passe par ICI, jamais par une seconde fusion écrite de son côté. `origin` nomme la
/// surcharge dans les messages ; une entrée de `base` fautive est signalée comme le catalogue
/// embarqué.
///
/// Les packs se fusionnent PAR CLÉ, champ par champ, comme les applis : `label` se change seul ;
/// une source donnée par la surcharge REMPLACE celle du pack en entier (jamais deux sources) ;
/// `remove = true` retire le pack ; un pack neuf exige `label` et une source et s'ajoute à la fin.
/// Refusé, en nommant l'origine et le pack : une clé citée absente du catalogue (TOUTES listées, avec
/// « retirée par … » quand une surcharge l'a supprimée, ou « est un pack » quand c'en est une),
/// une clé répétée dans `apps`, un pack vide une fois résolu, un libellé vide, une clé de pack invalide
/// ou égale à celle d'une appli.
pub fn merge_catalogue(base: Fichier, over: Fichier, origin: &str) -> Result<Catalogue, Erreur> {
    let mut out: Vec<App> = Vec::new();
    // Les clés retirées par `remove = true`, et PAR QUI : un pack qui les cite encore le saura.
    let mut retirees: Vec<(String, String)> = Vec::new();
    let mut apply = |raw: RawApp, is_base: bool| -> Result<(), Erreur> {
        let qui = if is_base {
            "le catalogue embarqué"
        } else {
            origin
        };
        if !valid_key(&raw.key) {
            // `qui`, pas `origin` : la faute peut venir de la base, et la surcharge n'y est pour rien.
            return Err(Erreur::Invalide(format!(
                "{qui} : clé invalide « {} »",
                raw.key
            )));
        }
        let pos = out.iter().position(|a| a.key == raw.key);
        if raw.remove {
            if let Some(i) = pos {
                out.remove(i);
                retirees.retain(|(k, _)| k != &raw.key);
                retirees.push((raw.key, qui.to_string()));
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
                    return Err(Erreur::Invalide(format!(
                        "{qui} : « {} » est une entrée nouvelle, elle doit avoir label et winget",
                        raw.key
                    )));
                };
                // Une appli qui revient après avoir été retirée n'est plus « retirée ».
                retirees.retain(|(k, _)| k != &raw.key);
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
    for r in base.apps {
        apply(r, true)?;
    }
    for r in over.apps {
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
    let packs = merge_packs(base.packs, over.packs, origin, &out, &retirees)?;
    Ok(Catalogue { apps: out, packs })
}

/// Où va la liste d'un pack : écrite à la main, ou DÉRIVÉE du catalogue final.
enum Source {
    Apps(Vec<String>),
    Category(String),
    Defaults,
}

/// Un pack en cours de fusion : `qui` est le dernier fichier qui l'a écrit (pour dire d'où vient une faute).
struct PackFusion {
    key: String,
    label: String,
    source: Source,
    qui: String,
}

/// Fusionne les packs de `base` et de `over` PAR CLÉ, puis les résout contre les applis finales `apps`.
/// `retirees` : les clés d'applis supprimées par `remove`, avec le fichier qui l'a fait.
fn merge_packs(
    base: Vec<RawPack>,
    over: Vec<RawPack>,
    origin: &str,
    apps: &[App],
    retirees: &[(String, String)],
) -> Result<Vec<Pack>, Erreur> {
    let mut defs: Vec<PackFusion> = Vec::new();
    for (raws, is_base) in [(base, true), (over, false)] {
        let qui = if is_base {
            "le catalogue embarqué"
        } else {
            origin
        };
        for raw in raws {
            if !valid_key(&raw.key) {
                return Err(Erreur::Invalide(format!(
                    "{qui} : clé de pack invalide « {} »",
                    raw.key
                )));
            }
            let pos = defs.iter().position(|d| d.key == raw.key);
            if raw.remove {
                if let Some(i) = pos {
                    defs.remove(i);
                }
                continue;
            }
            // `parse_catalogue` a déjà refusé deux sources et `defaults = false` : il n'en reste qu'une, ou aucune.
            let source = match (raw.apps, raw.category, raw.defaults) {
                (Some(liste), None, None) => Some(Source::Apps(liste)),
                (None, Some(c), None) => Some(Source::Category(clean_label(&c))),
                (None, None, Some(true)) => Some(Source::Defaults),
                _ => None,
            };
            match pos {
                Some(i) => {
                    let d = &mut defs[i];
                    if let Some(l) = raw.label {
                        d.label = clean_label(&l);
                    }
                    // Une source donnée REMPLACE celle du pack : jamais deux sources.
                    if let Some(s) = source {
                        d.source = s;
                    }
                    d.qui = qui.to_string();
                }
                None => {
                    let Some(label) = raw.label else {
                        return Err(Erreur::Invalide(format!(
                            "{qui} : « {} » est un pack nouveau, il doit avoir un label",
                            raw.key
                        )));
                    };
                    let Some(source) = source else {
                        return Err(Erreur::Invalide(format!(
                            "{qui} : pack « {} » : aucune source (une parmi apps, category, defaults)",
                            raw.key
                        )));
                    };
                    defs.push(PackFusion {
                        key: raw.key,
                        label: clean_label(&label),
                        source,
                        qui: qui.to_string(),
                    });
                }
            }
        }
    }

    // Résolution contre le catalogue FINAL. Toute faute nomme la surcharge (`origin`, comme les fautes
    // d'applis) et, quand le pack vient d'ailleurs, le fichier qui l'a écrit.
    let cles_de_packs: Vec<String> = defs.iter().map(|d| d.key.clone()).collect();
    let mut out = Vec::new();
    for d in defs {
        let nom = if d.qui == origin {
            format!("{origin} : pack « {} »", d.key)
        } else {
            format!("{origin} : pack « {} » (écrit par {})", d.key, d.qui)
        };
        if d.label.is_empty() {
            return Err(Erreur::Invalide(format!("{nom} : libellé vide")));
        }
        if apps.iter().any(|a| a.key == d.key) {
            return Err(Erreur::Invalide(format!(
                "{nom} : sa clé est celle d'une appli du catalogue"
            )));
        }
        let cles: Vec<String> = match &d.source {
            Source::Apps(liste) => {
                let mut vues: Vec<&str> = Vec::new();
                let mut fautes: Vec<String> = Vec::new();
                for k in liste {
                    if vues.contains(&k.as_str()) {
                        return Err(Erreur::Invalide(format!(
                            "{nom} : clé répétée dans apps « {k} »"
                        )));
                    }
                    vues.push(k);
                    if apps.iter().any(|a| &a.key == k) {
                        continue;
                    }
                    fautes.push(if cles_de_packs.contains(k) {
                        format!(
                            "« {k} » est un pack, pas une appli (un pack ne cite jamais un pack)"
                        )
                    } else if let Some((_, par)) = retirees.iter().find(|(r, _)| r == k) {
                        format!("« {k} » a été retirée par {par}")
                    } else {
                        format!("« {k} » n'existe pas dans le catalogue")
                    });
                }
                if !fautes.is_empty() {
                    return Err(Erreur::Invalide(format!(
                        "{nom} : {} ; corrige sa liste `apps` (ou redéfinis le pack dans la surcharge)",
                        fautes.join(" ; ")
                    )));
                }
                liste.clone()
            }
            Source::Category(c) => apps
                .iter()
                .filter(|a| &a.category == c)
                .map(|a| a.key.clone())
                .collect(),
            Source::Defaults => apps
                .iter()
                .filter(|a| a.default)
                .map(|a| a.key.clone())
                .collect(),
        };
        if cles.is_empty() {
            let pourquoi = match &d.source {
                Source::Apps(_) => "sa liste `apps` est vide".to_string(),
                Source::Category(c) => format!("aucune appli n'est dans la catégorie « {c} »"),
                Source::Defaults => "aucune appli n'est cochée par défaut".to_string(),
            };
            return Err(Erreur::Invalide(format!("{nom} : pack vide, {pourquoi}")));
        }
        out.push(Pack {
            key: d.key,
            label: d.label,
            apps: cles,
        });
    }
    Ok(out)
}

/// Fusionne les APPLIS de `over` dans celles de `base` : l'API d'avant les packs, gardée telle quelle.
/// WHY une enveloppe et pas une seconde fusion : [`merge_catalogue`] est l'unique logique, sinon deux
/// fusions divergeraient à la première règle ajoutée. Ici les packs sont ignorés (cet appelant n'en
/// reçoit pas) ; un essai prouve que le résultat est celui de [`merge_catalogue`].
pub fn merge(base: Vec<RawApp>, over: Vec<RawApp>, origin: &str) -> Result<Vec<App>, Erreur> {
    merge_catalogue(
        Fichier {
            apps: base,
            packs: Vec::new(),
        },
        Fichier {
            apps: over,
            packs: Vec::new(),
        },
        origin,
    )
    .map(|c| c.apps)
}

/// Catalogue embarqué seul, applis ET packs.
pub fn embedded_catalogue() -> Result<Catalogue, Erreur> {
    let base = parse_catalogue(EMBEDDED, "catalogue embarqué")?;
    merge_catalogue(base, Fichier::default(), "catalogue embarqué")
}

/// Catalogue embarqué seul, applis seules (celui des tests et du repli). Ses packs sont quand même
/// jugés : un pack embarqué fautif fait échouer ICI aussi.
pub fn embedded() -> Result<Vec<App>, Erreur> {
    embedded_catalogue().map(|c| c.apps)
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

    // ------------------------------------------------------------------ suite ArtCraft et packs

    /// Fusionne `over` sur le catalogue embarqué, applis ET packs : la fonction publique, jamais une copie.
    fn fusion_complete(over: &str) -> Result<Catalogue, Erreur> {
        let base = parse_catalogue(EMBEDDED, "catalogue embarqué")?;
        merge_catalogue(base, parse_catalogue(over, "surcharge")?, "surcharge")
    }

    fn pack<'a>(c: &'a Catalogue, key: &str) -> &'a Pack {
        c.packs
            .iter()
            .find(|p| p.key == key)
            .unwrap_or_else(|| panic!("pack absent : {key}"))
    }

    fn cles(p: &Pack) -> Vec<&str> {
        p.apps.iter().map(String::as_str).collect()
    }

    /// (clé, identifiant winget, nom du produit) des 14 applis, relus le 26/11/2026 dans manifests/a/ArtCraft/.
    const ARTCRAFT: [(&str, &str, &str); 14] = [
        ("artcraft-word", "ArtCraft.WordCraft", "WordCraft"),
        ("artcraft-grid", "ArtCraft.GridCraft", "GridCraft"),
        ("artcraft-deck", "ArtCraft.DeckCraft", "DeckCraft"),
        ("artcraft-pdf", "ArtCraft.PdfCraft", "PdfCraft"),
        ("artcraft-photo", "ArtCraft.PhotoCraft", "PhotoCraft"),
        ("artcraft-light", "ArtCraft.LightCraft", "LightCraft"),
        ("artcraft-vector", "ArtCraft.VectorCraft", "VectorCraft"),
        ("artcraft-design", "ArtCraft.DesignCraft", "DesignCraft"),
        ("artcraft-film", "ArtCraft.FilmCraft", "FilmCraft"),
        ("artcraft-effect", "ArtCraft.EffectCraft", "EffectCraft"),
        ("artcraft-sound", "ArtCraft.SoundCraft", "SoundCraft"),
        ("artcraft-cad", "ArtCraft.CadCraft", "CadCraft"),
        (
            "artcraft-material",
            "ArtCraft.MaterialCraft",
            "MaterialCraft",
        ),
        ("artcraft-texture", "ArtCraft.TextureCraft", "TextureCraft"),
    ];

    #[test]
    fn les_quatorze_applis_artcraft_ont_leurs_identifiants_exacts() {
        let apps = embedded().unwrap();
        for (cle, id, nom) in ARTCRAFT {
            let a = apps
                .iter()
                .find(|a| a.key == cle)
                .unwrap_or_else(|| panic!("clé manquante : {cle}"));
            assert_eq!(a.winget, id);
            assert_eq!(a.category, "ArtCraft");
            assert!(!a.default, "{cle} ne se coche pas d'avance");
            // « Nom (description) » : le nom court est celui du produit ; 80 caractères au plus (borne de la console).
            assert_eq!(a.label.split(" (").next().unwrap(), nom, "{}", a.label);
            assert!(
                a.label.chars().count() <= 80,
                "{} : {} caractères",
                a.label,
                a.label.chars().count()
            );
            // Décidé : pas d'étiquette de préversion ; et un libellé ne promet rien sur les langues.
            let bas = a.label.to_lowercase();
            for mot in [
                "préversion",
                "preview",
                "beta",
                "bêta",
                "anglais",
                "français",
            ] {
                assert!(!bas.contains(mot), "« {mot} » dans {}", a.label);
            }
        }
        assert_eq!(apps.iter().filter(|a| a.category == "ArtCraft").count(), 14);
        // Contrôle négatif : ces deux-là existent dans winget mais sont d'AUTRES produits.
        for id in ["ArtCraft.ArtCraft", "ArtCraft.CraftAnything"] {
            assert!(
                !apps.iter().any(|a| a.winget == id),
                "{id} ne doit pas figurer"
            );
        }
    }

    /// Les 14 libellés EXACTS, tels qu'ils s'affichent dans le wizard.
    const LIBELLES_ARTCRAFT: [(&str, &str); 14] = [
        (
            "artcraft-word",
            "WordCraft (traitement de texte : alternative libre à Word)",
        ),
        (
            "artcraft-grid",
            "GridCraft (tableur : alternative libre à Excel)",
        ),
        (
            "artcraft-deck",
            "DeckCraft (présentations : alternative libre à PowerPoint)",
        ),
        (
            "artcraft-pdf",
            "PdfCraft (outils PDF : alternative libre à Acrobat)",
        ),
        (
            "artcraft-photo",
            "PhotoCraft (retouche photo : alternative libre à Photoshop)",
        ),
        (
            "artcraft-light",
            "LightCraft (photothèque et RAW : alternative libre à Lightroom)",
        ),
        (
            "artcraft-vector",
            "VectorCraft (illustration vectorielle : alternative libre à Illustrator)",
        ),
        (
            "artcraft-design",
            "DesignCraft (mise en page : alternative libre à InDesign)",
        ),
        (
            "artcraft-film",
            "FilmCraft (montage vidéo : alternative libre à Premiere Pro)",
        ),
        (
            "artcraft-effect",
            "EffectCraft (effets visuels : alternative libre à After Effects)",
        ),
        (
            "artcraft-sound",
            "SoundCraft (montage audio : alternative libre à Pro Tools)",
        ),
        (
            "artcraft-cad",
            "CadCraft (dessin technique et CAO : alternative libre à AutoCAD)",
        ),
        (
            "artcraft-material",
            "MaterialCraft (matériaux 3D PBR par nœuds)",
        ),
        ("artcraft-texture", "TextureCraft (peinture de textures 3D)"),
    ];

    #[test]
    fn les_quatorze_libelles_artcraft_sont_exacts_et_d_une_seule_forme() {
        let apps = embedded().unwrap();
        for (cle, attendu) in LIBELLES_ARTCRAFT {
            let a = apps.iter().find(|a| a.key == cle).unwrap();
            assert_eq!(a.label, attendu);
            // Une seule forme « Nom (fonction : alternative libre à X) » ; deux logiciels n'en remplacent aucun.
            let sans_remplacement = ["artcraft-material", "artcraft-texture"].contains(&cle);
            assert_eq!(
                a.label.contains(" : alternative libre à "),
                !sans_remplacement,
                "{}",
                a.label
            );
            assert!(a.label.ends_with(')'), "{}", a.label);
            // Plus de jargon : le mot de l'éditeur ne doit pas revenir.
            assert!(!a.label.to_lowercase().contains("réimplémentation"));
        }
        // Les 14 de la table sont bien les 14 de la catégorie (aucun libellé oublié, aucun en trop).
        assert_eq!(
            LIBELLES_ARTCRAFT.len(),
            apps.iter().filter(|a| a.category == "ArtCraft").count()
        );
    }

    #[test]
    fn une_cle_d_appli_invalide_nomme_le_fichier_qui_l_a_ecrite() {
        // Dans la BASE : la faute n'est pas celle de la surcharge, le message nomme le catalogue embarqué.
        let fautive = "[[app]]\nkey = \"Majuscule\"\nlabel = \"X\"\nwinget = \"A.B\"\n";
        let base = parse_catalogue(fautive, "catalogue embarqué").unwrap();
        let sur = parse_catalogue("", "surcharge").unwrap();
        match merge_catalogue(base, sur, "surcharge") {
            Err(Erreur::Invalide(m)) => {
                assert!(
                    m.contains("le catalogue embarqué : clé invalide « Majuscule »"),
                    "{m}"
                );
                assert!(
                    !m.contains("surcharge"),
                    "la surcharge n'y est pour rien : {m}"
                );
            }
            autre => panic!("refus attendu, reçu {autre:?}"),
        }
        // Contrôle positif : la même clé dans la SURCHARGE nomme la surcharge.
        let base = parse_catalogue(EMBEDDED, "catalogue embarqué").unwrap();
        let sur = parse_catalogue(fautive, "surcharge").unwrap();
        match merge_catalogue(base, sur, "surcharge") {
            Err(Erreur::Invalide(m)) => {
                assert!(
                    m.starts_with("surcharge : clé invalide « Majuscule »"),
                    "{m}"
                );
                assert!(!m.contains("le catalogue embarqué"), "{m}");
            }
            autre => panic!("refus attendu, reçu {autre:?}"),
        }
    }

    #[test]
    fn les_six_packs_du_catalogue_livre_se_resolvent() {
        let c = embedded_catalogue().unwrap();
        let ordre: Vec<&str> = c.packs.iter().map(|p| p.key.as_str()).collect();
        assert_eq!(
            ordre,
            [
                "artcraft-bureautique",
                "artcraft-photo-dessin",
                "artcraft-video-son",
                "artcraft-3d",
                "artcraft-suite",
                "essentiels"
            ]
        );
        assert_eq!(
            cles(pack(&c, "artcraft-bureautique")),
            [
                "artcraft-word",
                "artcraft-grid",
                "artcraft-deck",
                "artcraft-pdf"
            ]
        );
        assert_eq!(
            cles(pack(&c, "artcraft-photo-dessin")),
            [
                "artcraft-photo",
                "artcraft-light",
                "artcraft-vector",
                "artcraft-design"
            ]
        );
        assert_eq!(
            cles(pack(&c, "artcraft-video-son")),
            ["artcraft-film", "artcraft-effect", "artcraft-sound"]
        );
        assert_eq!(
            cles(pack(&c, "artcraft-3d")),
            ["artcraft-cad", "artcraft-material", "artcraft-texture"]
        );
        // Les dérivés sont CALCULÉS ici depuis les applis : un essai qui les recopierait ne prouverait rien.
        let categorie: Vec<&str> = c
            .apps
            .iter()
            .filter(|a| a.category == "ArtCraft")
            .map(|a| a.key.as_str())
            .collect();
        assert_eq!(categorie.len(), 14);
        assert_eq!(cles(pack(&c, "artcraft-suite")), categorie);
        let cochees: Vec<&str> = c
            .apps
            .iter()
            .filter(|a| a.default)
            .map(|a| a.key.as_str())
            .collect();
        assert!(cochees.len() >= 2 && cochees.contains(&"chrome"));
        assert_eq!(cles(pack(&c, "essentiels")), cochees);
        // Les quatre packs thématiques PARTAGENT la suite : aucune appli oubliée, aucune en double.
        let mut union: Vec<&str> = [
            "artcraft-bureautique",
            "artcraft-photo-dessin",
            "artcraft-video-son",
            "artcraft-3d",
        ]
        .iter()
        .flat_map(|k| cles(pack(&c, k)))
        .collect();
        union.sort_unstable();
        let mut suite = categorie.clone();
        suite.sort_unstable();
        assert_eq!(union, suite);
        for p in &c.packs {
            assert!(
                !p.label.contains(',') && !p.label.contains('\t'),
                "{}",
                p.label
            );
            assert!(
                !p.label.is_empty() && p.label.chars().count() <= 80,
                "{}",
                p.label
            );
            assert!(valid_key(&p.key), "{}", p.key);
        }
    }

    #[test]
    fn les_packs_derives_suivent_le_catalogue_sans_etre_recopies() {
        let base = embedded_catalogue().unwrap();
        // « essentiels » suit le drapeau `default` : cocher firefox l'ajoute, décocher chrome le retire.
        let c = fusion_complete(
            r#"
[[app]]
key = "firefox"
default = true

[[app]]
key = "chrome"
default = false
"#,
        )
        .unwrap();
        let ess = cles(pack(&c, "essentiels"));
        assert!(
            ess.contains(&"firefox") && !ess.contains(&"chrome"),
            "{ess:?}"
        );
        assert_ne!(ess, cles(pack(&base, "essentiels")));
        // « suite » suit la catégorie : une appli ArtCraft de plus l'agrandit, à sa place dans l'ordre du catalogue.
        let c = fusion_complete(
            r#"
[[app]]
key = "artcraft-extra"
label = "Extra"
category = "ArtCraft"
winget = "Editeur.Extra"
"#,
        )
        .unwrap();
        let suite = cles(pack(&c, "artcraft-suite"));
        assert_eq!(suite.len(), 15);
        assert_eq!(suite.last(), Some(&"artcraft-extra"));
        // Les packs à liste explicite, eux, ne bougent pas.
        assert_eq!(
            pack(&c, "artcraft-bureautique"),
            pack(&base, "artcraft-bureautique")
        );
        // Retirer une appli de la catégorie : « suite » rétrécit tout seul ; le pack à liste qui la cite doit être redéfini.
        let c = fusion_complete(
            r#"
[[app]]
key = "artcraft-texture"
remove = true

[[pack]]
key = "artcraft-3d"
apps = ["artcraft-cad", "artcraft-material"]
"#,
        )
        .unwrap();
        assert_eq!(pack(&c, "artcraft-suite").apps.len(), 13);
        assert_eq!(
            cles(pack(&c, "artcraft-3d")),
            ["artcraft-cad", "artcraft-material"]
        );
    }

    #[test]
    fn les_packs_se_fusionnent_par_cle_champ_par_champ() {
        let base = embedded_catalogue().unwrap();
        // Le libellé seul : la liste reste celle de la base ; la virgule d'un libellé est neutralisée (gum).
        let c = fusion_complete(
            "[[pack]]\nkey = \"artcraft-bureautique\"\nlabel = \"Bureautique, Craft\"\n",
        )
        .unwrap();
        let p = pack(&c, "artcraft-bureautique");
        assert_eq!(p.label, "Bureautique Craft");
        assert_eq!(p.apps, pack(&base, "artcraft-bureautique").apps);
        // Une source donnée REMPLACE celle du pack, son libellé reste.
        let c = fusion_complete(
            "[[pack]]\nkey = \"artcraft-bureautique\"\ncategory = \"Navigateurs\"\n",
        )
        .unwrap();
        let p = pack(&c, "artcraft-bureautique");
        assert_eq!(cles(p), ["chrome", "firefox"]);
        assert_eq!(p.label, "ArtCraft bureautique");
        // `remove = true` retire le pack.
        let c = fusion_complete("[[pack]]\nkey = \"artcraft-3d\"\nremove = true\n").unwrap();
        assert!(c.packs.iter().all(|p| p.key != "artcraft-3d"));
        assert_eq!(c.packs.len(), base.packs.len() - 1);
        // Un pack neuf, avec une liste dans l'ordre écrit, s'ajoute à la fin ; ceux de la base gardent leur ordre.
        let c = fusion_complete(
            "[[pack]]\nkey = \"mon-pack\"\nlabel = \"Mon pack\"\napps = [\"vlc\", \"chrome\"]\n",
        )
        .unwrap();
        assert_eq!(
            c.packs.last().unwrap(),
            &Pack {
                key: "mon-pack".into(),
                label: "Mon pack".into(),
                apps: vec!["vlc".into(), "chrome".into()]
            }
        );
        assert_eq!(c.packs[..base.packs.len()], base.packs[..]);
        // La surcharge peut citer SES PROPRES applis, ajoutées dans le même fichier.
        let c = fusion_complete(
            r#"
[[app]]
key = "outil"
label = "Outil"
category = "Mes outils"
winget = "Editeur.Outil"

[[pack]]
key = "mes-outils"
label = "Mes outils"
category = "Mes outils"
"#,
        )
        .unwrap();
        assert_eq!(cles(pack(&c, "mes-outils")), ["outil"]);
        // Une appli retirée puis REMISE dans le même fichier n'est plus « retirée » : le pack qui la cite passe.
        let c = fusion_complete(
            r#"
[[app]]
key = "artcraft-word"
remove = true

[[app]]
key = "artcraft-word"
label = "WordCraft bis"
winget = "ArtCraft.WordCraft"
"#,
        )
        .unwrap();
        assert!(pack(&c, "artcraft-bureautique")
            .apps
            .contains(&"artcraft-word".to_string()));
    }

    #[test]
    fn chaque_faute_de_pack_est_refusee_et_la_version_corrigee_passe() {
        // (la faute, la même surcharge corrigée, ce que le message doit dire). Tout message nomme la surcharge.
        let cas: Vec<(&str, &str, Vec<&str>)> = vec![
            (
                "[[pack]]\nkey = \"p\"\nlabel = \"P\"\napps = [\"chrome\", \"nope\", \"zzz\"]\n",
                "[[pack]]\nkey = \"p\"\nlabel = \"P\"\napps = [\"chrome\", \"vlc\"]\n",
                vec!["pack « p »", "« nope » n'existe pas", "« zzz » n'existe pas"],
            ),
            (
                // Une appli retirée par la surcharge alors qu'un pack du catalogue embarqué la cite.
                "[[app]]\nkey = \"artcraft-word\"\nremove = true\n",
                "[[app]]\nkey = \"artcraft-word\"\nremove = true\n\n[[pack]]\nkey = \"artcraft-bureautique\"\napps = [\"artcraft-grid\", \"artcraft-deck\", \"artcraft-pdf\"]\n",
                vec![
                    "pack « artcraft-bureautique » (écrit par le catalogue embarqué)",
                    "« artcraft-word » a été retirée par surcharge",
                    "redéfinis le pack",
                ],
            ),
            (
                "[[pack]]\nkey = \"p\"\nlabel = \"P\"\napps = [\"artcraft-suite\"]\n",
                "[[pack]]\nkey = \"p\"\nlabel = \"P\"\napps = [\"chrome\"]\n",
                vec!["« artcraft-suite » est un pack, pas une appli"],
            ),
            (
                "[[pack]]\nkey = \"p\"\nlabel = \"P\"\n",
                "[[pack]]\nkey = \"p\"\nlabel = \"P\"\napps = [\"chrome\"]\n",
                vec!["pack « p » : aucune source"],
            ),
            (
                "[[pack]]\nkey = \"p\"\napps = [\"chrome\"]\n",
                "[[pack]]\nkey = \"p\"\nlabel = \"P\"\napps = [\"chrome\"]\n",
                vec!["« p » est un pack nouveau", "label"],
            ),
            (
                "[[pack]]\nkey = \"p\"\nlabel = \"P\"\napps = [\"chrome\"]\ncategory = \"ArtCraft\"\n",
                "[[pack]]\nkey = \"p\"\nlabel = \"P\"\napps = [\"chrome\"]\n",
                vec!["pack « p » : plusieurs sources"],
            ),
            (
                "[[pack]]\nkey = \"p\"\nlabel = \"P\"\ndefaults = false\n",
                "[[pack]]\nkey = \"p\"\nlabel = \"P\"\ndefaults = true\n",
                vec!["pack « p » : `defaults = false` n'est pas une source"],
            ),
            (
                "[[pack]]\nkey = \"p\"\nlabel = \"P\"\napps = []\n",
                "[[pack]]\nkey = \"p\"\nlabel = \"P\"\napps = [\"chrome\"]\n",
                vec!["pack « p »", "pack vide", "sa liste `apps` est vide"],
            ),
            (
                "[[pack]]\nkey = \"p\"\nlabel = \"P\"\ncategory = \"Inexistante\"\n",
                "[[pack]]\nkey = \"p\"\nlabel = \"P\"\ncategory = \"Navigateurs\"\n",
                vec!["pack vide", "aucune appli n'est dans la catégorie « Inexistante »"],
            ),
            (
                // Plus aucune appli cochée : « essentiels » (embarqué, dérivé) devient vide.
                "[[app]]\nkey = \"chrome\"\ndefault = false\n[[app]]\nkey = \"libreoffice\"\ndefault = false\n[[app]]\nkey = \"acrobat-reader\"\ndefault = false\n[[app]]\nkey = \"7zip\"\ndefault = false\n[[app]]\nkey = \"vlc\"\ndefault = false\n[[app]]\nkey = \"vcredist\"\ndefault = false\n",
                "[[app]]\nkey = \"chrome\"\ndefault = false\n[[app]]\nkey = \"libreoffice\"\ndefault = false\n[[app]]\nkey = \"acrobat-reader\"\ndefault = false\n[[app]]\nkey = \"7zip\"\ndefault = false\n[[app]]\nkey = \"vlc\"\ndefault = false\n",
                vec![
                    "pack « essentiels » (écrit par le catalogue embarqué)",
                    "aucune appli n'est cochée par défaut",
                ],
            ),
            (
                "[[pack]]\nkey = \"p\"\nlabel = \"P\"\napps = [\"chrome\"]\n\n[[pack]]\nkey = \"p\"\nlabel = \"Q\"\napps = [\"vlc\"]\n",
                "[[pack]]\nkey = \"p\"\nlabel = \"P\"\napps = [\"chrome\"]\n\n[[pack]]\nkey = \"q\"\nlabel = \"Q\"\napps = [\"vlc\"]\n",
                vec!["clé de pack en double « p »"],
            ),
            (
                "[[pack]]\nkey = \"chrome\"\nlabel = \"P\"\napps = [\"vlc\"]\n",
                "[[pack]]\nkey = \"chrome-pack\"\nlabel = \"P\"\napps = [\"vlc\"]\n",
                vec!["pack « chrome »", "sa clé est celle d'une appli"],
            ),
            (
                "[[pack]]\nkey = \"p\"\nlabel = \"P\"\napps = [\"chrome\", \"chrome\"]\n",
                "[[pack]]\nkey = \"p\"\nlabel = \"P\"\napps = [\"chrome\", \"vlc\"]\n",
                vec!["pack « p »", "clé répétée dans apps « chrome »"],
            ),
            (
                "[[pack]]\nkey = \"p\"\nlabel = \" , \"\napps = [\"chrome\"]\n",
                "[[pack]]\nkey = \"p\"\nlabel = \"P\"\napps = [\"chrome\"]\n",
                vec!["pack « p »", "libellé vide"],
            ),
            (
                "[[pack]]\nkey = \"p\"\nlabel = \"P\"\napps = [\"chrome\"]\nwinget = \"A.B\"\n",
                "[[pack]]\nkey = \"p\"\nlabel = \"P\"\napps = [\"chrome\"]\n",
                vec!["surcharge invalide", "winget"],
            ),
            (
                "[[packs]]\nkey = \"p\"\n",
                "",
                vec!["surcharge invalide", "packs"],
            ),
            (
                "[[pack]]\nkey = \"Majuscule\"\nlabel = \"P\"\napps = [\"chrome\"]\n",
                "[[pack]]\nkey = \"majuscule\"\nlabel = \"P\"\napps = [\"chrome\"]\n",
                vec!["clé de pack invalide « Majuscule »"],
            ),
        ];
        for (i, (mauvais, bon, attendus)) in cas.iter().enumerate() {
            match fusion_complete(mauvais) {
                Err(Erreur::Invalide(m)) => {
                    assert!(
                        m.contains("surcharge"),
                        "cas {i} : la surcharge n'est pas nommée : {m}"
                    );
                    for a in attendus {
                        assert!(m.contains(a), "cas {i} : « {a} » absent de : {m}");
                    }
                }
                autre => panic!("cas {i} : refus attendu pour {mauvais:?}, reçu {autre:?}"),
            }
            let corrige = fusion_complete(bon);
            assert!(
                corrige.is_ok(),
                "cas {i} : la version corrigée doit passer : {corrige:?}"
            );
        }
    }

    #[test]
    fn un_catalogue_sans_pack_se_fusionne_comme_avant() {
        let base = parse_catalogue(
            "[[app]]\nkey = \"a\"\nlabel = \"A\"\nwinget = \"E.A\"\n",
            "base",
        )
        .unwrap();
        let c = merge_catalogue(base, Fichier::default(), "base").unwrap();
        assert_eq!(c.apps.len(), 1);
        assert!(c.packs.is_empty());
    }

    #[test]
    fn les_enveloppes_rendent_les_memes_applis_que_la_fusion_a_packs() {
        // Base seule.
        let enveloppe = merge(
            parse_file(EMBEDDED, "catalogue embarqué").unwrap(),
            Vec::new(),
            "catalogue embarqué",
        )
        .unwrap();
        let complet = embedded_catalogue().unwrap();
        assert_eq!(enveloppe, complet.apps);
        assert_eq!(embedded().unwrap(), complet.apps);
        // Base + surcharge : un champ changé, une appli retirée, une ajoutée, ET un pack (que l'enveloppe ignore).
        let sur = r#"
[[app]]
key = "chrome"
default = false

[[app]]
key = "winrar"
remove = true

[[app]]
key = "gimp"
label = "GIMP, retouche"
winget = "GIMP.GIMP.3"

[[pack]]
key = "mon-pack"
label = "Mon pack"
apps = ["gimp", "vlc"]
"#;
        let enveloppe = merge(
            parse_file(EMBEDDED, "catalogue embarqué").unwrap(),
            parse_file(sur, "surcharge").unwrap(),
            "surcharge",
        )
        .unwrap();
        let complet = fusion_complete(sur).unwrap();
        assert_eq!(enveloppe, complet.apps);
        // Contrôle positif : la comparaison n'est pas vide de sens, la surcharge a bien changé le catalogue.
        assert_ne!(enveloppe, embedded().unwrap());
        assert!(enveloppe.iter().any(|a| a.key == "gimp"));
        assert!(!enveloppe.iter().any(|a| a.key == "winrar"));
        assert!(
            !enveloppe
                .iter()
                .find(|a| a.key == "chrome")
                .unwrap()
                .default
        );
    }

    #[test]
    fn l_enveloppe_ne_juge_pas_les_packs_la_fusion_complete_si() {
        let sur = "[[pack]]\nkey = \"p\"\nlabel = \"P\"\napps = [\"nope\"]\n";
        let applis = merge(
            parse_file(EMBEDDED, "catalogue embarqué").unwrap(),
            parse_file(sur, "surcharge").unwrap(),
            "surcharge",
        );
        assert!(applis.is_ok(), "l'enveloppe ne regarde que les applis");
        assert!(
            fusion_complete(sur).is_err(),
            "la fusion complète juge le pack"
        );
    }

    #[test]
    fn les_vingt_lignes_d_avant_restent_en_tete_du_wizard_et_les_quatorze_suivent() {
        // Les 20 lignes que `win catalog` rendait avant la suite ArtCraft (clé, libellé, coché), relevées sur f420292.
        const AVANT: [(&str, &str, u8); 20] = [
            ("chrome", "Google Chrome", 1),
            ("firefox", "Mozilla Firefox", 0),
            ("libreoffice", "LibreOffice (suite bureautique gratuite)", 1),
            ("thunderbird", "Mozilla Thunderbird (messagerie)", 0),
            ("acrobat-reader", "Adobe Acrobat Reader (PDF)", 1),
            ("notepadpp", "Notepad++", 0),
            ("winrar", "WinRAR (archives — licence payante)", 0),
            ("7zip", "7-Zip (archives gratuit)", 1),
            ("vlc", "VLC (lecteur multimédia)", 1),
            ("powertoys", "Microsoft PowerToys", 0),
            ("keepassxc", "KeePassXC (gestionnaire de mots de passe)", 0),
            ("malwarebytes", "Malwarebytes (anti-malware)", 0),
            ("anydesk", "AnyDesk (prise en main à distance)", 0),
            ("teamviewer", "TeamViewer (prise en main à distance)", 0),
            ("zoom", "Zoom", 0),
            ("teams", "Microsoft Teams", 0),
            ("onedrive", "Microsoft OneDrive", 0),
            ("java", "Java (environnement d'exécution Oracle)", 0),
            ("dotnet-desktop", ".NET Desktop Runtime 8", 0),
            ("vcredist", "Visual C++ Redistributable 2015-2022 (x64)", 1),
        ];
        let lignes = render_lines(&embedded().unwrap());
        let avant: String = AVANT
            .iter()
            .map(|(k, l, d)| format!("{k}\t{l}\t{d}\n"))
            .collect();
        assert!(
            lignes.starts_with(&avant),
            "les 20 premières lignes ont changé"
        );
        // Ensuite : exactement les 14 d'ArtCraft, décochées, et jamais une ligne de pack (le wizard n'en connaît pas).
        let reste: Vec<&str> = lignes[avant.len()..].lines().collect();
        assert_eq!(reste.len(), 14);
        assert!(reste.iter().all(|l| l.starts_with("artcraft-")
            && l.ends_with("\t0")
            && l.split('\t').count() == 3));
        assert!(!lignes.contains("essentiels") && !lignes.contains("artcraft-suite"));
    }
}
