//! Installation de logiciels par winget : arguments, codes de sortie, résultats.
//!
//! Sortie par paquet sur stdout (contrat avec le wizard) :
//! `ok|deja|echec<TAB>clé<TAB>détail`, une ligne, jamais de tabulation dans le détail.
//!
//! Ce module ne lance aucun processus : l'exécution passe par le trait [`Winget`], que chaque
//! appelant implémente avec SON exécuteur (le noyau : `RealWinget`, borné par `run_bounded`).

use crate::catalog::App;
// WHY la liste vient d'une crate : une ligne rendue ici est AFFICHÉE à un technicien (nom de logiciel,
// détail d'un échec), et `char::is_control` n'attrape pas les caractères de FORMAT (U+202E retourne
// `gpj.exe` en `exe.jpg`, U+200B cache une partie du texte). La liste doit être la même chez tous ceux
// qui nettoient un texte avant de l'afficher : elle ne vit donc qu'à un endroit.
use baluchon_texte::invisible_trompeur;
use std::collections::VecDeque;
use std::time::Duration;

/// Durée maximale d'un paquet. Un installateur qui attend une fenêtre cachée ne
/// doit pas figer le lot entier ; 30 minutes couvrent les plus gros (.NET, Java).
pub const INSTALL_TIMEOUT: Duration = Duration::from_secs(30 * 60);
pub const VERSION_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    Ok,
    /// Déjà présent : c'est un succès pour le wizard.
    Already,
    Failed,
}

