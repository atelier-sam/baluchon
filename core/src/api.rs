//! API Anthropic : profil et usage, en LECTURE seule. Classification PURE des
//! réponses (testée sur des réponses figées) séparée du transport. Le client de
//! renouvellement n'est pas ici : il vit dans la couche privée.
//!
//! Règles apprises à la dure (cf. ai-cluster `anthropicOauthUsage.ts`) :
//! - 429 sur `/api/oauth/usage` = limite PAR IP du point de statut, jamais un
//!   épuisement du compte : on garde la dernière bonne valeur.
//! - un 200 qui n'est pas du JSON attendu (portail captif) = hors ligne ;
//! - un 200 JSON sans champ connu = erreur de FORMAT, jamais « 0 % ».

use crate::http::{Http, HttpRequest, Method};
use crate::model::Bucket;
use secrecy::SecretString;
use serde_json::Value;
use std::sync::Arc;
use std::time::Duration;

pub const BETA: &str = "oauth-2025-04-20";
pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(2);
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(4);

#[derive(Debug, PartialEq)]
pub enum Fetch<T> {
    Ok(T),
    Unauthorized,
    Forbidden,
    RateLimited,
    /// Réseau coupé, délai, ou réponse qui n'est pas celle de l'API (portail captif).
    Unreachable(String),
    /// 200 mais JSON sans aucun champ connu.
    Format(String),
    /// Autre code HTTP (5xx, 4xx inattendu).
    Server(u16),
}

#[derive(Debug, PartialEq, Clone)]
pub struct ProfileInfo {
    pub email: Option<String>,
    pub tier: Option<String>,
    pub has_max: bool,
    pub has_pro: bool,
}

#[derive(Debug, PartialEq, Clone)]
pub struct UsageInfo {
    pub five_hour: Option<Bucket>,
    pub seven_day: Option<Bucket>,
    pub seven_day_sonnet: Option<Bucket>,
}

/// Statut HTTP commun aux sondes. `None` = c'est un 200 à analyser.
fn common<T>(status: u16, body: &str) -> Option<Fetch<T>> {
    match status {
        200 => None,
        401 => Some(Fetch::Unauthorized),
        403 => Some(Fetch::Forbidden),
        429 => Some(Fetch::RateLimited),
        511 => Some(Fetch::Unreachable("portail captif (HTTP 511)".into())),
        s => {
            let _ = body; // jamais de corps serveur dans nos messages
            Some(Fetch::Server(s))
        }
    }
}

fn json_or_unreachable<T>(body: &str) -> Result<Value, Fetch<T>> {
    match serde_json::from_str::<Value>(body) {
        Ok(v @ Value::Object(_)) => Ok(v),
        Ok(_) => Err(Fetch::Format("réponse JSON inattendue".into())),
        Err(_) => Err(Fetch::Unreachable(
            "réponse inattendue (portail captif ou proxy ?)".into(),
        )),
    }
}

pub fn classify_profile(status: u16, body: &str) -> Fetch<ProfileInfo> {
    if let Some(f) = common(status, body) {
        return f;
    }
    let v = match json_or_unreachable(body) {
        Ok(v) => v,
        Err(f) => return f,
    };
    let account = v.get("account").filter(|a| a.is_object());
    let org = v.get("organization").filter(|o| o.is_object());
    if account.is_none() && org.is_none() {
        return Fetch::Format("profil sans champ connu".into());
    }
    let s = |o: Option<&Value>, k: &str| {
        o.and_then(|o| o.get(k))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
    };
    let b = |o: Option<&Value>, k: &str| {
        o.and_then(|o| o.get(k))
            .and_then(Value::as_bool)
            .unwrap_or(false)
    };
    Fetch::Ok(ProfileInfo {
        email: s(account, "email"),
        tier: s(org, "rate_limit_tier"),
        has_max: b(account, "has_claude_max"),
        has_pro: b(account, "has_claude_pro"),
    })
}

fn bucket(v: &Value, key: &str) -> Option<Bucket> {
    let b = v.get(key)?.as_object()?;
    let u = b.get("utilization")?.as_f64()?;
    if !u.is_finite() {
        return None;
    }
    let resets_at = b
        .get("resets_at")
        .and_then(Value::as_str)
        .map(str::to_string);
    Some(Bucket {
        pct: u.clamp(0.0, 999.0).trunc() as u32,
        resets_at,
    })
}

pub fn classify_usage(status: u16, body: &str) -> Fetch<UsageInfo> {
    if let Some(f) = common(status, body) {
        return f;
    }
    let v = match json_or_unreachable(body) {
        Ok(v) => v,
        Err(f) => return f,
    };
    let five = bucket(&v, "five_hour");
    let seven = bucket(&v, "seven_day");
    if five.is_none() && seven.is_none() {
        return Fetch::Format("usage sans fenêtre 5 h ni 7 j".into());
    }
    Fetch::Ok(UsageInfo {
        five_hour: five,
        seven_day: seven,
        seven_day_sonnet: bucket(&v, "seven_day_sonnet"),
    })
}

#[derive(Clone)]
pub struct Api {
    http: Arc<dyn Http>,
    base: String,
}

