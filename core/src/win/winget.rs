//! Installation de logiciels par winget : arguments, codes de sortie, résultats.
//!
//! Façade. Le moteur (arguments figés, table des codes de sortie, verdict par paquet, trait
//! `Winget`) vit dans la crate `baluchon-winget`, liée aussi par des programmes qui n'ont
//! besoin ni de TLS ni de clap : un seul juge des codes pour tous. Les chemins d'ici
//! (`win::winget::install_one`, `Status`…) sont ceux d'avant l'extraction.
//!
//! Ce qui reste au noyau : l'exécuteur de processus, [`RealWinget`], branché sur
//! `util::run_bounded` (délai, tuyaux bornés).

pub use baluchon_winget::winget::{
    classify_exit, install_args, install_one, one_line, summarize_output, Classified,
    PackageResult, RunOut, Status, Winget, INSTALL_TIMEOUT, VERSION_TIMEOUT, WINGET_MISSING,
};
use std::time::Duration;

/// Vrai winget : `winget` du PATH (alias d'exécution de l'App Installer) ou le
/// binaire donné par `CCP_WINGET_BIN`.
pub struct RealWinget {
    bin: std::ffi::OsString,
}

impl RealWinget {
    pub fn new(bin: Option<&str>) -> RealWinget {
        RealWinget {
            bin: bin.unwrap_or("winget").into(),
        }
    }

    /// Winget répond-il ? `None` = introuvable ; `Some(version)` sinon.
    pub fn probe(&self) -> Option<String> {
        let w: &dyn Winget = self;
        match w.run(&["--version".to_string()], VERSION_TIMEOUT) {
            Ok(RunOut {
                code: Some(0),
                text,
            }) => Some(one_line(&text)),
            _ => None,
        }
    }
}

impl Winget for RealWinget {
    fn run(&self, args: &[String], timeout: Duration) -> std::io::Result<RunOut> {
        let mut cmd = std::process::Command::new(&self.bin);
        cmd.args(args);
        let out = crate::util::run_bounded(&mut cmd, None, timeout)?;
        // winget écrit sur stdout ; stderr porte rarement plus qu'une erreur de lancement.
        let mut text = out.stdout_str();
        let err = out.stderr_str();
        if !err.trim().is_empty() {
            text.push('\n');
            text.push_str(&err);
        }
        Ok(RunOut {
            code: out.code(),
            text,
        })
    }
}