impl Status {
    pub fn word(self) -> &'static str {
        match self {
            Status::Ok => "ok",
            Status::Already => "deja",
            Status::Failed => "echec",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PackageResult {
    pub key: String,
    pub status: Status,
    pub detail: String,
}

impl PackageResult {
    /// La ligne exacte attendue par le wizard.
    pub fn line(&self) -> String {
        format!(
            "{}\t{}\t{}",
            self.status.word(),
            self.key,
            one_line(&self.detail)
        )
    }
}

/// Une ligne, sans tabulation : le format est séparé par des tabulations.
pub fn one_line(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Interprétation d'un code de sortie de `winget install`.
///
/// Source des valeurs : microsoft/winget-cli, `doc/windows/package-manager/winget/returnCodes.md`
/// (généré par `winget error --output`, version du 13/05/2026). Les codes sont des
/// HRESULT ; le processus les renvoie en entier signé 32 bits, d'où la comparaison en
/// `u32` ci-dessous.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Classified {
    pub status: Status,
    pub detail: String,
}

pub fn classify_exit(code: i32) -> Classified {
    let c = code as u32;
    let (status, msg): (Status, &str) = match c {
        0 => (Status::Ok, "installé"),
        // PACKAGE_ALREADY_INSTALLED : « Found at least one version of the package installed ».
        0x8A15_0061 => (Status::Already, "déjà installé"),
        // UPDATE_NOT_APPLICABLE : « No applicable update found » (déjà à jour).
        0x8A15_002B => (Status::Already, "déjà à jour"),
        // INSTALL_ALREADY_INSTALLED / INSTALL_DOWNGRADE : remontés par l'installateur lui-même.
        0x8A15_010D => (Status::Already, "une autre version est déjà installée"),
        0x8A15_010E => (
            Status::Already,
            "une version plus récente est déjà installée",
        ),
        // Installé mais le système doit redémarrer : le paquet EST là. 3010 et 1641 sont les
        // codes Windows Installer équivalents (ERROR_SUCCESS_REBOOT_REQUIRED / REBOOT_INITIATED).
        0x8A15_0109 | 3010 => (Status::Ok, "installé, redémarrage requis pour finir"),
        0x8A15_010B | 1641 => (Status::Ok, "installé, redémarrage en cours"),
        0x8A15_0010 => (Status::Failed, "aucun installateur adapté à cet ordinateur"),
        0x8A15_0011 => (
            Status::Failed,
            "empreinte de l'installateur invalide (téléchargement corrompu ?)",
        ),
        0x8A15_0017 => (Status::Failed, "paquet introuvable dans la source winget"),
        0x8A15_0019 => (Status::Failed, "droits administrateur requis"),
        0x8A15_003A | 0x8A15_010F => (Status::Failed, "bloqué par une stratégie de l'organisation"),
        0x8A15_0008 | 0x8A15_0086 => (
            Status::Failed,
            "téléchargement de l'installateur échoué (réseau ?)",
        ),
        0x8A15_0107 => (
            Status::Failed,
            "connexion Internet requise par l'installateur",
        ),
        0x8A15_0105 => (Status::Failed, "disque plein"),
        0x8A15_0101 | 0x8A15_0103 | 0x8A15_0111 => (
            Status::Failed,
            "l'application est en cours d'utilisation : ferme-la puis recommence",
        ),
        0x8A15_0102 => (
            Status::Failed,
            "une autre installation est en cours : recommence plus tard",
        ),
        0x8A15_0104 | 0x8A15_0110 => (Status::Failed, "dépendance manquante"),
        0x8A15_010A => (Status::Failed, "redémarre l'ordinateur puis recommence"),
        0x8A15_010C => (Status::Failed, "installation annulée"),
        0x8A15_0045 | 0x8A15_0015 | 0x8A15_000F => {
            (Status::Failed, "source winget inaccessible (réseau ?)")
        }
        0x8A15_0041 | 0x8A15_0046 => (Status::Failed, "conditions d'utilisation non acceptées"),
        0x8A15_0113 => (Status::Failed, "paquet non pris en charge par ce système"),
        _ => {
            return Classified {
                status: Status::Failed,
                detail: format!("échec (code winget 0x{c:08X})"),
            }
        }
    };
    Classified {
        status,
        detail: msg.to_string(),
    }
}

/// Arguments de `winget install` (golden test : l'ordre est figé).
pub fn install_args(id: &str, user_scope: bool) -> Vec<String> {
    let mut a: Vec<String> = [
        "install",
        "--id",
        id,
        "-e",
        "--silent",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--disable-interactivity",
        "--source",
        "winget",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    if user_scope {
        a.push("--scope".into());
        a.push("user".into());
    }
    a
}

/// Résultat brut d'une exécution de winget.
pub struct RunOut {
    /// `None` : tué faute de fin dans le délai.
    pub code: Option<i32>,
    pub text: String,
}

/// Exécuteur de winget derrière un trait : les arguments, les codes et les
/// verdicts se testent sans Windows.
pub trait Winget {
    fn run(&self, args: &[String], timeout: Duration) -> std::io::Result<RunOut>;

    /// Variante EN CONTINU : chaque ligne de la sortie part vers `sortie` au fil de l'eau,
    /// et l'exécuteur s'arrête si [`Sortie::annule`] répond vrai.
    ///
    /// Le défaut ne diffuse rien en direct : il exécute [`Winget::run`] (bloquant) puis REJOUE
    /// le texte ligne à ligne, par le même [`Decoupeur`]. Tout exécuteur existant reste donc
    /// valide sans changement ; seul celui qui sait lire un tuyau pendant que le processus
    /// tourne (et le tuer sur annulation) redéfinit cette méthode.
    fn run_flux(
        &self,
        args: &[String],
        timeout: Duration,
        sortie: &mut dyn Sortie,
    ) -> std::io::Result<Fin> {
        if sortie.annule() {
            return Ok(Fin::Annulee);
        }
        let r = self.run(args, timeout)?;
        let mut d = Decoupeur::new(LIGNE_MAX);
        d.pousse(r.text.as_bytes(), &mut |l| sortie.ligne(l));
        d.fin(&mut |l| sortie.ligne(l));
        Ok(match r.code {
            Some(c) => Fin::Code(c),
            None => Fin::Delai,
        })
    }
}

/// Longueur maximale, en octets, d'une ligne rendue à une [`Sortie`] : au-delà, la ligne est
/// COUPÉE (jamais rendue en entier). Une sortie sans fin de ligne ne fait donc pas grossir la
/// mémoire de l'appelant.
pub const LIGNE_MAX: usize = 512;

/// Comment un winget lancé en continu s'est terminé.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Fin {
    /// Le processus a rendu ce code de sortie : [`classify_exit`] le juge.
    Code(i32),
    /// Tué faute de fin dans le délai.
    Delai,
    /// Arrêté parce que [`Sortie::annule`] a répondu vrai.
    Annulee,
}

/// Où arrivent les lignes d'un winget en cours d'exécution, et par où l'on peut l'arrêter.
pub trait Sortie {
    /// Une ligne complète de la sortie de winget : jamais vide, bornée à [`LIGNE_MAX`] octets,
    /// sans caractère de commande. Les lignes de PROGRESSION (barres, pourcentage, tailles) sont
    /// rendues aussi : c'est l'appelant qui les lit ; le détail d'un échec, lui, les écarte.
    fn ligne(&mut self, l: &str);

    /// L'appelant veut-il arrêter l'installation ? Interrogé entre deux lectures.
    fn annule(&self) -> bool;
}

/// Découpe un flux d'octets en lignes, sur `\n` ET sur `\r` : winget redessine ses barres de
/// progression par un simple retour chariot, sans jamais aller à la ligne.
///
/// - Une ligne vide n'est jamais rendue (donc `\r\n` ne donne rien de plus que `\n`).
/// - Les caractères de commande ET les caractères de format invisibles trompeurs (sens d'écriture,
///   largeur nulle) sont retirés : une ligne rendue est sûre à afficher. Ce type DÉCOUPE et nettoie ;
///   il ne juge pas le sens de la ligne.
/// - Une ligne plus longue que la borne est COUPÉE : le surplus est jeté jusqu'au saut suivant,
///   la mémoire reste bornée quoi que la sortie contienne.
/// - Les octets s'accumulent AVANT d'être lus en UTF-8 : un caractère coupé entre deux lectures
///   du tuyau est reconstitué ; les octets invalides sont remplacés, jamais une erreur.
pub struct Decoupeur {
    ligne: Vec<u8>,
    borne: usize,
    coupee: bool,
}

impl Decoupeur {
    pub fn new(borne: usize) -> Decoupeur {
        Decoupeur {
            ligne: Vec::new(),
            borne: borne.max(1),
            coupee: false,
        }
    }

    /// Reçoit un morceau du flux ; chaque ligne complète part vers `f`.
    pub fn pousse(&mut self, octets: &[u8], f: &mut dyn FnMut(&str)) {
        for &b in octets {
            if b == b'\n' || b == b'\r' {
                self.rend(f);
            } else if self.ligne.len() < self.borne {
                self.ligne.push(b);
            } else {
                self.coupee = true;
            }
        }
    }

    /// Fin du flux : rend la ligne en cours, s'il y en a une.
    pub fn fin(&mut self, f: &mut dyn FnMut(&str)) {
        self.rend(f);
    }

    fn rend(&mut self, f: &mut dyn FnMut(&str)) {
        let coupee = std::mem::take(&mut self.coupee);
        let octets = std::mem::take(&mut self.ligne);
        let texte = String::from_utf8_lossy(&octets);
        // Une coupe au milieu d'un caractère laisse un octet incomplet en queue : il ne doit
        // pas ressortir en caractère de remplacement.
        let texte: &str = if coupee {
            texte.trim_end_matches('\u{FFFD}')
        } else {
            &texte
        };
        let propre: String = texte
            .chars()
            .map(|c| if c == '\t' { ' ' } else { c })
            .filter(|c| !c.is_control() && !invisible_trompeur(*c))
            .collect();
        let propre = propre.trim();
        if !propre.is_empty() {
            f(propre);
        }
    }
}

/// Lignes de progression de winget (barres, spinner, tailles) : du bruit pour un détail.
fn is_progress_noise(line: &str) -> bool {
    if line.is_empty() {
        return true;
    }
    if line.chars().any(|c| matches!(c, '█' | '▒' | '▓' | '░')) {
        return true;
    }
    // Spinner : un seul caractère parmi - \ | /
    if line.chars().count() <= 2
        && line
            .chars()
            .all(|c| matches!(c, '-' | '\\' | '|' | '/' | ' '))
    {
        return true;
    }
    // « 12.3 MB / 40.0 MB » ou « 85% »
    let l = line.trim();
    if l.ends_with('%') && l[..l.len() - 1].trim().parse::<f64>().is_ok() {
        return true;
    }
    l.contains(" MB / ") || l.contains(" KB / ") || l.contains(" GB / ")
}

/// Les deux dernières lignes utiles de la sortie de winget, en une ligne.
pub fn summarize_output(text: &str) -> String {
    let lines: Vec<String> = text
        .split(['\r', '\n'])
        .map(|l| {
            l.chars()
                .filter(|c| (!c.is_control() || *c == '\t') && !invisible_trompeur(*c))
                .collect::<String>()
                .trim()
                .to_string()
        })
        .filter(|l| !is_progress_noise(l))
        .collect();
    let tail: Vec<&str> = lines
        .iter()
        .rev()
        .take(2)
        .rev()
        .map(String::as_str)
        .collect();
    let joined = one_line(&tail.join(" / "));
    let mut out: String = joined.chars().take(200).collect();
    if joined.chars().count() > 200 {
        out.push('…');
    }
    out
}

/// Installe UN paquet. En mode utilisateur (`user_scope`), un paquet sans
/// installateur « par utilisateur » n'est pas tenté en machine : une invite UAC au
/// milieu d'un lot, sans que personne la voie, ferait croire à un blocage.
pub fn install_one(w: &dyn Winget, app: &App, user_scope: bool) -> PackageResult {
    let args = install_args(&app.winget, user_scope);
    let (fin, text) = match w.run(&args, INSTALL_TIMEOUT) {
        Ok(RunOut {
            code: Some(c),
            text,
        }) => (Ok(Fin::Code(c)), text),
        Ok(RunOut { code: None, text }) => (Ok(Fin::Delai), text),
        Err(e) => (Err(e), String::new()),
    };
    verdict(app, user_scope, fin, &text)
}

/// Installe UN paquet EN CONTINU : chaque ligne de la sortie de winget part vers `sortie`
/// pendant qu'il tourne, et `sortie.annule()` l'arrête. Le verdict est CELUI de
/// [`install_one`] (même [`classify_exit`], mêmes phrases) : un seul juge, que l'appelant
/// affiche une progression ou non. Une installation arrêtée par `annule` rend
/// `Status::Failed` avec une phrase qui le dit, jamais un nouveau statut (le contrat tabulé
/// lu par le wizard reste `ok|deja|echec`).
pub fn install_one_flux(
    w: &dyn Winget,
    app: &App,
    user_scope: bool,
    sortie: &mut dyn Sortie,
) -> PackageResult {
    let args = install_args(&app.winget, user_scope);
    let mut relais = Relais {
        sortie,
        dernieres: VecDeque::new(),
    };
    let fin = w.run_flux(&args, INSTALL_TIMEOUT, &mut relais);
    // Le détail d'un échec n'a besoin que de la fin de la sortie : les lignes utiles les plus
    // récentes suffisent (`summarize_output` n'en garde que deux).
    let text = Vec::from(relais.dernieres).join("\n");
    verdict(app, user_scope, fin, &text)
}

/// Combien de lignes utiles (hors progression) `install_one_flux` garde pour le détail d'un échec.
const LIGNES_DE_DETAIL: usize = 8;

/// Passe les lignes à la [`Sortie`] de l'appelant et retient les dernières lignes utiles.
struct Relais<'a> {
    sortie: &'a mut dyn Sortie,
    dernieres: VecDeque<String>,
}

impl Sortie for Relais<'_> {
    fn ligne(&mut self, l: &str) {
        self.sortie.ligne(l);
        if !is_progress_noise(l) {
            if self.dernieres.len() == LIGNES_DE_DETAIL {
                self.dernieres.pop_front();
            }
            self.dernieres.push_back(l.to_string());
        }
    }

