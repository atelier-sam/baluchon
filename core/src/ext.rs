//! La couture entre le noyau public et ce qui ne l'est pas : l'`Extension`.
//!
//! Pourquoi elle existe. Le noyau public affiche les quotas en LISANT le jeton de
//! l'utilisateur ; il ne le renouvelle pas, ne rejoue aucun journal et n'écrit pas
//! dans le Trousseau. Tout ce qui écrit sur un identifiant d'Anthropic vit de
//! l'autre côté de cette couture, dans une couche privée qui fournit SA propre
//! implémentation de ce trait. Le public ne contient donc aucun code de
//! renouvellement : il ne peut pas en exécuter un par erreur.
//!
//! Chaque méthode est un point d'injection : un endroit précis du public qui
//! demandait jusqu'ici un appel direct à `oauth::`, à une liste codée en dur ou à
//! une commande fermée. La table de référence (point, appel public, méthode, défaut
//! `ReadOnly`) est parcourue par `tests/seam.rs` : un point rebranché en direct à
//! `oauth::` fait rougir le test de balayage des sources.
//!
//! Aucune méthode n'a d'implémentation par défaut, exprès : un point ajouté au trait
//! plus tard doit casser la compilation de chaque implémentation, pas hériter en
//! silence d'un comportement qu'on n'a pas choisi.
//!
//! `Session` est PASSIVE à ce stade : elle porte les références dont l'ancien appel
//! direct avait besoin (environnement, API, profil, compteur critique, login lu,
//! verrou tenu). Le verrou de session et le marqueur de renouvellement restent pris
//! par le code de renouvellement lui-même ; ils passeront du côté de l'enveloppe
//! publique quand ce code aura déménagé (lot 2), sans changer la signature ci-dessous.

use crate::api::Api;
use crate::creds::Loaded;
use crate::discover::Origin;
use crate::env::Env;
use crate::error::{CcpError, Result};
use crate::lock::SessionGuard;
use crate::root::{ProfileDir, Root};
use crate::status::Deps;
use std::ffi::OsString;
use std::path::PathBuf;
use std::sync::atomic::AtomicUsize;

/// Pourquoi on demande un renouvellement.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Trigger {
    /// `expiresAt` dépassé (ou dans moins d'une minute).
    Expired,
    /// Le serveur a répondu 401 au jeton d'accès (une seule fois par sonde).
    Unauthorized,
}

/// Issue d'une demande de renouvellement.
#[derive(Debug, PartialEq)]
pub enum Renewal {
    Renewed,
    /// Un autre processus a déjà renouvelé, ou le login a changé : rien à faire.
    AlreadyFresh,
    Revoked,
    /// Une session ou un autre renouvellement tient le verrou.
    SessionBusy,
    Unreachable(String),
    Failed(String),
    /// Cette édition ne renouvelle pas : Claude le fera au lancement.
    Unsupported,
}

/// Issue d'une reprise de renouvellement interrompu.
#[derive(Debug, PartialEq)]
pub enum Recovery {
    Nothing,
    Applied,
    /// Journal périmé (déjà appliqué, ou le login a changé depuis) : effacé.
    Discarded,
    /// Session en cours : on ne touche pas au magasin, on réessaiera.
    Busy,
    Failed(String),
}

/// Ce que le public met à la disposition de l'extension pour UN geste (un
/// renouvellement, une reprise). Seul le public la construit.
pub struct Session<'a> {
    env: &'a Env,
    api: &'a Api,
    profile: &'a ProfileDir,
    critical: &'a AtomicUsize,
    seen: Option<&'a Loaded>,
    held: Option<&'a SessionGuard>,
}

impl<'a> Session<'a> {
    /// Renouvellement demandé pour le login `seen`, lu par la sonde.
    pub(crate) fn for_renewal(d: &'a Deps, profile: &'a ProfileDir, seen: &'a Loaded) -> Self {
        Session {
            env: &d.env,
            api: &d.api,
            profile,
            critical: &d.critical,
            seen: Some(seen),
            held: None,
        }
    }

    /// Reprise d'un renouvellement interrompu. `held` : le verrou de session que
    /// l'appelant tient déjà (lancement de Claude), sinon la reprise le prend elle-même.
    pub(crate) fn for_recovery(
        d: &'a Deps,
        profile: &'a ProfileDir,
        held: Option<&'a SessionGuard>,
    ) -> Self {
        Session {
            env: &d.env,
            api: &d.api,
            profile,
            critical: &d.critical,
            seen: None,
            held,
        }
    }

    pub fn env(&self) -> &Env {
        self.env
    }
    pub fn api(&self) -> &Api {
        self.api
    }
    pub fn profile(&self) -> &ProfileDir {
        self.profile
    }
    /// Compteur des sections critiques en cours : une sonde qui dépasse son budget
    /// n'est PAS abandonnée tant qu'il n'est pas retombé à 0.
    pub fn critical(&self) -> &AtomicUsize {
        self.critical
    }
    /// Le login lu par la sonde (renouvellement seulement).
    pub fn seen(&self) -> Option<&Loaded> {
        self.seen
    }
    /// Le verrou de session déjà tenu par l'appelant (reprise au lancement seulement).
    pub fn held(&self) -> Option<&SessionGuard> {
        self.held
    }
}

