use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use iroh::{
    Endpoint as IrohEndpoint,
    EndpointAddr,
    SecretKey,
    endpoint::{Connection, SendStream, presets},
};
use tokio::runtime::Runtime;

use crate::error::P2pError;
use crate::protocol::Frame;
use crate::session::{receive_frame, request, send_frame};

/// ALPN is part of the wire contract and must remain stable across releases.
pub const ALPN: &[u8] = b"easycalendar/sync/1";

/// Small synchronous wrapper around Iroh's async endpoint.
///
/// Flutter calls the native bridge synchronously through FFI. Keeping the
/// runtime here prevents Tokio details from leaking into the Dart boundary.
pub struct IrohEndpointHandle {
    runtime: Arc<Runtime>,
    endpoint: IrohEndpoint,
    connections: Mutex<HashMap<u64, Connection>>,
    pending: Mutex<HashMap<u64, PendingRequest>>,
    next_connection_id: AtomicU64,
}

struct PendingRequest {
    _connection: Connection,
    send: SendStream,
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
        Ok(Self {
            runtime,
            endpoint,
            connections: Mutex::new(HashMap::new()),
            pending: Mutex::new(HashMap::new()),
            next_connection_id: AtomicU64::new(1),
        })
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

    pub fn connect(&self, ticket: &str) -> Result<u64, P2pError> {
        let address: EndpointAddr = serde_json::from_str(ticket)
            .map_err(|_| P2pError::InvalidArgument("endpoint ticket is invalid"))?;
        let connection = self.runtime
            .block_on(self.endpoint.connect(address, ALPN))
            .map_err(|_| P2pError::TransportUnavailable)
            ?;
        Ok(self.insert_connection(connection))
    }

    pub fn accept(&self, timeout_duration: Duration) -> Result<Option<u64>, P2pError> {
        let incoming = self.runtime.block_on(async {
            match tokio::time::timeout(timeout_duration, self.endpoint.accept()).await {
                Ok(incoming) => Ok(incoming),
                Err(_) => Ok(None),
            }
        })?;
        let Some(incoming) = incoming else {
            return Ok(None);
        };
        let connection = self
            .runtime
            .block_on(incoming)
            .map_err(|_| P2pError::TransportUnavailable)?;
        Ok(Some(self.insert_connection(connection)))
    }

    pub fn request(
        &self,
        connection_id: u64,
        encoded_request: &[u8],
    ) -> Result<Vec<u8>, P2pError> {
        let frame = Frame::decode(encoded_request)?;
        let connection = self.take_connection(connection_id)?;
        let result = self.runtime.block_on(request(&connection, frame));
        self.put_connection(connection_id, connection)?;
        result.map(|response| response.encode())
    }

    pub fn receive_request(&self, connection_id: u64) -> Result<Vec<u8>, P2pError> {
        let connection = self.take_connection(connection_id)?;
        let accepted = self.runtime.block_on(connection.accept_bi());
        let (send, mut receive) = match accepted {
            Ok(streams) => streams,
            Err(_) => {
                self.put_connection(connection_id, connection)?;
                return Err(P2pError::TransportUnavailable);
            }
        };
        let frame = match self.runtime.block_on(receive_frame(&mut receive)) {
            Ok(frame) => frame,
            Err(error) => {
                self.put_connection(connection_id, connection)?;
                return Err(error);
            }
        };
        self.pending
            .lock()
            .map_err(|_| P2pError::TransportUnavailable)?
            .insert(connection_id, PendingRequest { _connection: connection, send });
        Ok(frame.encode())
    }

    pub fn respond(
        &self,
        connection_id: u64,
        encoded_response: &[u8],
    ) -> Result<(), P2pError> {
        let frame = Frame::decode(encoded_response)?;
        let mut pending = self
            .pending
            .lock()
            .map_err(|_| P2pError::TransportUnavailable)?
            .remove(&connection_id)
            .ok_or(P2pError::InvalidArgument("connection has no pending request"))?;
        self.runtime
            .block_on(send_frame(&mut pending.send, &frame))
    }

    fn insert_connection(&self, connection: Connection) -> u64 {
        let id = self.next_connection_id.fetch_add(1, Ordering::Relaxed);
        if let Ok(mut connections) = self.connections.lock() {
            connections.insert(id, connection);
        }
        id
    }

    fn take_connection(&self, connection_id: u64) -> Result<Connection, P2pError> {
        self.connections
            .lock()
            .map_err(|_| P2pError::TransportUnavailable)?
            .remove(&connection_id)
            .ok_or(P2pError::InvalidArgument("connection ID is invalid"))
    }

    fn put_connection(&self, connection_id: u64, connection: Connection) -> Result<(), P2pError> {
        self.connections
            .lock()
            .map_err(|_| P2pError::TransportUnavailable)?
            .insert(connection_id, connection);
        Ok(())
    }

    pub fn close(&self) {
        if let Ok(mut connections) = self.connections.lock() {
            connections.clear();
        }
        if let Ok(mut pending) = self.pending.lock() {
            pending.clear();
        }
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
