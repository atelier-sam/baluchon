//! baluchon-winget : le moteur « winget » de Baluchon, sans le reste du noyau.
//!
//! - [`catalog`] : le catalogue de logiciels (TOML embarqué, fusion PAR CLÉ, champ par champ) ;
//! - [`winget`] : les arguments de `winget install`, la lecture de ses codes de sortie, le
//!   verdict par paquet, et le trait [`winget::Winget`] derrière lequel un appelant branche
//!   SON exécuteur de processus.
//!
//! La crate n'exécute rien et n'ouvre aucun fichier : elle juge. Le noyau (`baluchon-core`)
//! la ré-exporte sous les mêmes chemins qu'avant ; un autre programme qui doit installer des
//! logiciels sans tirer TLS ni clap dans son arbre la lie directement. Un seul juge des
//! codes de sortie, un seul découpage de la sortie en lignes, pour tous.

pub mod catalog;
pub mod winget;

use std::fmt;

/// Ce qui peut refuser un catalogue ou une demande. Le noyau le range dans ses propres
/// erreurs (code de sortie 2 pour [`Erreur::Inconnu`], erreur interne pour [`Erreur::Invalide`]).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Erreur {
    /// Catalogue ou surcharge illisible ou invalide ; le message nomme l'origine fautive.
    Invalide(String),
    /// Clés demandées absentes du catalogue : TOUTES, listées d'un coup.
    Inconnu(Vec<String>),
}

impl fmt::Display for Erreur {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Erreur::Invalide(m) => f.write_str(m),
            Erreur::Inconnu(cles) => write!(
                f,
                "logiciel(s) inconnu(s) du catalogue : {}",
                cles.join(", ")
            ),
        }
    }
}

impl std::error::Error for Erreur {}
