use std::sync::Arc;
use std::time::Duration;

use iroh::{Endpoint as IrohEndpoint, EndpointAddr, SecretKey, endpoint::presets};
use tokio::runtime::Runtime;

use crate::error::P2pError;

/// ALPN is part of the wire contract and must remain stable across releases.
pub const ALPN: &[u8] = b"easycalendar/sync/1";

/// Small synchronous wrapper around Iroh's async endpoint.
///
/// Flutter calls the native bridge synchronously through FFI. Keeping the
/// runtime here prevents Tokio details from leaking into the Dart boundary.
pub struct IrohEndpointHandle {
    runtime: Arc<Runtime>,
    endpoint: IrohEndpoint,
}

impl IrohEndpointHandle {
    pub fn bind(secret_key: [u8; 32]) -> Result<Self, P2pError> {
        let runtime = Arc::new(
            Runtime::new()
                .map_err(|_| P2pError::TransportUnavailable)?,
        );
        let key = SecretKey::from_bytes(&secret_key);
        let endpoint = runtime.block_on(async {
            IrohEndpoint::builder(presets::N0)
                .secret_key(key)
                .alpns(vec![ALPN.to_vec()])
                .bind()
                .await
        })
        .map_err(|_| P2pError::TransportUnavailable)?;
        Ok(Self { runtime, endpoint })
    }

    pub fn endpoint_id(&self) -> String {
        self.endpoint.id().to_string()
    }

    pub fn endpoint_ticket(&self) -> Result<String, P2pError> {
        self.wait_for_ticket()
    }

    /// Waits until a default relay has registered the endpoint and returns a
    /// JSON ticket containing the current EndpointAddr.
    pub fn wait_for_ticket(&self) -> Result<String, P2pError> {
        let address = self.runtime.block_on(async {
            tokio::time::timeout(Duration::from_secs(15), self.endpoint.online())
                .await
                .map_err(|_| P2pError::TransportUnavailable)?;
            Ok::<EndpointAddr, P2pError>(self.endpoint.addr())
        })?;
        serde_json::to_string(&address)
            .map_err(|_| P2pError::TransportUnavailable)
    }

    pub fn connect(&self, ticket: &str) -> Result<(), P2pError> {
        let address: EndpointAddr = serde_json::from_str(ticket)
            .map_err(|_| P2pError::InvalidArgument("endpoint ticket is invalid"))?;
        self.runtime
            .block_on(self.endpoint.connect(address, ALPN))
            .map(|_| ())
            .map_err(|_| P2pError::TransportUnavailable)
    }

    pub fn close(&self) {
        self.runtime.block_on(self.endpoint.close());
    }
}

impl Drop for IrohEndpointHandle {
    fn drop(&mut self) {
        if !self.endpoint.is_closed() {
            self.close();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn alpn_is_stable() {
        assert_eq!(ALPN, b"easycalendar/sync/1");
    }

    #[test]
    fn malformed_ticket_is_rejected_before_network_access() {
        let endpoint = IrohEndpointHandle::bind([7; 32]);
        if let Ok(endpoint) = endpoint {
            assert_eq!(
                endpoint.connect("not-json"),
                Err(P2pError::InvalidArgument("endpoint ticket is invalid"))
            );
            endpoint.close();
        }
    }
}