    fn annule(&self) -> bool {
        self.sortie.annule()
    }
}

/// Le verdict, commun à `install_one` et `install_one_flux`.
fn verdict(app: &App, user_scope: bool, fin: std::io::Result<Fin>, text: &str) -> PackageResult {
    let failed = |detail: String| PackageResult {
        key: app.key.clone(),
        status: Status::Failed,
        detail,
    };
    let code = match fin {
        Ok(Fin::Code(c)) => c,
        Ok(Fin::Delai) => {
            return failed(format!(
                "pas de fin au bout de {} minutes, abandonné",
                INSTALL_TIMEOUT.as_secs() / 60
            ))
        }
        Ok(Fin::Annulee) => {
            return failed(
                "installation interrompue : vérifie dans les applications installées de Windows ce qui a pu rester".into(),
            )
        }
        Err(e) => return failed(format!("winget n'a pas pu être lancé : {e}")),
    };
    let mut c = classify_exit(code);
    if user_scope && (code as u32) == 0x8A15_0010 {
        c.detail =
            "installation pour tous les utilisateurs uniquement : relance en acceptant l'élévation administrateur".into();
    }
    if c.status == Status::Failed {
        let tail = summarize_output(text);
        if !tail.is_empty() {
            c.detail = format!("{} — {tail}", c.detail);
        }
    }
    PackageResult {
        key: app.key.clone(),
        status: c.status,
        detail: c.detail,
    }
}

