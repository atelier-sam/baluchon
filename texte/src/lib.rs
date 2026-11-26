//! baluchon-texte : rendre sûr à AFFICHER un texte écrit par quelqu'un d'autre.
//!
//! Un nom de processus, de fichier ou de périphérique, la sortie d'un outil, un message saisi
//! ailleurs : tout cela finit montré à une personne, qui s'y fie. Or `char::is_control` ne retient
//! que les caractères de COMMANDE ; les caractères de FORMAT, invisibles, passent. Une marque de
//! sens d'écriture (U+202E « droite à gauche ») retourne tout ce qui suit : `gpj.exe` précédé d'un
//! U+202E s'affiche `exe.jpg`. Une largeur nulle (U+200B…) cache une partie du texte ou fabrique
//! deux noms qui se ressemblent à s'y méprendre.
//!
//! La crate porte donc UNE liste ([`PLAGES`]), ses deux usages (le prédicat STRICT
//! [`invisible_trompeur`] pour les noms et les libellés, [`trompeur_dans_un_message`] pour le texte
//! libre, qui garde l'emoji et le persan) et l'assainissement d'une ligne ([`assainir`]). Les deux
//! prédicats lisent la MÊME table : la différence est une propriété de la famille de chaque plage,
//! pas une seconde liste. WHY une crate et non une
//! copie par programme : la liste vivait en cinq exemplaires, dont deux sous-ensembles (le sens
//! d'écriture seul, ou sans largeur nulle). Un texte propre à un endroit ne l'était plus à
//! l'autre, et un caractère ajouté d'un côté n'arrivait jamais de l'autre.
//!
//! AUCUNE dépendance : la crate se lie partout, jusque dans un programme compilé pour le
//! navigateur.

#![forbid(unsafe_code)]

use std::borrow::Cow;

/// Pourquoi un caractère est dit « invisible trompeur » : ce qu'il fait au texte qui l'entoure.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Famille {
    /// Marques de sens d'écriture : ALM, LRM, RLM, LRE, RLE, PDF, LRO, RLO, LRI, RLI, FSI, PDI.
    /// Elles retournent le texte qui suit.
    SensEcriture,
    /// Largeur nulle : ZWSP, WJ, BOM, trait d'union conditionnel (invisible hors coupure de
    /// ligne). Elles cachent une partie du texte ou le dédoublent.
    LargeurNulle,
    /// Liants de largeur nulle : ZWNJ (U+200C) et ZWJ (U+200D). Invisibles, mais ils portent du
    /// sens : le ZWNJ est indispensable à l'écriture du persan, le ZWJ à la composition des emoji
    /// (👨‍👩‍👧). Trompeurs dans un nom, légitimes dans un message.
    Liant,
    /// Sélecteurs de variation (et leurs équivalents mongols, hangul…) autres que les deux de la
    /// famille [`Famille::Presentation`] : ils ne changent que la forme du caractère précédent,
    /// et leur grand nombre sert à cacher des octets entiers derrière un caractère.
    Selecteur,
    /// Les DEUX sélecteurs de présentation, U+FE0E (texte) et U+FE0F (emoji) : « ❤️ » et « ✔️ »
    /// en dépendent. Trompeurs dans un nom, légitimes dans un message.
    Presentation,
    /// Caractères de balise (U+E0000 à U+E007F) : de l'ASCII invisible, sans usage dans un texte
    /// qu'on affiche.
    Balise,
}

impl Famille {
    /// Nom stable, ASCII : celui qu'écrivent les vecteurs partagés et les journaux.
    pub const fn nom(self) -> &'static str {
        match self {
            Famille::SensEcriture => "sens-ecriture",
            Famille::LargeurNulle => "largeur-nulle",
            Famille::Liant => "liant",
            Famille::Selecteur => "selecteur",
            Famille::Presentation => "presentation",
            Famille::Balise => "balise",
        }
    }

    /// Cette famille survit-elle dans un MESSAGE (texte libre qu'une personne écrit à une autre) ?
    /// Oui pour [`Famille::Liant`] et [`Famille::Presentation`], non pour toutes les autres. C'est
    /// une propriété de la table et non une seconde liste : une plage ajoutée à `PLAGES` est
    /// jugée, pour les noms comme pour les messages, par la famille qu'on lui donne.
    pub const fn survit_dans_un_message(self) -> bool {
        matches!(self, Famille::Liant | Famille::Presentation)
    }
}

/// Une plage de caractères, bornes COMPRISES, d'une même famille.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Plage {
    /// Premier caractère de la plage.
    pub debut: char,
    /// Dernier caractère de la plage (le même que `debut` pour un caractère seul).
    pub fin: char,
    /// Ce que ces caractères font au texte.
    pub famille: Famille,
}

