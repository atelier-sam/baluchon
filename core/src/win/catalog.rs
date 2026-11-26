//! Catalogue des logiciels Windows : TOML embarqué + surcharge `config/catalog.toml`.
//!
//! Façade. Le catalogue embarqué, sa fusion par clé et la validation vivent dans la crate
//! `baluchon-winget` (une seule base pour tous ses utilisateurs, sans copie). Les chemins
//! d'ici (`win::catalog::App`, `load`, `render_lines`…) sont ceux d'avant l'extraction.
//!
//! Ce qui reste au noyau, parce que c'est SA politique : où lire la surcharge
//! (`<racine>/config/catalog.toml`), quoi faire d'une surcharge cassée (la signaler et
//! retomber sur l'embarqué), la sortie JSON, et la correspondance des erreurs de la crate avec
//! les codes de sortie du noyau.

use crate::error::{CcpError, Result};
pub use baluchon_winget::catalog::{
    clean_label, render_lines, valid_key, valid_winget_id, App, EMBEDDED,
};
use baluchon_winget::catalog::{merge, parse_file};
use baluchon_winget::Erreur;
use serde::Serialize;
use std::path::Path;

/// Nom du fichier de surcharge, sous `<racine>/config/`.
pub const OVERRIDE_FILE: &str = "catalog.toml";

/// Une clé inconnue est une faute d'usage (code 2) ; un catalogue invalide est interne.
/// Le conseil « voir win catalog » est celui de la ligne de commande du noyau : la crate, qui
/// n'en a pas, ne le porte pas.
impl From<Erreur> for CcpError {
    fn from(e: Erreur) -> CcpError {
        match e {
            Erreur::Invalide(m) => CcpError::Internal(m),
            Erreur::Inconnu(cles) => CcpError::Usage(format!(
                "logiciel(s) inconnu(s) du catalogue : {} (voir « win catalog »)",
                cles.join(", ")
            )),
        }
    }
}

/// Catalogue embarqué seul (celui des tests et du repli).
pub fn embedded() -> Result<Vec<App>> {
    Ok(baluchon_winget::catalog::embedded()?)
}

/// Catalogue embarqué + surcharge de la racine. Une surcharge illisible ou
/// invalide n'empêche pas le wizard de proposer le catalogue de base : on la
/// signale sur stderr et on l'ignore (`warn` reçoit le message).
pub fn load(root_dir: &Path, warn: &mut dyn FnMut(String)) -> Result<Vec<App>> {
    let base = parse_file(EMBEDDED, "catalogue embarqué")?;
    let file = root_dir.join("config").join(OVERRIDE_FILE);
    let over = match std::fs::read_to_string(&file) {
        Ok(text) => match parse_file(&text, &file.display().to_string()) {
            Ok(v) => v,
            Err(m) => {
                warn(format!("{m} ; surcharge ignorée."));
                Vec::new()
            }
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
        Err(e) => {
            warn(format!(
                "{} illisible ({e}) ; surcharge ignorée.",
                file.display()
            ));
            Vec::new()
        }
    };
    let origin = file.display().to_string();
    // Si la fusion échoue À CAUSE de la surcharge, on retombe sur l'embarqué seul.
    let base_again = parse_file(EMBEDDED, "catalogue embarqué")?;
    match merge(base, over, &origin) {
        Ok(v) => Ok(v),
        Err(m) => {
            warn(format!("{m} ; surcharge ignorée."));
            Ok(merge(base_again, Vec::new(), "catalogue embarqué")?)
        }
    }
}

pub fn render_json(apps: &[App]) -> Result<String> {
    #[derive(Serialize)]
    struct Out<'a> {
        schema: u32,
        apps: &'a [App],
    }
    serde_json::to_string(&Out { schema: 1, apps })
        .map_err(|e| CcpError::Internal(format!("sérialisation JSON : {e}")))
}

