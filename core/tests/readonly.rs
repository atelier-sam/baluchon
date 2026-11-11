//! Le test « aucun POST, magasin identique » du noyau PUBLIC.
//!
//! Écrit au lot 1, volontairement ROUGE contre le binaire d'alors (qui renouvelait) : la
//! preuve qu'il mord. Activé au lot 3, quand le binaire public ne branche plus que
//! `ReadOnly` : il passe sans autre changement.
//!
//! CONTRÔLE POSITIF (un essai qui ne peut pas échouer ne prouve rien) :
//! `BALUCHON_READONLY_BIN=<chemin d'un binaire qui renouvelle> cargo test --test readonly`
//! vise cet autre binaire, et les deux essais doivent alors être ROUGES. Sans la
//! variable, le binaire visé est celui de ce paquet, le PUBLIC : ils sont verts.
//!
//! Le binaire est lancé contre un faux serveur local, dans un HOME jetable, avec des
//! jetons factices. Le vrai `claude` n'est jamais lancé, aucune requête ne sort de la machine.

use baluchon_testkit::{creds_json, Fake, Hit, Sandbox};

const BIN: &str = env!("CARGO_BIN_EXE_baluchon-core");

/// Binaire visé : celui du paquet, ou celui que désigne `BALUCHON_READONLY_BIN`
/// (contrôle positif). `Box::leak` : le banc veut un `&'static str`, et un essai est un
/// processus court.
fn bin() -> &'static str {
    match std::env::var("BALUCHON_READONLY_BIN") {
        Ok(p) if !p.is_empty() => Box::leak(p.into_boxed_str()),
        _ => BIN,
    }
}

fn store_bytes(sb: &Sandbox) -> Vec<u8> {
    std::fs::read(sb.profile_dir("1").join(".credentials.json")).unwrap()
}

#[test]
fn an_expired_login_is_never_renewed_by_the_public_binary() {
    let sb = Sandbox::new(bin());
    sb.put_file_login("1", &creds_json("AT-faux", "RT-faux", 1_000, 0));
    let before = store_bytes(&sb);
    let fake = Fake::start(baluchon_testkit::healthy);

    let o = sb.run(Some(&fake), &["accounts", "status", "--format", "json"]);

    assert!(
        o.status.success(),
        "status a échoué : {}",
        String::from_utf8_lossy(&o.stderr)
    );
    assert_eq!(
        fake.token_hits(),
        0,
        "aucun POST vers le point de renouvellement"
    );
    assert_eq!(store_bytes(&sb), before, "magasin identique à l'octet");
    assert!(!sb.journal("1").exists(), "aucun journal de renouvellement");
}

#[test]
fn a_401_is_never_answered_by_a_renewal_in_the_public_binary() {
    let sb = Sandbox::new(bin());
    let in_an_hour = baluchon_testkit::now_ms() + 3_600_000;
    sb.put_file_login("1", &creds_json("AT-faux", "RT-faux", in_an_hour, 0));
    let before = store_bytes(&sb);
    // Le serveur refuse le jeton d'accès (401) et accepterait un renouvellement.
    let fake = Fake::start(|h: &Hit, rank| match (h.method.as_str(), h.path.as_str()) {
        ("GET", "/api/oauth/profile") | ("GET", "/api/oauth/usage") => (401, "{}".into()),
        _ => baluchon_testkit::healthy(h, rank),
    });

    let o = sb.run(Some(&fake), &["accounts", "status", "--format", "json"]);

    assert!(
        o.status.success(),
        "status a échoué : {}",
        String::from_utf8_lossy(&o.stderr)
    );
    assert_eq!(
        fake.token_hits(),
        0,
        "aucun POST vers le point de renouvellement"
    );
    assert_eq!(
        fake.count("GET", "/api/oauth/profile"),
        1,
        "une seule requête refusée, pas de nouvel essai"
    );
    assert_eq!(store_bytes(&sb), before, "magasin identique à l'octet");
}