const fn plage(debut: char, fin: char, famille: Famille) -> Plage {
    Plage {
        debut,
        fin,
        famille,
    }
}

/// LA liste. Triée, sans chevauchement, bornes comprises : un test le vérifie, et un autre la
/// compare, caractère par caractère sur tout Unicode, à l'ensemble des anciennes copies.
///
/// Un caractère ajouté ici est retiré partout à la fois ; c'est tout le but. Les programmes qui
/// gardent un jumeau dans un autre langage le comparent à un vecteur tiré de cette table.
pub const PLAGES: &[Plage] = &[
    plage('\u{00AD}', '\u{00AD}', Famille::LargeurNulle),
    plage('\u{061C}', '\u{061C}', Famille::SensEcriture),
    plage('\u{200B}', '\u{200B}', Famille::LargeurNulle),
    plage('\u{200C}', '\u{200D}', Famille::Liant),
    plage('\u{200E}', '\u{200F}', Famille::SensEcriture),
    plage('\u{202A}', '\u{202E}', Famille::SensEcriture),
    plage('\u{2060}', '\u{2060}', Famille::LargeurNulle),
    plage('\u{2066}', '\u{2069}', Famille::SensEcriture),
    plage('\u{FE00}', '\u{FE0D}', Famille::Selecteur),
    plage('\u{FE0E}', '\u{FE0F}', Famille::Presentation),
    plage('\u{FEFF}', '\u{FEFF}', Famille::LargeurNulle),
    plage('\u{E0000}', '\u{E007F}', Famille::Balise),
];

/// La famille de `c` s'il est un invisible trompeur, `None` sinon.
pub fn famille_de(c: char) -> Option<Famille> {
    // Chemin chaud : tout le texte courant (ASCII, Latin-1) est sous la première plage.
    if c < '\u{00AD}' {
        return None;
    }
    PLAGES
        .iter()
        .find(|p| (p.debut..=p.fin).contains(&c))
        .map(|p| p.famille)
}

/// `c` est-il un caractère de format invisible qui peut tromper la lecture d'un texte affiché ?
pub fn invisible_trompeur(c: char) -> bool {
    famille_de(c).is_some()
}

/// `c` est-il trompeur dans un MESSAGE (texte libre) ? C'est [`invisible_trompeur`] SAUF pour les
/// familles [`Famille::Liant`] et [`Famille::Presentation`] (voir
/// [`Famille::survit_dans_un_message`]) : ZWNJ, ZWJ, U+FE0E et U+FE0F, et ces QUATRE seulement.
///
/// WHY quatre caractères et non « tous les sélecteurs » : ils gardent l'emoji (« ❤️ », « 👨‍👩‍👧 »,
/// « 🏳️‍🌈 ») et le persan, mais sans laisser de canal caché exploitable. Les 256 sélecteurs de
/// variation (U+FE00 à U+FE0F, U+E0100 à U+E01EF) servent à cacher des octets entiers derrière un
/// caractère visible, et les balises (U+E0000 à U+E007F) se lisent comme de l'ASCII par un modèle
/// de langage : un texte qui arrive devant un modèle ne doit pas lui être lisible là où il est
/// invisible pour la personne qui le lit.
pub fn trompeur_dans_un_message(c: char) -> bool {
    famille_de(c).is_some_and(|f| !f.survit_dans_un_message())
}

/// Retire de `s` les caractères que `trompeur` désigne. Rend `s` lui-même, sans copie, quand il
/// n'en porte aucun.
fn retirer(s: &str, trompeur: fn(char) -> bool) -> Cow<'_, str> {
    if !s.chars().any(trompeur) {
        return Cow::Borrowed(s);
    }
    Cow::Owned(s.chars().filter(|c| !trompeur(*c)).collect())
}

/// `s` sans aucun invisible trompeur (le prédicat STRICT : noms, libellés, lignes d'un outil).
/// Rend `s` lui-même, sans copie, quand il n'en porte pas.
pub fn sans_invisibles(s: &str) -> Cow<'_, str> {
    retirer(s, invisible_trompeur)
}

/// `s` sans aucun caractère [trompeur dans un message](trompeur_dans_un_message) : l'emoji et le
/// persan survivent. Rend `s` lui-même, sans copie, quand il n'en porte pas.
pub fn sans_invisibles_de_message(s: &str) -> Cow<'_, str> {
    retirer(s, trompeur_dans_un_message)
}