impl Api {
    pub fn new(http: Arc<dyn Http>, base: &str) -> Api {
        Api {
            http,
            base: base.trim_end_matches('/').to_string(),
        }
    }

    fn get(&self, path: &str, access: &SecretString) -> Result<(u16, String), String> {
        let req = HttpRequest {
            method: Method::Get,
            url: format!("{}{path}", self.base),
            bearer: Some(access.clone()),
            headers: vec![("anthropic-beta", BETA.to_string())],
            connect_timeout: CONNECT_TIMEOUT,
            total_timeout: REQUEST_TIMEOUT,
        };
        self.http
            .send(&req)
            .map(|r| (r.status, r.body))
            .map_err(|e| e.message())
    }

    pub fn profile(&self, access: &SecretString) -> Fetch<ProfileInfo> {
        match self.get("/api/oauth/profile", access) {
            Ok((s, b)) => classify_profile(s, &b),
            Err(m) => Fetch::Unreachable(m),
        }
    }

    pub fn usage(&self, access: &SecretString) -> Fetch<UsageInfo> {
        match self.get("/api/oauth/usage", access) {
            Ok((s, b)) => classify_usage(s, &b),
            Err(m) => Fetch::Unreachable(m),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PROFILE: &str = r#"{"account":{"uuid":"u","email":"eve@x.fr","has_claude_max":true,"has_claude_pro":false},"organization":{"rate_limit_tier":"default_claude_max_20x","organization_type":"claude_max"}}"#;
    const USAGE: &str = r#"{"five_hour":{"utilization":12.7,"resets_at":"2026-11-09T04:00:00.123456+00:00"},"seven_day":{"utilization":40.0,"resets_at":"2026-11-12T10:00:00Z"},"seven_day_sonnet":null,"seven_day_opus":null,"extra_usage":{"is_enabled":false}}"#;

    #[test]
    fn profile_ok() {
        let Fetch::Ok(p) = classify_profile(200, PROFILE) else {
            panic!()
        };
        assert_eq!(p.email.as_deref(), Some("eve@x.fr"));
        assert_eq!(p.tier.as_deref(), Some("default_claude_max_20x"));
        assert!(p.has_max && !p.has_pro);
    }

    #[test]
    fn profile_status_mapping() {
        assert_eq!(classify_profile(401, "{}"), Fetch::Unauthorized);
        assert_eq!(classify_profile(403, "{}"), Fetch::Forbidden);
        assert_eq!(classify_profile(429, "{}"), Fetch::RateLimited);
        assert_eq!(classify_profile(503, "boum"), Fetch::Server(503));
        assert!(matches!(
            classify_profile(511, "<html>"),
            Fetch::Unreachable(_)
        ));
    }

    #[test]
    fn captive_portal_is_unreachable_not_error() {
        let html = "<html><body>Connectez-vous au Wi-Fi</body></html>";
        assert!(matches!(classify_profile(200, html), Fetch::Unreachable(_)));
        assert!(matches!(classify_usage(200, html), Fetch::Unreachable(_)));
        assert!(matches!(classify_usage(200, ""), Fetch::Unreachable(_)));
    }

    #[test]
    fn unknown_json_is_a_format_error_never_zero_percent() {
        assert!(matches!(classify_usage(200, "{}"), Fetch::Format(_)));
        assert!(matches!(
            classify_usage(200, r#"{"foo":1}"#),
            Fetch::Format(_)
        ));
        assert!(matches!(
            classify_usage(200, r#"{"five_hour":null,"seven_day":null}"#),
            Fetch::Format(_)
        ));
        assert!(matches!(
            classify_usage(200, r#"{"five_hour":{"utilization":null}}"#),
            Fetch::Format(_)
        ));
        assert!(matches!(classify_usage(200, "[1,2]"), Fetch::Format(_)));
        assert!(matches!(classify_profile(200, "{}"), Fetch::Format(_)));
    }

    #[test]
    fn usage_ok_truncates_percentages() {
        let Fetch::Ok(u) = classify_usage(200, USAGE) else {
            panic!()
        };
        assert_eq!(u.five_hour.as_ref().unwrap().pct, 12);
        assert_eq!(u.seven_day.as_ref().unwrap().pct, 40);
        assert!(u.seven_day_sonnet.is_none());
        assert_eq!(
            u.seven_day.unwrap().resets_at.as_deref(),
            Some("2026-11-12T10:00:00Z")
        );
    }

    #[test]
    fn usage_99_9_is_not_limited() {
        let body = r#"{"five_hour":{"utilization":99.9,"resets_at":null},"seven_day":{"utilization":100.0,"resets_at":null}}"#;
        let Fetch::Ok(u) = classify_usage(200, body) else {
            panic!()
        };
        assert_eq!(u.five_hour.unwrap().pct, 99);
        assert_eq!(u.seven_day.unwrap().pct, 100);
    }

    #[test]
    fn usage_429_is_rate_limited_not_exhausted() {
        assert_eq!(
            classify_usage(429, r#"{"error":"rate_limited"}"#),
            Fetch::RateLimited
        );
    }
}
