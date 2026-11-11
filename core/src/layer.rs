//! La COUCHE : un dossier `<racine>/overlay/` que le public sait LIRE sans en connaître
//! le contenu (H1 de la revue d'ingénierie).
//!
//! Le noyau public ne remplace, n'écrit ni ne supprime jamais rien sous `overlay/` : une
//! mise à jour du portable n'écrit que `bin/`. Une couche (un noyau complémentaire, des
//! crochets `hooks/update` et `hooks/uninstall`) se pose à côté et se met à jour par ses
//! propres crochets. Ici, on ne fait que dire ce qu'on voit (`doctor`).
//!
//! Manifeste `overlay/LAYER`, lignes `clé = valeur` (même syntaxe que `config/remote.conf`) :
//! `name`, `version`, `built_on` (version publique de construction), `contract` (contrat CLI
//! du noyau de la couche), `platforms` (liste séparée par des virgules, jokers `*`).

use crate::cli::CONTRACT;
use crate::root::Root;
use std::fs;
use std::path::PathBuf;

/// Nom du manifeste, sous `<racine>/overlay/`.
pub const MANIFEST: &str = "LAYER";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Layer {
    pub name: String,
    pub version: String,
    pub built_on: String,
    pub contract: u32,
    pub platforms: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LayerState {
    /// Pas de `overlay/LAYER` : le public tourne seul.
    Absent,
    /// Manifeste lu, contrat compatible.
    Usable(Layer),
    /// Manifeste lu, mais son contrat n'est pas celui de ce noyau : la couche ne sera pas utilisée.
    StaleContract(Layer),
    /// Manifeste présent mais illisible ou incomplet.
    Unreadable(String),
}

pub fn dir(root: &Root) -> PathBuf {
    root.path().join("overlay")
}

/// Lit le manifeste. Ne crée, n'écrit ni ne déplace jamais rien.
pub fn read(root: &Root) -> LayerState {
    let p = dir(root).join(MANIFEST);
    match fs::read_to_string(&p) {
        Ok(t) => classify(&t),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => LayerState::Absent,
        Err(e) => LayerState::Unreadable(format!("{} illisible : {e}", p.display())),
    }
}

/// Pure : jugement d'un manifeste, testable sans disque.
pub fn classify(text: &str) -> LayerState {
    let mut name = None;
    let mut version = None;
    let mut built_on = None;
    let mut contract = None;
    let mut platforms = Vec::new();
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((k, v)) = line.split_once('=') else {
            return LayerState::Unreadable(format!(
                "« {line} » n'est pas de la forme clé = valeur"
            ));
        };
        let v = v.trim().trim_matches(['"', '\'']);
        match k.trim() {
            "name" => name = Some(v.to_string()),
            "version" => version = Some(v.to_string()),
            "built_on" => built_on = Some(v.to_string()),
            "contract" => match v.parse::<u32>() {
                Ok(n) => contract = Some(n),
                Err(_) => {
                    return LayerState::Unreadable(format!("contract « {v} » n'est pas un entier"))
                }
            },
            "platforms" => {
                platforms = v
                    .split(',')
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty())
                    .collect();
            }
            // Clé inconnue (ex. `files`) : ignorée, pour qu'un manifeste plus récent reste lisible.
            _ => {}
        }
    }
    let (Some(name), Some(version), Some(built_on), Some(contract)) =
        (name, version, built_on, contract)
    else {
        return LayerState::Unreadable("name, version, built_on et contract sont requis".into());
    };
    let layer = Layer {
        name,
        version,
        built_on,
        contract,
        platforms,
    };
    if layer.contract == CONTRACT {
        LayerState::Usable(layer)
    } else {
        LayerState::StaleContract(layer)
    }
}

/// Lignes de `doctor` pour la couche (une ou deux). `core_version` = version de ce noyau.
pub fn doctor_lines(state: &LayerState, core_version: &str) -> Vec<String> {
    match state {
        LayerState::Absent => vec!["Couche : absente (noyau public seul)".to_string()],
        LayerState::Unreadable(why) => vec![format!(
            "Couche : PROBLÈME, manifeste inutilisable ({why}) : noyau public utilisé"
        )],
        LayerState::StaleContract(l) => vec![format!(
            "Couche : {} {} — PROBLÈME, contrat périmé (couche {}, noyau {CONTRACT}) : noyau public utilisé. \
             Relance la mise à jour de la couche.",
            l.name, l.version, l.contract
        )],
        LayerState::Usable(l) => {
            let mut v = vec![format!(
                "Couche : {} {} (construite sur {}, contrat {}) — utilisable",
                l.name, l.version, l.built_on, l.contract
            )];
            if l.built_on != core_version {
                v.push(format!(
                    "Couche : construite sur le public {} alors que ce noyau est le {core_version} : \
                     relance la mise à jour de la couche.",
                    l.built_on
                ));
            }
            v
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const OK: &str = "name = extension\nversion = 3.0.0+ext.1\nbuilt_on = 3.0.0\ncontract = 1\nplatforms = darwin-*,linux-*\n";

    #[test]
    fn a_complete_manifest_is_usable_and_lists_platforms() {
        let LayerState::Usable(l) = classify(OK) else {
            panic!()
        };
        assert_eq!(l.name, "extension");
        assert_eq!(l.platforms, ["darwin-*", "linux-*"]);
    }

    #[test]
    fn a_stale_contract_is_reported_and_names_both_numbers() {
        let s = classify(&OK.replace("contract = 1", "contract = 2"));
        assert!(matches!(s, LayerState::StaleContract(_)));
        let t = doctor_lines(&s, "3.0.0").join("\n");
        assert!(t.contains("contrat périmé (couche 2, noyau 1)"), "{t}");
    }

    #[test]
    fn missing_fields_or_bad_lines_are_unreadable_never_usable() {
        for bad in [
            "name = a\n",
            "pas une ligne\n",
            "name=a\nversion=1\nbuilt_on=1\ncontract=x\n",
            "",
        ] {
            assert!(
                matches!(classify(bad), LayerState::Unreadable(_)),
                "{bad:?}"
            );
        }
    }

    #[test]
    fn unknown_keys_comments_and_quotes_are_tolerated() {
        let t =
            format!("# posé par la couche\nfiles = config/remote.conf\n{OK}name = \"extension\"\n");
        assert!(matches!(classify(&t), LayerState::Usable(_)));
    }

    #[test]
    fn an_older_build_gets_a_second_line_asking_for_the_update() {
        let s = classify(OK);
        assert_eq!(doctor_lines(&s, "3.0.0").len(), 1);
        let t = doctor_lines(&s, "3.1.0");
        assert_eq!(t.len(), 2);
        assert!(t[1].contains("construite sur le public 3.0.0"), "{t:?}");
    }

    #[test]
    fn an_absent_layer_says_so() {
        assert_eq!(
            doctor_lines(&LayerState::Absent, "3.0.0"),
            ["Couche : absente (noyau public seul)"]
        );
    }

    #[test]
    fn reading_a_root_without_overlay_is_absent_and_creates_nothing() {
        let d = tempfile::tempdir().unwrap();
        let root = Root::new(d.path().to_str().unwrap(), crate::root::PathStyle::native()).unwrap();
        assert_eq!(read(&root), LayerState::Absent);
        assert!(!d.path().join("overlay").exists());
    }
}