pub const WINGET_MISSING: &str =
    "winget est introuvable sur cet ordinateur. Installe « Programme d'installation \
d'application » (App Installer) depuis le Microsoft Store, puis relance. \
(Windows LTSC et Windows Server n'ont pas winget d'origine.)";

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    fn app(key: &str, id: &str) -> App {
        App {
            key: key.into(),
            label: key.into(),
            category: "t".into(),
            winget: id.into(),
            default: false,
        }
    }

    struct Fake {
        replies: RefCell<Vec<std::io::Result<RunOut>>>,
        seen: RefCell<Vec<Vec<String>>>,
    }
    impl Fake {
        fn new(replies: Vec<std::io::Result<RunOut>>) -> Fake {
            Fake {
                replies: RefCell::new(replies),
                seen: RefCell::new(Vec::new()),
            }
        }
    }
    impl Winget for Fake {
        fn run(&self, args: &[String], _t: Duration) -> std::io::Result<RunOut> {
            self.seen.borrow_mut().push(args.to_vec());
            self.replies.borrow_mut().remove(0)
        }
    }

    fn out(code: i32, text: &str) -> std::io::Result<RunOut> {
        Ok(RunOut {
            code: Some(code),
            text: text.into(),
        })
    }

    #[test]
    fn args_are_exactly_the_documented_ones() {
        assert_eq!(
            install_args("Google.Chrome", false),
            [
                "install",
                "--id",
                "Google.Chrome",
                "-e",
                "--silent",
                "--accept-package-agreements",
                "--accept-source-agreements",
                "--disable-interactivity",
                "--source",
                "winget"
            ]
        );
        let u = install_args("Mozilla.Firefox", true);
        assert_eq!(&u[u.len() - 2..], ["--scope", "user"]);
    }

    #[test]
    fn exit_codes_are_tabulated_from_the_official_table() {
        // Valeurs en décimal signé, telles que le processus les renvoie.
        assert_eq!(classify_exit(0).status, Status::Ok);
        assert_eq!(classify_exit(-1978335135).status, Status::Already); // 0x8A150061
        assert_eq!(classify_exit(-1978335189).status, Status::Already); // 0x8A15002B
        assert_eq!(classify_exit(-1978334963).status, Status::Already); // 0x8A15010D
        assert_eq!(classify_exit(-1978334962).status, Status::Already); // 0x8A15010E
        let reboot = classify_exit(-1978334967); // 0x8A150109
        assert_eq!(reboot.status, Status::Ok);
        assert!(reboot.detail.contains("redémarrage"));
        assert_eq!(classify_exit(3010).status, Status::Ok);
        assert_eq!(classify_exit(1641).status, Status::Ok);
        for failing in [
            -1978335216, // NO_APPLICABLE_INSTALLER
            -1978335215, // INSTALLER_HASH_MISMATCH
            -1978335209, // NO_MANIFEST_FOUND
            -1978334971, // INSTALL_DISK_FULL
            1603,        // erreur fatale MSI
            -1,
        ] {
            assert_eq!(classify_exit(failing).status, Status::Failed, "{failing}");
        }
        let unknown = classify_exit(-1978335231);
        assert!(unknown.detail.contains("0x8A150001"), "{}", unknown.detail);
    }

    #[test]
    fn result_line_has_three_tab_separated_fields_and_no_tab_in_detail() {
        let r = PackageResult {
            key: "chrome".into(),
            status: Status::Failed,
            detail: "a\tb\nc".into(),
        };
        let l = r.line();
        assert_eq!(l, "echec\tchrome\ta b c");
        assert_eq!(l.matches('\t').count(), 2);
    }

    #[test]
    fn summarize_keeps_the_last_meaningful_lines_and_drops_progress() {
        let raw = "Found Google Chrome [Google.Chrome] Version 130\r\n\
                   Downloading https://dl.google.com/x.exe\r\n\
                   \u{2588}\u{2588}\u{2588}\u{2588}\u{2592}\u{2592}  1.20 MB / 4.00 MB\r\n\
                   - \r\n\
                   \\ \r\n\
                   100%\r\n\
                   Successfully verified installer hash\r\n\
                   Starting package install...\r\n\
                   Installer failed with exit code: 1603\r\n";
        assert_eq!(
            summarize_output(raw),
            "Starting package install... / Installer failed with exit code: 1603"
        );
        assert_eq!(summarize_output("\r\n  \r\n"), "");
        let long = "x".repeat(500);
        let s = summarize_output(&long);
        assert!(s.chars().count() <= 201 && s.ends_with('…'));
    }

    #[test]
    fn summarize_strips_bidi_and_zero_width_characters_from_the_detail() {
        // Le détail d'un échec est AFFICHÉ au technicien : aucune marque de sens d'écriture, aucune largeur nulle n'y survit.
        for c in invisibles() {
            let raw = format!("Installer failed\r\ngpj{c}.exe a \u{202E}echoue\n");
            assert_eq!(
                summarize_output(&raw),
                "Installer failed / gpj.exe a echoue",
                "U+{:04X} doit être retiré",
                c as u32
            );
        }
        // Le texte ordinaire n'est pas touché (accents, CJK).
        assert_eq!(
            summarize_output("Échec de l’installation 日本\n"),
            "Échec de l’installation 日本"
        );
    }

    #[test]
    fn install_one_maps_success_already_and_failure() {
        let w = Fake::new(vec![
            out(0, "Successfully installed"),
            out(-1978335135, "Found an existing package already installed."),
            out(
                1603,
                "Starting package install...\nInstaller failed with exit code: 1603",
            ),
        ]);
        let a = app("chrome", "Google.Chrome");
        assert_eq!(install_one(&w, &a, false).status, Status::Ok);
        let d = install_one(&w, &a, false);
        assert_eq!(d.status, Status::Already);
        assert_eq!(d.detail, "déjà installé");
        let f = install_one(&w, &a, false);
        assert_eq!(f.status, Status::Failed);
        assert!(f.detail.contains("1603"), "{}", f.detail);
        assert_eq!(w.seen.borrow().len(), 3);
        assert_eq!(w.seen.borrow()[0][2], "Google.Chrome");
    }

    #[test]
    fn user_mode_adds_scope_and_explains_machine_only_packages() {
        let w = Fake::new(vec![out(-1978335216, "No applicable installer found")]);
        let r = install_one(&w, &app("vcredist", "Microsoft.VCRedist.2015+.x64"), true);
        assert_eq!(r.status, Status::Failed);
        assert!(r.detail.contains("administrateur"), "{}", r.detail);
        let args = &w.seen.borrow()[0];
        assert_eq!(&args[args.len() - 2..], ["--scope", "user"]);
    }

    #[test]
    fn timeout_and_spawn_errors_are_failures_not_panics() {
        let w = Fake::new(vec![
            Ok(RunOut {
                code: None,
                text: String::new(),
            }),
            Err(std::io::Error::new(
                std::io::ErrorKind::NotFound,
                "introuvable",
            )),
        ]);
        let a = app("vlc", "VideoLAN.VLC");
        let t = install_one(&w, &a, false);
        assert_eq!(t.status, Status::Failed);
        assert!(t.detail.contains("minutes"));
        let e = install_one(&w, &a, false);
        assert_eq!(e.status, Status::Failed);
        assert!(e.detail.contains("introuvable"));
    }

    // ── Flux ligne à ligne ───────────────────────────────────────────────────────────────

    fn lignes(d: &mut Decoupeur, morceaux: &[&[u8]], fin: bool) -> Vec<String> {
        let mut v = Vec::new();
        for m in morceaux {
            d.pousse(m, &mut |l| v.push(l.to_string()));
        }
        if fin {
            d.fin(&mut |l| v.push(l.to_string()));
        }
        v
    }

    /// Les caractères de format invisibles qui trompent un affichage : les deux bornes de chaque plage de la liste PARTAGÉE
    /// (`baluchon-texte`), jamais une liste recopiée ici. Que la liste gagne une plage, et ces épreuves la jouent aussi.
    fn invisibles() -> Vec<char> {
        baluchon_texte::PLAGES
            .iter()
            .flat_map(|p| [p.debut, p.fin])
            .collect()
    }

    #[test]
    fn decoupeur_strips_bidi_and_zero_width_characters() {
        // U+202E devant `gpj.exe` ferait lire `exe.jpg` ; chacun des caractères de la liste disparaît, le reste est intact.
        for c in invisibles() {
            let mut d = Decoupeur::new(LIGNE_MAX);
            let brut = format!("gpj{c}.exe\n");
            let v = lignes(&mut d, &[brut.as_bytes()], true);
            assert_eq!(v, ["gpj.exe"], "U+{:04X} doit être retiré", c as u32);
        }
        // Une ligne qui n'est QUE de l'invisible n'est jamais rendue (comme une ligne vide).
        let mut d = Decoupeur::new(LIGNE_MAX);
        let seul = format!("{}{}\u{202E}\n", '\u{200B}', '\u{FEFF}');
        assert!(lignes(&mut d, &[seul.as_bytes()], true).is_empty());
    }

    #[test]
    fn decoupeur_strips_an_invisible_character_split_between_two_reads() {
        // U+202E = E2 80 AE, coupé entre deux lectures du tuyau : reconstitué PUIS retiré.
        let mut d = Decoupeur::new(LIGNE_MAX);
        let v = lignes(&mut d, &[b"un\xe2\x80", b"\xaenom\n"], true);
        assert_eq!(v, ["unnom"]);
    }

    #[test]
    fn decoupeur_keeps_ordinary_text_beyond_ascii() {
        // Le nettoyage ne touche que les caractères de format : accents, cyrillique, CJK, emoji et le U+2019 typographique passent.
        let mut d = Decoupeur::new(LIGNE_MAX);
        let v = lignes(&mut d, &[b"Gestionnaire d\xe2\x80\x99\xc3\xa9tat \xd0\x9f\xd1\x80\xd0\xb8\xd0\xb2\xd0\xb5\xd1\x82 \xe6\x97\xa5\xe6\x9c\xac \xf0\x9f\x93\xa6\n"], true);
        assert_eq!(v, ["Gestionnaire d’état Привет 日本 📦"]);
    }

    #[test]
    fn decoupeur_cuts_on_lf_cr_and_crlf_and_never_renders_an_empty_line() {
        let mut d = Decoupeur::new(LIGNE_MAX);
        // winget redessine sa barre par `\r` seul ; Windows termine ses lignes par `\r\n`.
        let v = lignes(
            &mut d,
            &[
                b"Trouv\xc3\xa9\r\n",
                b"  10%\r  20%\r  30%\n\n\r\n",
                b"fini\n",
            ],
            true,
        );
        assert_eq!(v, ["Trouvé", "10%", "20%", "30%", "fini"]);
    }

    #[test]
    fn decoupeur_rebuilds_a_character_split_between_two_reads() {
        let mut d = Decoupeur::new(LIGNE_MAX);
        // « é » = C3 A9, coupé entre deux lectures du tuyau.
        let v = lignes(&mut d, &[b"caf\xc3", b"\xa9 pr\xc3\xaat\n"], true);
        assert_eq!(v, ["café prêt"]);
    }

    #[test]
    fn decoupeur_flushes_the_last_line_without_a_separator_and_only_at_the_end() {
        let mut d = Decoupeur::new(LIGNE_MAX);
        assert!(lignes(&mut d, &[b"sans fin de ligne"], false).is_empty());
        let mut v = Vec::new();
        d.fin(&mut |l| v.push(l.to_string()));
        assert_eq!(v, ["sans fin de ligne"]);
        // Une seconde fin ne rend rien : la ligne est déjà partie.
        let mut encore = Vec::new();
        d.fin(&mut |l| encore.push(l.to_string()));
        assert!(encore.is_empty());
    }

    #[test]
    fn decoupeur_bounds_a_giant_line_and_still_renders_the_next_one() {
        let mut d = Decoupeur::new(LIGNE_MAX);
        let geante = vec![b'x'; 4 * 1024 * 1024];
        let mut v = Vec::new();
        for morceau in geante.chunks(16 * 1024) {
            d.pousse(morceau, &mut |l| v.push(l.to_string()));
            // La mémoire retenue ne dépasse jamais la borne, quelle que soit la sortie.
            assert!(d.ligne.len() <= LIGNE_MAX);
        }
        d.pousse(b"\nensuite\n", &mut |l| v.push(l.to_string()));
        assert_eq!(v.len(), 2, "{} lignes", v.len());
        assert_eq!(v[0].len(), LIGNE_MAX);
        assert_eq!(v[1], "ensuite");
    }

    #[test]
    fn decoupeur_does_not_leave_a_replacement_character_after_cutting_a_multibyte_one() {
        let mut d = Decoupeur::new(5);
        // « abcdé » : le « é » (2 octets) commence à l'octet 4 et la borne le coupe en deux.
        let v = lignes(&mut d, &[b"abcd\xc3\xa9 suite\n"], true);
        assert_eq!(v, ["abcd"]);
        assert!(!v[0].contains('\u{FFFD}'));
    }

    #[test]
    fn decoupeur_strips_control_characters_and_turns_tabs_into_spaces() {
        let mut d = Decoupeur::new(LIGNE_MAX);
        let v = lignes(&mut d, &[b"a\tb\x1b[0m\x07c\n"], true);
        // La séquence d'échappement perd son caractère de commande ; elle n'a plus d'effet.
        assert_eq!(v, ["a b[0mc"]);
        assert!(!v[0].contains('\t'));
    }

    /// Exécuteur qui diffuse VRAIMENT : une ligne à la fois, en regardant `annule` entre deux.
    struct Direct {
        lignes: Vec<String>,
        fin: Fin,
        emises: RefCell<usize>,
    }
    impl Direct {
        fn new(lignes: &[&str], fin: Fin) -> Direct {
            Direct {
                lignes: lignes.iter().map(|l| l.to_string()).collect(),
                fin,
                emises: RefCell::new(0),
            }
        }
    }
    impl Winget for Direct {
        fn run(&self, _a: &[String], _t: Duration) -> std::io::Result<RunOut> {
            panic!("le chemin en continu ne doit pas passer par `run`");
        }
        fn run_flux(
            &self,
            _a: &[String],
            _t: Duration,
            sortie: &mut dyn Sortie,
        ) -> std::io::Result<Fin> {
            for l in &self.lignes {
                if sortie.annule() {
                    return Ok(Fin::Annulee);
                }
                sortie.ligne(l);
                *self.emises.borrow_mut() += 1;
            }
            Ok(self.fin)
        }
    }

    /// Sortie d'essai : garde les lignes, demande l'annulation après `annule_apres` lignes.
    struct Garde {
        vues: Vec<String>,
        annule_apres: Option<usize>,
    }
    impl Garde {
        fn new(annule_apres: Option<usize>) -> Garde {
            Garde {
                vues: Vec::new(),
                annule_apres,
            }
        }
    }
    impl Sortie for Garde {
        fn ligne(&mut self, l: &str) {
            self.vues.push(l.to_string());
        }
        fn annule(&self) -> bool {
            self.annule_apres.is_some_and(|n| self.vues.len() >= n)
        }
    }

    #[test]
    fn flux_gives_the_same_verdict_as_the_blocking_install_for_every_outcome() {
        let a = app("chrome", "Google.Chrome");
        // (code de sortie, texte) : succès, déjà installé, redémarrage, hash invalide, MSI fatal,
        // code inconnu, et le cas « machine seulement » en mode utilisateur.
        let cas: [(i32, &str); 8] = [
            (0, "Successfully installed"),
            (-1978335135, "déjà installé"),
            (-1978334967, "redémarrage"),
            (-1978335215, "hash mismatch"),
            (
                1603,
                "Starting package install...\nInstaller failed with exit code: 1603",
            ),
            (-1978335231, ""),
            (-1978335216, "No applicable installer found"),
            (3010, "ok"),
        ];
        for user_scope in [false, true] {
            for (code, texte) in cas {
                let bloquant = Fake::new(vec![out(code, texte)]);
                let attendu = install_one(&bloquant, &a, user_scope);
                // Défaut du trait : `run` puis rejeu des lignes.
                let rejoue = Fake::new(vec![out(code, texte)]);
                let mut s = Garde::new(None);
                assert_eq!(
                    install_one_flux(&rejoue, &a, user_scope, &mut s),
                    attendu,
                    "code {code} portée utilisateur {user_scope}"
                );
                // Exécuteur qui diffuse vraiment les mêmes lignes : même verdict, phrase comprise.
                let lignes: Vec<&str> = texte.lines().collect();
                let direct = Direct::new(&lignes, Fin::Code(code));
                let mut s2 = Garde::new(None);
                let vu = install_one_flux(&direct, &a, user_scope, &mut s2);
                assert_eq!(vu, attendu, "diffusé, code {code}");
            }
        }
    }

    #[test]
    fn flux_default_replays_the_text_line_by_line_including_progress_lines() {
        let w = Fake::new(vec![out(
            0,
            "Téléchargement\r  10%\r  55%\r\nInstallation\r\nTerminé",
        )]);
        let mut s = Garde::new(None);
        let r = install_one_flux(&w, &app("vlc", "VideoLAN.VLC"), false, &mut s);
        assert_eq!(r.status, Status::Ok);
        // La progression est rendue à l'appelant (c'est lui qui la lit)…
        assert_eq!(
            s.vues,
            ["Téléchargement", "10%", "55%", "Installation", "Terminé"]
        );
        // … et les arguments sont ceux de `install_one`, rien de plus.
        assert_eq!(w.seen.borrow()[0], install_args("VideoLAN.VLC", false));
    }

    #[test]
    fn flux_stops_and_says_so_when_the_sortie_asks_to_cancel() {
        let w = Direct::new(&["un", "deux", "trois", "quatre"], Fin::Code(0));
        let mut s = Garde::new(Some(2));
        let r = install_one_flux(&w, &app("vlc", "VideoLAN.VLC"), false, &mut s);
        assert_eq!(r.status, Status::Failed);
        assert!(r.detail.contains("interrompue"), "{}", r.detail);
        // L'exécuteur a regardé `annule` entre deux lignes : il n'a rien émis après la demande.
        assert_eq!(s.vues, ["un", "deux"]);
        assert_eq!(*w.emises.borrow(), 2);
    }

    #[test]
    fn flux_cancelled_before_the_start_never_launches_winget() {
        let w = Fake::new(vec![]);
        let mut s = Garde::new(Some(0));
        let r = install_one_flux(&w, &app("vlc", "VideoLAN.VLC"), false, &mut s);
        assert_eq!(r.status, Status::Failed);
        assert!(r.detail.contains("interrompue"), "{}", r.detail);
        assert!(
            w.seen.borrow().is_empty(),
            "winget ne devait pas être lancé"
        );
    }

    #[test]
    fn flux_timeout_and_spawn_errors_are_failures_not_panics() {
        let a = app("vlc", "VideoLAN.VLC");
        let t = install_one_flux(
            &Direct::new(&["début"], Fin::Delai),
            &a,
            false,
            &mut Garde::new(None),
        );
        assert_eq!(t.status, Status::Failed);
        assert!(t.detail.contains("minutes"), "{}", t.detail);
        let e = install_one_flux(
            &Fake::new(vec![Err(std::io::Error::new(
                std::io::ErrorKind::NotFound,
                "introuvable",
            ))]),
            &a,
            false,
            &mut Garde::new(None),
        );
        assert_eq!(e.status, Status::Failed);
        assert!(e.detail.contains("introuvable"), "{}", e.detail);
    }

    #[test]
    fn flux_failure_detail_keeps_the_last_useful_lines_and_drops_progress() {
        let mut texte = String::from("Trouvé VLC\nTéléchargement\n");
        for p in 0..200 {
            texte.push_str(&format!("  {p}%\r"));
        }
        texte.push_str("Démarrage de l'installation\nInstallateur en échec : 1603\n");
        for _ in 0..50 {
            texte.push_str("  100%\r- \r");
        }
        let w = Fake::new(vec![out(1603, &texte)]);
        let r = install_one_flux(
            &w,
            &app("vlc", "VideoLAN.VLC"),
            false,
            &mut Garde::new(None),
        );
        assert_eq!(r.status, Status::Failed);
        assert!(
            r.detail
                .ends_with("Démarrage de l'installation / Installateur en échec : 1603"),
            "{}",
            r.detail
        );
    }
}