/// Coupe `s` à `max` octets au plus, sur une frontière de caractère.
pub fn tronquer(s: &str, max: usize) -> &str {
    if s.len() <= max {
        return s;
    }
    let mut n = max;
    while !s.is_char_boundary(n) {
        n -= 1;
    }
    &s[..n]
}

/// Une ligne de texte sûre à afficher : sans invisible trompeur, sans caractère de contrôle, les
/// blancs (séparateurs de ligne Unicode compris) réduits à une espace, coupée à `max` octets (avec
/// « … » quand elle est coupée).
///
/// Un texte qui ne contient plus rien d'affichable donne une chaîne vide : l'appelant décide de ce
/// qu'il met à la place (jamais un nom « deviné »).
pub fn assainir(brut: &str, max: usize) -> String {
    let mut propre = String::with_capacity(brut.len().min(max + 4));
    let mut espace_en_attente = false;
    for c in brut.chars() {
        if invisible_trompeur(c) {
            continue;
        }
        if c.is_control() || c.is_whitespace() {
            espace_en_attente = !propre.is_empty();
            continue;
        }
        if espace_en_attente {
            propre.push(' ');
            espace_en_attente = false;
        }
        propre.push(c);
        // Inutile de lire plus loin que ce qu'on peut garder : un nom d'un mégaoctet reste borné
        // en temps.
        if propre.len() > max + 8 {
            break;
        }
    }
    if propre.len() <= max {
        return propre;
    }
    // Le « … » prend trois octets.
    let coupe = tronquer(&propre, max.saturating_sub(3))
        .trim_end()
        .to_string();
    format!("{coupe}…")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Une attaque réaliste par famille : le caractère, sa famille, un texte qui le porte et ce
    /// qu'il doit devenir. C'est le contrôle POSITIF : la liste a retiré quelque chose, et pour la
    /// bonne raison.
    const ATTAQUES: &[(char, Famille, &str, &str)] = &[
        (
            '\u{061C}',
            Famille::SensEcriture,
            "doc\u{061C}.exe",
            "doc.exe",
        ),
        (
            '\u{200E}',
            Famille::SensEcriture,
            "doc\u{200E}.exe",
            "doc.exe",
        ),
        (
            '\u{200F}',
            Famille::SensEcriture,
            "doc\u{200F}.exe",
            "doc.exe",
        ),
        (
            '\u{202E}',
            Famille::SensEcriture,
            "facture\u{202E}fdp.exe",
            "facturefdp.exe",
        ),
        (
            '\u{2066}',
            Famille::SensEcriture,
            "\u{2066}a\u{2069}b",
            "ab",
        ),
        (
            '\u{200B}',
            Famille::LargeurNulle,
            "sv\u{200B}chost.exe",
            "svchost.exe",
        ),
        (
            '\u{200C}',
            Famille::Liant,
            "sv\u{200C}chost.exe",
            "svchost.exe",
        ),
        (
            '\u{200D}',
            Famille::Liant,
            "sv\u{200D}chost.exe",
            "svchost.exe",
        ),
        (
            '\u{2060}',
            Famille::LargeurNulle,
            "sv\u{2060}chost.exe",
            "svchost.exe",
        ),
        (
            '\u{FEFF}',
            Famille::LargeurNulle,
            "\u{FEFF}svchost.exe",
            "svchost.exe",
        ),
        (
            '\u{00AD}',
            Famille::LargeurNulle,
            "s\u{00AD}vchost.exe",
            "svchost.exe",
        ),
        ('\u{FE00}', Famille::Selecteur, "a\u{FE00}b", "ab"),
        ('\u{FE0E}', Famille::Presentation, "a\u{FE0E}b", "ab"),
        ('\u{FE0F}', Famille::Presentation, "a\u{FE0F}b", "ab"),
        ('\u{E0041}', Famille::Balise, "a\u{E0041}b", "ab"),
    ];

    /// L'ensemble des anciennes copies, recopié ICI tel qu'il était dans `baluchon-winget` (et dans
    /// les deux autres exemplaires complets) : l'oracle contre lequel la table est jugée. Il ne
    /// sert qu'à ce test ; la table [`PLAGES`] est la seule liste du code livré.
    fn ancien_ensemble(c: char) -> bool {
        matches!(
            c,
            '\u{061C}'
                | '\u{200E}'
                | '\u{200F}'
                | '\u{202A}'..='\u{202E}'
                | '\u{2066}'..='\u{2069}'
                | '\u{200B}'..='\u{200D}'
                | '\u{2060}'
                | '\u{FEFF}'
                | '\u{00AD}'
                | '\u{FE00}'..='\u{FE0F}'
                | '\u{E0000}'..='\u{E007F}'
        )
    }

    #[test]
    fn la_table_est_exactement_l_ensemble_des_anciennes_copies_sur_tout_unicode() {
        for n in 0..=0x10FFFF_u32 {
            if let Some(c) = char::from_u32(n) {
                assert_eq!(
                    invisible_trompeur(c),
                    ancien_ensemble(c),
                    "U+{n:04X} : la table et l'ancien ensemble divergent"
                );
            }
        }
    }

    #[test]
    fn les_plages_sont_triees_disjointes_et_non_vides() {
        for p in PLAGES {
            assert!(p.debut <= p.fin, "plage vide ou inversée : {p:?}");
        }
        for deux in PLAGES.windows(2) {
            assert!(
                deux[0].fin < deux[1].debut,
                "plages mal triées ou qui se chevauchent : {:?} puis {:?}",
                deux[0],
                deux[1]
            );
        }
    }

    #[test]
    fn chaque_borne_est_prise_et_son_voisin_ne_l_est_que_s_il_est_dans_la_plage_d_a_cote() {
        let voisin = |n: u32| char::from_u32(n).expect("voisin valide");
        for (i, p) in PLAGES.iter().enumerate() {
            for c in [p.debut, p.fin] {
                assert_eq!(famille_de(c), Some(p.famille), "U+{:04X}", c as u32);
            }
            let avant = voisin(p.debut as u32 - 1);
            let colle_avant = i > 0 && PLAGES[i - 1].fin == avant;
            assert_eq!(invisible_trompeur(avant), colle_avant, "avant {p:?}");
            let apres = voisin(p.fin as u32 + 1);
            let colle_apres = PLAGES.get(i + 1).is_some_and(|s| s.debut == apres);
            assert_eq!(invisible_trompeur(apres), colle_apres, "après {p:?}");
        }
    }

    #[test]
    fn chaque_famille_a_sa_plage_et_son_nom() {
        for f in [
            Famille::SensEcriture,
            Famille::LargeurNulle,
            Famille::Liant,
            Famille::Selecteur,
            Famille::Presentation,
            Famille::Balise,
        ] {
            assert!(PLAGES.iter().any(|p| p.famille == f), "{f:?} sans plage");
            assert!(
                ATTAQUES.iter().any(|a| a.1 == f),
                "{f:?} sans contrôle positif"
            );
            assert!(!f.nom().is_empty() && f.nom().is_ascii());
        }
    }

    #[test]
    fn controle_positif_un_caractere_de_chaque_famille_disparait_pour_la_bonne_raison() {
        for &(c, famille, entree, attendu) in ATTAQUES {
            assert!(invisible_trompeur(c), "U+{:04X} doit être pris", c as u32);
            assert_eq!(famille_de(c), Some(famille), "U+{:04X}", c as u32);
            assert!(
                entree.contains(c),
                "le texte d'attaque de U+{:04X} ne le porte pas",
                c as u32
            );
            assert_eq!(sans_invisibles(entree), attendu, "U+{:04X}", c as u32);
            assert_eq!(assainir(entree, 64), attendu, "U+{:04X}", c as u32);
        }
    }

    #[test]
    fn le_texte_ordinaire_passe_intact_et_sans_copie() {
        for s in [
            "svchost.exe",
            "Gestionnaire d’état",
            "Привет 日本 📦",
            "espace\u{00A0}insécable et \u{202F}fine",
            "tab\tet\nligne",
            "",
        ] {
            assert!(
                matches!(sans_invisibles(s), Cow::Borrowed(t) if t == s),
                "{s:?} ne doit pas être copié"
            );
        }
    }

    /// Les QUATRE caractères qu'un message garde : ZWNJ, ZWJ et les deux sélecteurs de présentation.
    const GARDES_DANS_UN_MESSAGE: [char; 4] = ['\u{200C}', '\u{200D}', '\u{FE0E}', '\u{FE0F}'];

    #[test]
    fn un_message_garde_exactement_quatre_caracteres_que_le_predicat_strict_retire() {
        let mut gardes = Vec::new();
        for n in 0..=0x10FFFF_u32 {
            if let Some(c) = char::from_u32(n) {
                // Le prédicat de message n'est jamais PLUS large que le strict.
                assert!(!trompeur_dans_un_message(c) || invisible_trompeur(c));
                if invisible_trompeur(c) && !trompeur_dans_un_message(c) {
                    gardes.push(c);
                }
            }
        }
        assert_eq!(gardes, GARDES_DANS_UN_MESSAGE);
        for c in GARDES_DANS_UN_MESSAGE {
            // Le prédicat strict (noms de fichier, libellés) les retire bien.
            assert!(invisible_trompeur(c), "U+{:04X}", c as u32);
            let nom = format!("sv{c}chost");
            assert_eq!(sans_invisibles(&nom), "svchost", "U+{:04X}", c as u32);
        }
    }

    #[test]
    fn l_emoji_et_le_persan_passent_intacts_dans_un_message() {
        for s in [
            "❤\u{FE0F}",                                   // cœur, présentation emoji
            "✔\u{FE0F} fait",                              // coche, présentation emoji
            "\u{2764}\u{FE0E}",                            // cœur, présentation texte
            "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", // famille (liants)
            "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}",          // drapeau arc-en-ciel (FE0F puis ZWJ)
            // Un mot persan écrit avec un ZWNJ au milieu (« je veux »).
            "\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645}",
        ] {
            assert!(
                matches!(sans_invisibles_de_message(s), Cow::Borrowed(t) if t == s),
                "{s:?} doit passer intact dans un message"
            );
        }
    }

    #[test]
    fn un_message_perd_le_reste_des_invisibles_et_les_canaux_caches() {
        for (c, nom) in [
            ('\u{202E}', "sens d'écriture"),
            ('\u{061C}', "U+061C"),
            ('\u{200B}', "largeur nulle"),
            ('\u{2060}', "mot-lien"),
            ('\u{FEFF}', "BOM"),
            ('\u{00AD}', "trait d'union conditionnel"),
            ('\u{FE00}', "sélecteur de variation"),
            ('\u{E0041}', "balise"),
        ] {
            assert!(trompeur_dans_un_message(c), "{nom} (U+{:04X})", c as u32);
            let brut = format!("sa{c}lut \u{2764}\u{FE0F}");
            assert_eq!(
                sans_invisibles_de_message(&brut),
                "salut \u{2764}\u{FE0F}",
                "{nom} doit disparaître, l'emoji rester"
            );
        }
    }

    #[test]
    fn sans_invisibles_ne_touche_pas_au_reste_du_texte() {
        let brut = "é\u{200B}日\u{202E}本\u{FE0F}📦\u{E0041}!";
        assert_eq!(sans_invisibles(brut), "é日本📦!");
    }

    #[test]
    fn assainir_retire_les_marques_de_sens_d_ecriture() {
        // « document\u{202E}fdp.exe » s'afficherait « documentexe.pdf » : le piège classique.
        assert_eq!(assainir("document\u{202E}fdp.exe", 64), "documentfdp.exe");
        assert_eq!(assainir("\u{2066}a\u{2069}\u{200F}b", 64), "ab");
    }

    #[test]
    fn assainir_retire_largeur_nulle_et_traduit_les_separateurs_unicode() {
        assert_eq!(assainir("sv\u{200B}chost\u{FEFF}.exe", 64), "svchost.exe");
        assert_eq!(assainir("a\u{2028}b\u{2029}c", 64), "a b c");
        assert_eq!(assainir("s\u{00AD}vchost.exe", 64), "svchost.exe");
    }

    #[test]
    fn assainir_reduit_controles_et_blancs_a_une_espace() {
        assert_eq!(assainir("  a\tb\r\n\u{0007}c  ", 64), "a b c");
        assert_eq!(assainir("\u{0000}\u{001F}", 64), "");
        assert_eq!(assainir("", 64), "");
        // Rien d'affichable après nettoyage : vide, jamais un nom deviné.
        assert_eq!(assainir("\u{200B}\u{202E}", 64), "");
    }

    #[test]
    fn assainir_coupe_sur_une_frontiere_de_caractere_avec_points_de_suite() {
        let long = "é".repeat(100); // 200 octets
        let t = assainir(&long, 21);
        assert!(t.len() <= 21, "{} octets", t.len());
        assert!(t.ends_with('…'));
        // Pile à la limite : rien n'est coupé.
        assert_eq!(assainir("abcde", 5), "abcde");
        assert_eq!(assainir("abcdef", 5), "ab…");
    }

    #[test]
    fn assainir_borne_un_texte_enorme_en_temps_et_en_memoire() {
        let enorme = "x".repeat(5_000_000);
        assert!(assainir(&enorme, 100).len() <= 100);
    }

    #[test]
    fn tronquer_ne_coupe_pas_un_caractere() {
        assert_eq!(tronquer("aé", 2), "a");
        assert_eq!(tronquer("aé", 3), "aé");
        assert_eq!(tronquer("abc", 10), "abc");
        assert_eq!(tronquer("é", 0), "");
    }
}
