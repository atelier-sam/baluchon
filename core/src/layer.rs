//! La COUCHE : un dossier `<racine>/overlay/` que le public sait LIRE sans en connaître
//! le contenu (H1 de la revue d'ingénierie).
//!
//! Le noyau public ne remplace, n'écrit ni ne supprime jamais rien sous `overlay/` : une
//! mise à jour du portable n'écrit que `bin/`. Une couche (un noyau complémentaire, des
//! crochets `hooks/update` et `hooks/uninstall`) se pose à côté et se met à jour par ses
//! propres crochets. Ici, on ne fait que dire ce qu'on voit (`doctor`).
//!
//! Manifeste `LAYER`, lignes `clé = valeur` (même syntaxe que `config/remote.conf`) :
//! `name`, `version`, `built_on` (version publique de construction), `contract` (contrat CLI
//! du noyau de la couche), `platforms` (liste séparée par des virgules, jokers `*`).
//!
//! Il vit dans la GÉNÉRATION courante : `overlay/gen/<nom>/LAYER`, désignée par le pointeur
//! `overlay/CURRENT` (voir [`current_dir`]). La génération est posée en entier avant d'être
//! visible, puis un seul renommage la désigne : un lecteur sans verrou voit l'ancienne ou la
//! nouvelle, jamais un mélange. Sans pointeur, la couche est à plat sous `overlay/`.

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

/// Nom du pointeur de génération, sous `<racine>/overlay/`.
pub const POINTER: &str = "CURRENT";

/// Le dossier `overlay/` (racine des générations, des crochets et du pointeur).
pub fn dir(root: &Root) -> PathBuf {
    root.path().join("overlay")
}

/// Dossier de la génération COURANTE de la couche : `overlay/CURRENT` contient `gen/<nom>`, le
/// dossier est posé EN ENTIER avant que le pointeur ne le désigne (un seul renommage), donc une
/// lecture sous ce dossier voit une génération entière. Sans pointeur, la couche est à plat sous
/// `overlay/` (posée avant les générations). Un pointeur présent mais invalide (lien, forme
/// inattendue, dossier absent ou lien) est une ERREUR : on ne devine jamais une autre génération.
///
/// Lit une seule fois le pointeur ; n'écrit ni ne crée jamais rien.
pub fn current_dir(root: &Root) -> Result<PathBuf, String> {
    let overlay = dir(root);
    let pointer = overlay.join(POINTER);
    let meta = match fs::symlink_metadata(&pointer) {
        Ok(m) => m,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(overlay),
        Err(e) => return Err(format!("{} illisible : {e}", pointer.display())),
    };
    if !meta.is_file() {
        return Err(format!(
            "{} n'est pas un fichier ordinaire (lien ou dossier)",
            pointer.display()
        ));
    }
    let text = fs::read_to_string(&pointer)
        .map_err(|e| format!("{} illisible : {e}", pointer.display()))?;
    let name = parse_pointer(&text).ok_or_else(|| {
        format!(
            "{} : contenu inattendu (« gen/<nom> » attendu)",
            pointer.display()
        )
    })?;
    let gen = overlay.join("gen").join(name);
    match fs::symlink_metadata(&gen) {
        Ok(m) if m.is_dir() => Ok(gen),
        _ => Err(format!(
            "{} désigne {}, qui n'est pas un dossier de génération",
            pointer.display(),
            gen.display()
        )),
    }
}

/// Pure : le nom de génération que désigne le contenu de `CURRENT` (`gen/<nom>`), si la forme est
/// stricte. Le nom ne porte ni séparateur ni `..` : le pointeur ne sort jamais de `overlay/gen/`.
pub fn parse_pointer(text: &str) -> Option<&str> {
    let line = text.lines().next()?.trim_end_matches('\r');
    let name = line.strip_prefix("gen/")?;
    let mut chars = name.chars();
    let first = chars.next()?;
    let valid = first.is_ascii_alphanumeric()
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'));
    valid.then_some(name)
}