/// Résout des clés demandées ; les inconnues sont listées TOUTES d'un coup.
pub fn resolve<'a>(apps: &'a [App], keys: &[String]) -> Result<Vec<&'a App>> {
    Ok(baluchon_winget::catalog::resolve(apps, keys)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_override(dir: &Path, text: &str) {
        std::fs::create_dir_all(dir.join("config")).unwrap();
        std::fs::write(dir.join("config").join(OVERRIDE_FILE), text).unwrap();
    }

    #[test]
    fn override_changes_one_field_without_copying_the_entry() {
        let t = tempfile::tempdir().unwrap();
        write_override(
            t.path(),
            "[[app]]\nkey = \"chrome\"\ndefault = false\n\n[[app]]\nkey = \"firefox\"\ndefault = true\n",
        );
        let apps = load(t.path(), &mut |_m| {}).unwrap();
        let chrome = apps.iter().find(|a| a.key == "chrome").unwrap();
        assert!(!chrome.default);
        assert_eq!(chrome.winget, "Google.Chrome");
        assert_eq!(chrome.label, "Google Chrome");
        assert!(apps.iter().find(|a| a.key == "firefox").unwrap().default);
        // L'ordre du catalogue de base est conservé.
        assert_eq!(apps[0].key, "chrome");
    }

    #[test]
    fn override_can_add_and_remove_entries() {
        let t = tempfile::tempdir().unwrap();
        write_override(
            t.path(),
            "[[app]]\nkey = \"gimp\"\nlabel = \"GIMP, retouche\"\nwinget = \"GIMP.GIMP.3\"\n\n\
             [[app]]\nkey = \"winrar\"\nremove = true\n",
        );
        let apps = load(t.path(), &mut |_m| {}).unwrap();
        assert!(!apps.iter().any(|a| a.key == "winrar"));
        let gimp = apps.iter().find(|a| a.key == "gimp").unwrap();
        // La virgule du libellé est neutralisée (gum), la catégorie par défaut posée.
        assert_eq!(gimp.label, "GIMP retouche");
        assert_eq!(gimp.category, "Divers");
        assert!(!gimp.default);
        assert_eq!(apps.last().unwrap().key, "gimp");
    }

    #[test]
    fn a_broken_override_falls_back_to_the_embedded_catalog_with_a_warning() {
        for bad in [
            "ceci n'est pas du toml [[",
            "[[app]]\nkey = \"nouveau\"\nlabel = \"Sans winget\"\n",
            "[[app]]\nkey = \"chrome\"\nwinget = \"-oEvil\"\n",
            "[[app]]\nkey = \"Majuscule\"\nlabel = \"x\"\nwinget = \"A.B\"\n",
            "[[app]]\nkey = \"chrome\"\ninconnu = 1\n",
        ] {
            let t = tempfile::tempdir().unwrap();
            write_override(t.path(), bad);
            let mut warnings = Vec::new();
            let apps = load(t.path(), &mut |m| warnings.push(m)).unwrap();
            assert_eq!(apps, embedded().unwrap(), "repli attendu pour {bad:?}");
            assert_eq!(warnings.len(), 1, "{bad:?}");
            assert!(warnings[0].contains("surcharge ignorée"), "{warnings:?}");
        }
    }

    #[test]
    fn missing_override_is_silent() {
        let t = tempfile::tempdir().unwrap();
        let mut warnings = Vec::new();
        let apps = load(t.path(), &mut |m| warnings.push(m)).unwrap();
        assert_eq!(apps, embedded().unwrap());
        assert!(warnings.is_empty());
    }

    #[test]
    fn unknown_keys_are_a_usage_error_exit_2_that_points_to_the_catalog_command() {
        let apps = embedded().unwrap();
        let keys: Vec<String> = ["chrome", "nope", "zzz"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let e = resolve(&apps, &keys).unwrap_err();
        assert_eq!(e.exit_code(), 2);
        assert_eq!(
            e.to_string(),
            "logiciel(s) inconnu(s) du catalogue : nope, zzz (voir « win catalog »)"
        );
    }

    #[test]
    fn an_invalid_catalog_is_an_internal_error_not_a_usage_one() {
        let e: CcpError = Erreur::Invalide("catalogue embarqué invalide : x".into()).into();
        assert_ne!(e.exit_code(), 2);
        assert!(e.to_string().contains("catalogue embarqué invalide : x"));
    }

    #[test]
    fn json_output_has_schema_and_fields() {
        let apps = embedded().unwrap();
        let v: serde_json::Value = serde_json::from_str(&render_json(&apps).unwrap()).unwrap();
        assert_eq!(v["schema"], 1);
        assert_eq!(v["apps"][0]["key"], "chrome");
        assert_eq!(v["apps"][0]["winget"], "Google.Chrome");
        assert_eq!(v["apps"][0]["default"], true);
    }
}