/// Un dossier de profils d'un autre outil à inventorier en lecture seule.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExtraOrigin {
    pub origin: Origin,
    /// Libellé court pour l'écran (`outil/profil`…), choisi par l'extension.
    pub label: String,
    pub dir: PathBuf,
}

/// Une sous-commande que le public ne connaît pas, offerte à l'extension.
pub struct External<'a> {
    /// Le nom de la sous-commande puis ses arguments, tels que saisis.
    pub args: &'a [OsString],
    env: &'a Env,
    root_arg: Option<&'a str>,
}

impl<'a> External<'a> {
    pub(crate) fn new(args: &'a [OsString], env: &'a Env, root_arg: Option<&'a str>) -> Self {
        External {
            args,
            env,
            root_arg,
        }
    }

    pub fn env(&self) -> &Env {
        self.env
    }

    /// Résolue à la demande : une commande inconnue n'a pas besoin d'une racine
    /// valide pour répondre « usage » (code 2).
    pub fn root(&self) -> Result<Root> {
        Root::resolve(self.root_arg)
    }
}

pub trait Extension: Send + Sync {
    /// Nom de l'édition affiché par `about --json`. `"public"` est réservé au noyau
    /// sans couche privée : le wizard s'en sert pour savoir quel noyau il tient.
    fn edition(&self) -> &'static str;

    /// Renouvelle le jeton du login vu par la sonde (`Run::renew`).
    fn renew(&self, s: &Session<'_>, why: Trigger) -> Renewal;

    /// Rejoue un renouvellement interrompu : avant toute lecture du statut, et au
    /// lancement de Claude (verrou tenu).
    fn recover(&self, s: &Session<'_>) -> Recovery;

    /// Ce profil porte-t-il un refus de renouvellement mémorisé pour CE login
    /// (empreinte `fp`) ? Peut effacer un marqueur périmé.
    fn is_revoked(&self, p: &ProfileDir, fp: &str) -> bool;

    /// Fichiers secrets propres à l'extension, à effacer en plus de ceux du public.
    fn secret_files(&self, p: &ProfileDir) -> Vec<PathBuf>;

    /// Lignes de diagnostic propres à l'extension pour ce profil (`doctor`).
    fn doctor_lines(&self, p: &ProfileDir) -> Vec<String>;

    /// Dossiers de profils d'autres outils à inventorier (`accounts discover`).
    fn extra_origins(&self, env: &Env) -> Vec<ExtraOrigin>;

    /// Sous-commande inconnue du public. `None` = inconnue aussi de l'extension
    /// (le public répond alors « usage », code 2).
    fn external(&self, call: &External<'_>) -> Option<Result<i32>>;
}

/// Édition publique : lecture seule, aucun effet de bord. C'est le comportement
/// livré aux utilisateurs.
pub struct ReadOnly;

impl Extension for ReadOnly {
    fn edition(&self) -> &'static str {
        "public"
    }
    fn renew(&self, _s: &Session<'_>, _why: Trigger) -> Renewal {
        Renewal::Unsupported
    }
    fn recover(&self, _s: &Session<'_>) -> Recovery {
        Recovery::Nothing
    }
    fn is_revoked(&self, _p: &ProfileDir, _fp: &str) -> bool {
        false
    }
    fn secret_files(&self, _p: &ProfileDir) -> Vec<PathBuf> {
        Vec::new()
    }
    fn doctor_lines(&self, p: &ProfileDir) -> Vec<String> {
        orphan_journal_lines(p)
    }
    fn extra_origins(&self, _env: &Env) -> Vec<ExtraOrigin> {
        Vec::new()
    }
    fn external(&self, _call: &External<'_>) -> Option<Result<i32>> {
        None
    }
}

/// M7 : un journal de renouvellement (`.ccp-pending`) ou sa réservation laissés par une autre
/// édition. Le public ne les rejoue JAMAIS (il ne sait pas écrire un identifiant) ; il le dit,
/// pour que l'utilisateur ne l'apprenne pas de `claude`. Lecture seule : `exists()` seulement.
pub fn orphan_journal_lines(p: &ProfileDir) -> Vec<String> {
    if p.pending_journal().exists() || p.pending_reserve().exists() {
        vec![format!(
            "Journal de renouvellement orphelin dans {} : ce compte devra peut-être être \
             reconnecté (le jeton renouvelé n'a jamais été écrit). Le public ne le rejoue pas.",
            p.name
        )]
    } else {
        Vec::new()
    }
}

/// « Commande inconnue » : le message du public quand aucune extension ne la prend.
pub(crate) fn unknown_command(args: &[OsString]) -> CcpError {
    let name = args
        .first()
        .map(|a| a.to_string_lossy().into_owned())
        .unwrap_or_default();
    CcpError::Usage(format!("commande inconnue « {name} » (voir --help)"))
}
