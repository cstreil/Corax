//! Thin HTTP layer for WebDAV verbs. The `Transport` trait is the seam that
//! makes discovery/sync/push unit-testable against canned responses.

use crate::error::{CoreError, Result};

#[derive(Debug, Clone)]
pub enum DavAuth {
    Bearer(String),
    Basic(String, String),
}

#[derive(Debug, Clone, Default)]
pub struct DavResponse {
    pub status: u16,
    pub etag: Option<String>,
    pub body: String,
}

impl DavResponse {
    pub fn ok(&self) -> bool {
        (200..300).contains(&self.status)
    }
}

/// Content-Type for XML bodies (PROPFIND, REPORT). RFC 4918 verbs.
pub const XML_CONTENT_TYPE: &str = "application/xml; charset=utf-8";
/// Content-Type for iCalendar bodies (PUT of a `.ics` resource). RFC 4791 §5.3.2
/// requires `text/calendar`; iCloud answers 501 to a VCALENDAR sent as XML.
pub const ICAL_CONTENT_TYPE: &str = "text/calendar; charset=utf-8";

/// One WebDAV request. `depth` adds a Depth header when Some; `extra` carries
/// conditional headers (If-Match / If-None-Match); `content_type` is the body's
/// media type, chosen per request (`XML_CONTENT_TYPE`, `ICAL_CONTENT_TYPE`).
#[async_trait::async_trait]
pub trait Transport: Send + Sync {
    async fn request(
        &self,
        method: &str,
        url: &str,
        depth: Option<&str>,
        extra: &[(&str, &str)],
        content_type: Option<&str>,
        body: Option<String>,
    ) -> Result<DavResponse>;
}

pub struct HttpTransport {
    client: reqwest::Client,
    auth: DavAuth,
}

impl HttpTransport {
    pub fn new(auth: DavAuth) -> Result<Self> {
        let client = reqwest::Client::builder()
            .user_agent("comail-caldav/0.1")
            .timeout(std::time::Duration::from_secs(45))
            .redirect(reqwest::redirect::Policy::limited(5))
            .build()
            .map_err(|e| CoreError::CalDav(format!("http client: {e}")))?;
        Ok(Self { client, auth })
    }
}

#[async_trait::async_trait]
impl Transport for HttpTransport {
    async fn request(
        &self,
        method: &str,
        url: &str,
        depth: Option<&str>,
        extra: &[(&str, &str)],
        content_type: Option<&str>,
        body: Option<String>,
    ) -> Result<DavResponse> {
        let method = reqwest::Method::from_bytes(method.as_bytes())
            .map_err(|_| CoreError::CalDav(format!("bad method {method}")))?;
        let mut req = self.client.request(method, url);
        req = match &self.auth {
            DavAuth::Bearer(token) => req.bearer_auth(token),
            DavAuth::Basic(user, pass) => req.basic_auth(user, Some(pass)),
        };
        if let Some(d) = depth {
            req = req.header("Depth", d);
        }
        for (k, v) in extra {
            req = req.header(*k, *v);
        }
        if let Some(b) = body {
            req = req
                .header("Content-Type", content_type.unwrap_or(XML_CONTENT_TYPE))
                .body(b);
        }
        let resp = req.send().await.map_err(|e| {
            if e.is_connect() || e.is_timeout() {
                CoreError::Offline
            } else {
                CoreError::CalDav(format!("request: {e}"))
            }
        })?;
        let status = resp.status().as_u16();
        if status == 401 {
            return Err(CoreError::NeedsReauth);
        }
        let etag = resp
            .headers()
            .get("etag")
            .and_then(|v| v.to_str().ok())
            .map(str::to_string);
        let body = resp
            .text()
            .await
            .map_err(|e| CoreError::CalDav(format!("body: {e}")))?;
        Ok(DavResponse { status, etag, body })
    }
}

/// Canned-response transport for tests: pops responses in order and records
/// every request it saw.
#[cfg(test)]
use std::collections::HashMap;

#[cfg(test)]
pub struct MockTransport {
    pub responses: std::sync::Mutex<std::collections::VecDeque<DavResponse>>,
    pub seen: std::sync::Mutex<Vec<(String, String, Option<String>)>>, // (method, url, body)
    pub headers_seen: std::sync::Mutex<Vec<HashMap<String, String>>>,
}

#[cfg(test)]
impl MockTransport {
    pub fn new(responses: Vec<DavResponse>) -> Self {
        Self {
            responses: std::sync::Mutex::new(responses.into()),
            seen: std::sync::Mutex::new(Vec::new()),
            headers_seen: std::sync::Mutex::new(Vec::new()),
        }
    }
}

#[cfg(test)]
#[async_trait::async_trait]
impl Transport for MockTransport {
    async fn request(
        &self,
        method: &str,
        url: &str,
        depth: Option<&str>,
        extra: &[(&str, &str)],
        content_type: Option<&str>,
        body: Option<String>,
    ) -> Result<DavResponse> {
        let has_body = body.is_some();
        self.seen
            .lock()
            .unwrap()
            .push((method.to_string(), url.to_string(), body));
        let mut headers: HashMap<String, String> = extra
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        if let Some(d) = depth {
            headers.insert("Depth".into(), d.to_string());
        }
        // Mirror the wire: every body carries the effective Content-Type.
        if let Some(ct) = content_type {
            headers.insert("Content-Type".into(), ct.to_string());
        } else if has_body {
            headers.insert("Content-Type".into(), XML_CONTENT_TYPE.into());
        }
        self.headers_seen.lock().unwrap().push(headers);
        self.responses
            .lock()
            .unwrap()
            .pop_front()
            .ok_or_else(|| CoreError::CalDav("mock transport exhausted".into()))
    }
}
