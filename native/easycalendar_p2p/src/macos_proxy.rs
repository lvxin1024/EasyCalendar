use core_foundation::{base::CFType, dictionary::CFDictionary, number::CFNumber, string::CFString};
use system_configuration::dynamic_store::SCDynamicStoreBuilder;
use url::{Host, Url};

/// GUI apps usually inherit no proxy environment variables. Read the current
/// macOS HTTPS proxy on each bind so reconnecting also picks up setting changes.
pub fn system_https_proxy() -> Option<Url> {
    let environment_configured = ["HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy"]
        .iter()
        .any(|name| std::env::var_os(name).is_some());
    let proxies = SCDynamicStoreBuilder::new("EasyCalendar P2P")
        .build()?
        .get_proxies()?;
    https_proxy(&proxies, environment_configured)
}

fn https_proxy(
    proxies: &CFDictionary<CFString, CFType>,
    environment_configured: bool,
) -> Option<Url> {
    // Explicit environment settings take precedence, including an empty value.
    // Iroh handles their parsing and priority through proxy_from_env().
    if environment_configured || number(proxies, "HTTPSEnable")? != 1 {
        return None;
    }
    let host = proxies
        .find(&CFString::new("HTTPSProxy"))?
        .downcast::<CFString>()?
        .to_string();
    let port = u16::try_from(number(proxies, "HTTPSPort")?).ok()?;
    if port == 0 {
        return None;
    }
    let host = match host.parse::<std::net::Ipv6Addr>() {
        Ok(address) => Host::Ipv6(address),
        Err(_) => Host::parse(&host).ok()?,
    };
    // macOS's HTTPS proxy uses an HTTP CONNECT tunnel, not TLS to the proxy.
    Url::parse(&format!("http://{host}:{port}")).ok()
}

fn number(proxies: &CFDictionary<CFString, CFType>, key: &str) -> Option<i64> {
    proxies
        .find(&CFString::new(key))?
        .downcast::<CFNumber>()?
        .to_i64()
}

#[cfg(test)]
mod tests {
    use super::*;
    use core_foundation::base::TCFType;

    fn settings(enabled: i32, host: &str, port: i64) -> CFDictionary<CFString, CFType> {
        CFDictionary::from_CFType_pairs(&[
            (
                CFString::new("HTTPSEnable"),
                CFNumber::from(enabled).as_CFType(),
            ),
            (CFString::new("HTTPSProxy"), CFString::new(host).as_CFType()),
            (CFString::new("HTTPSPort"), CFNumber::from(port).as_CFType()),
        ])
    }

    #[test]
    fn enabled_https_proxy_uses_http_connect() {
        assert_eq!(
            https_proxy(&settings(1, "proxy.example.com", 7897), false)
                .unwrap()
                .as_str(),
            "http://proxy.example.com:7897/"
        );
        assert_eq!(
            https_proxy(&settings(1, "::1", 7897), false)
                .unwrap()
                .as_str(),
            "http://[::1]:7897/"
        );
    }

    #[test]
    fn disabled_or_invalid_system_proxy_is_ignored() {
        assert!(https_proxy(&settings(0, "proxy.example.com", 7897), false).is_none());
        for port in [-1, 0, 65536] {
            assert!(https_proxy(&settings(1, "proxy.example.com", port), false).is_none());
        }
        for host in [
            "",
            "bad host",
            "user@proxy.example.com",
            "proxy.example.com/path",
        ] {
            assert!(https_proxy(&settings(1, host, 7897), false).is_none());
        }
    }

    #[test]
    fn explicit_environment_proxy_takes_precedence() {
        assert!(https_proxy(&settings(1, "proxy.example.com", 7897), true).is_none());
    }
}