/// Lit le manifeste de la génération courante. Ne crée, n'écrit ni ne déplace jamais rien.
pub fn read(root: &Root) -> LayerState {
    let base = match current_dir(root) {
        Ok(d) => d,
        Err(e) => return LayerState::Unreadable(e),
    };
    let p = base.join(MANIFEST);
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

    // --- Générations : `overlay/CURRENT` désigne `overlay/gen/<nom>/` -------------------------------

    fn root_of(d: &tempfile::TempDir) -> Root {
        Root::new(d.path().to_str().unwrap(), crate::root::PathStyle::native()).unwrap()
    }

    fn write(path: &std::path::Path, text: &str) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    }

    #[test]
    fn pointer_forms_are_strict_and_never_leave_overlay_gen() {
        assert_eq!(
            parse_pointer("gen/g20261111T0459Z-1\n"),
            Some("g20261111T0459Z-1")
        );
        assert_eq!(parse_pointer("gen/abc.def_1-2\r\n"), Some("abc.def_1-2"));
        for bad in [
            "",
            "\n",
            "g20261111",
            "gen/",
            "gen/..",
            "gen/../x",
            "gen/a/b",
            "gen//etc",
            "/etc/passwd",
            "gen/.hidden",
            "gen/-x",
            "gen/a b",
            "../gen/a",
            "gen\\a",
        ] {
            assert_eq!(parse_pointer(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn the_pointer_wins_over_a_stale_flat_manifest() {
        let d = tempfile::tempdir().unwrap();
        let o = d.path().join("overlay");
        write(
            &o.join("LAYER"),
            &OK.replace("extension", "ancienne-a-plat"),
        );
        write(&o.join("gen/g1/LAYER"), OK);
        write(&o.join("CURRENT"), "gen/g1\n");
        let LayerState::Usable(l) = read(&root_of(&d)) else {
            panic!("la génération désignée doit être lue")
        };
        assert_eq!(l.name, "extension");
    }

    #[test]
    fn without_a_pointer_the_flat_layout_is_still_read() {
        let d = tempfile::tempdir().unwrap();
        write(&d.path().join("overlay/LAYER"), OK);
        assert!(matches!(read(&root_of(&d)), LayerState::Usable(_)));
    }

    #[test]
    fn an_invalid_pointer_is_unreadable_never_a_guess() {
        let d = tempfile::tempdir().unwrap();
        let o = d.path().join("overlay");
        // La couche à plat est valide : un pointeur illisible ne doit PAS retomber dessus.
        write(&o.join("LAYER"), OK);
        for bad in ["", "gen/../..", "gen/absente", "n'importe quoi", "gen/a/b"] {
            write(&o.join("CURRENT"), bad);
            assert!(
                matches!(read(&root_of(&d)), LayerState::Unreadable(_)),
                "{bad:?}"
            );
        }
        // Un pointeur dont la génération n'a pas de manifeste : couche absente, pas un repli à plat.
        fs::create_dir_all(o.join("gen/vide")).unwrap();
        write(&o.join("CURRENT"), "gen/vide\n");
        assert_eq!(read(&root_of(&d)), LayerState::Absent);
    }

    #[cfg(unix)]
    #[test]
    fn a_pointer_or_generation_that_is_a_link_is_refused() {
        use std::os::unix::fs::symlink;
        let d = tempfile::tempdir().unwrap();
        let o = d.path().join("overlay");
        write(&d.path().join("ailleurs/LAYER"), OK);
        write(&o.join("gen/vrai/LAYER"), OK);
        // Le pointeur est un lien vers un vrai pointeur.
        write(&d.path().join("p.txt"), "gen/vrai\n");
        symlink(d.path().join("p.txt"), o.join("CURRENT")).unwrap();
        assert!(matches!(read(&root_of(&d)), LayerState::Unreadable(_)));
        fs::remove_file(o.join("CURRENT")).unwrap();
        // La génération est un lien vers un dossier extérieur.
        symlink(d.path().join("ailleurs"), o.join("gen/lien")).unwrap();
        write(&o.join("CURRENT"), "gen/lien\n");
        assert!(matches!(read(&root_of(&d)), LayerState::Unreadable(_)));
    }

    #[test]
    fn reading_through_the_pointer_creates_and_writes_nothing() {
        let d = tempfile::tempdir().unwrap();
        let o = d.path().join("overlay");
        write(&o.join("gen/g1/LAYER"), OK);
        write(&o.join("CURRENT"), "gen/g1\n");
        let avant = snapshot(&o);
        let _ = read(&root_of(&d));
        let _ = current_dir(&root_of(&d));
        assert_eq!(avant, snapshot(&o));
    }

    fn snapshot(dir: &std::path::Path) -> Vec<String> {
        fn walk(p: &std::path::Path, out: &mut Vec<String>) {
            for e in fs::read_dir(p).unwrap() {
                let e = e.unwrap();
                let m = e.metadata().unwrap();
                out.push(format!("{} {}", e.path().display(), m.len()));
                if m.is_dir() {
                    walk(&e.path(), out);
                }
            }
        }
        let mut v = Vec::new();
        walk(dir, &mut v);
        v.sort();
        v
    }
}
