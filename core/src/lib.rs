//! baluchon-core : noyau « comptes » de Baluchon, lanceur portable pour Claude Code.
//! Le wizard bash affiche, ce noyau décide (statut, renouvellement, Trousseau, lancement).

pub mod api;
pub mod atomic;
pub mod cache;
pub mod claude_cli;
pub mod cli;
pub mod creds;
pub mod discover;
pub mod doctor;
pub mod env;
pub mod error;
pub mod expiry;
pub mod ext;
pub mod http;
pub mod layer;
pub mod lock;
pub mod model;
pub mod plan;
pub mod privdir;
pub mod purge;
pub mod recommend;
pub mod remote;
pub mod render;
pub mod root;
pub mod run;
pub mod status;
pub mod timefmt;
pub mod util;
pub mod win;

pub use cli::run_with;
