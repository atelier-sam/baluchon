//! « Ce jeton d'accès est-il expiré ? » : une LECTURE de la date `expiresAt`.
//!
//! Vit dans le noyau public parce que c'est ce qui fait afficher « jeton expiré » à
//! n'importe quelle édition. Le renouvellement lui-même (qui réagit à cette réponse)
//! n'est PAS ici : il est de l'autre côté de la couture `Extension`.

use crate::creds::CredBlob;

/// Marge avant l'expiration réelle : on renouvelle un peu avant.
pub const EXPIRY_MARGIN_MS: i64 = 60_000;

pub fn expired(blob: &CredBlob, now_ms: i64) -> bool {
    blob.expires_at_ms()
        .is_some_and(|e| e <= now_ms + EXPIRY_MARGIN_MS)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expiry_margin() {
        let b =
            CredBlob::parse(r#"{"claudeAiOauth":{"accessToken":"a","expiresAt":100000}}"#).unwrap();
        assert!(expired(&b, 100_000));
        assert!(expired(&b, 40_001));
        assert!(!expired(&b, 39_000));
    }
}
