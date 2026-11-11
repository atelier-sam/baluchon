//! Binaire `baluchon-core` : choisit l'extension et délègue à `baluchon_core::run_with`.
//! Aucune logique ici (voir `baluchon_core::cli`).

use baluchon_core::ext::ReadOnly;
use baluchon_core::run_with;
use std::io::Write;
use std::process::ExitCode;
use std::sync::Arc;

fn main() -> ExitCode {
    // `panic = "abort"` en release : sans ce hook un bug donnerait un SIGABRT
    // muet (code 134). Le wizard attend le code 10 et un message lisible.
    std::panic::set_hook(Box::new(|info| {
        let _ = writeln!(
            std::io::stderr(),
            "baluchon-core : erreur interne ({info}). Lance « doctor » ou signale-le."
        );
        std::process::exit(10);
    }));

    // `ReadOnly` : l'édition publique. Elle lit le jeton de l'utilisateur pour afficher
    // les quotas et ne renouvelle, ne rejoue et n'écrit rien. Une édition étendue est une
    // AUTRE crate, avec son propre binaire, qui appelle la même `run_with` avec son impl.
    let code = run_with(Arc::new(ReadOnly), std::env::args_os());
    ExitCode::from(u8::try_from(code).unwrap_or(10))
}
