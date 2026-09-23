use std::collections::HashMap;
use std::future::{Future, IntoFuture};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use iroh::{
    endpoint::{presets, Connection, SendStream},
    Endpoint as IrohEndpoint, EndpointAddr, SecretKey, TransportAddr,
};
use tokio::runtime::Runtime;

use crate::error::P2pError;
use crate::protocol::Frame;
use crate::session::{receive_frame, request, send_frame};

/// ALPN is part of the wire contract and must remain stable across releases.
pub const ALPN: &[u8] = b"easycalendar/sync/1";
const OPERATION_TIMEOUT: Duration = Duration::from_secs(15);
const RECEIVE_POLL_TIMEOUT: Duration = Duration::from_millis(250);

/// Small synchronous wrapper around Iroh's async endpoint.
///
/// Flutter calls the native bridge synchronously through FFI. Keeping the
/// runtime here prevents Tokio details from leaking into the Dart boundary.
pub struct IrohEndpointHandle {
    runtime: Arc<Runtime>,
    endpoint: IrohEndpoint,
    connections: Mutex<HashMap<u64, Connection>>,
    pending: Mutex<HashMap<u64, PendingRequest>>,
    last_error: Mutex<String>,
    next_connection_id: AtomicU64,
}

struct PendingRequest {
    connection: Connection,
    send: SendStream,
}

impl IrohEndpointHandle {
    pub fn bind(secret_key: [u8; 32]) -> Result<Self, P2pError> {
        let runtime = Arc::new(Runtime::new().map_err(|_| P2pError::TransportUnavailable)?);
        let key = SecretKey::from_bytes(&secret_key);
        let endpoint = runtime
            .block_on(async {
                let builder = IrohEndpoint::builder(presets::N0)
                    .secret_key(key)
                    .alpns(vec![ALPN.to_vec()])
                    .proxy_from_env();
                #[cfg(target_os = "macos")]
                let builder = match crate::macos_proxy::system_https_proxy() {
                    Some(proxy) => builder.proxy_url(proxy),
                    None => builder,
                };
                builder.bind().await
            })
            .map_err(|_| P2pError::TransportUnavailable)?;
        Ok(Self {
            runtime,
            endpoint,
            connections: Mutex::new(HashMap::new()),
            pending: Mutex::new(HashMap::new()),
            last_error: Mutex::new(String::new()),
            next_connection_id: AtomicU64::new(1),
        })
    }

    pub fn last_error(&self) -> String {
        self.last_error
            .lock()
            .map(|error| error.clone())
            .unwrap_or_else(|_| "transport error details are unavailable".to_owned())
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
                .map_err(|_| P2pError::transport("relay did not become online before timeout"))?;
            Ok::<EndpointAddr, P2pError>(stable_ticket_address(self.endpoint.addr()))
        });
        let address = address.map_err(|error| self.record_error(error))?;
        serde_json::to_string(&address).map_err(|error| self.record_transport(error))
    }

    pub fn connect(&self, ticket: &str) -> Result<u64, P2pError> {
        let address: EndpointAddr = serde_json::from_str(ticket)
            .map_err(|_| P2pError::InvalidArgument("endpoint ticket is invalid"))?;
        let connection = self.with_timeout("connect", async {
            self.endpoint
                .connect(address, ALPN)
                .await
                .map_err(P2pError::transport)
        })?;
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
        let connection = self.with_timeout("accept handshake", async {
            incoming.into_future().await.map_err(P2pError::transport)
        })?;
        Ok(Some(self.insert_connection(connection)))
    }

    pub fn request(&self, connection_id: u64, encoded_request: &[u8]) -> Result<Vec<u8>, P2pError> {
        let frame = Frame::decode(encoded_request)?;
        let connection = self.take_connection(connection_id)?;
        let result = self.with_timeout("request", request(&connection, frame));
        self.put_connection(connection_id, connection)?;
        result.map(|response| response.encode())
    }

    /// Returns an empty buffer when no new request arrives within the polling
    /// interval, allowing the synchronous caller to service other connections.
    pub fn receive_request(&self, connection_id: u64) -> Result<Vec<u8>, P2pError> {
        let connection = self.take_connection(connection_id)?;
        let accepted = self.runtime.block_on(async {
            tokio::time::timeout(RECEIVE_POLL_TIMEOUT, connection.accept_bi()).await
        });
        let (send, mut receive) = match accepted {
            Ok(Ok(streams)) => streams,
            Ok(Err(error)) => {
                return Err(self.record_transport(error));
            }
            Err(_) => {
                self.put_connection(connection_id, connection)?;
                // Zero bytes means no request is ready; valid frames always
                // contain a header. Yield the serial FFI worker to other peers.
                return Ok(Vec::new());
            }
        };
        let frame = match self.with_timeout("receive frame", receive_frame(&mut receive)) {
            Ok(frame) => frame,
            Err(error) => {
                self.put_connection(connection_id, connection)?;
                return Err(error);
            }
        };
        self.pending
            .lock()
            .map_err(|_| P2pError::TransportUnavailable)?
            .insert(connection_id, PendingRequest { connection, send });
        Ok(frame.encode())
    }

    pub fn respond(&self, connection_id: u64, encoded_response: &[u8]) -> Result<(), P2pError> {
        let frame = Frame::decode(encoded_response)?;
        let mut pending = self
            .pending
            .lock()
            .map_err(|_| P2pError::TransportUnavailable)?
            .remove(&connection_id)
            .ok_or(P2pError::InvalidArgument(
                "connection has no pending request",
            ))?;
        let result = self.with_timeout("respond", send_frame(&mut pending.send, &frame));
        // A response completes one stream, not the connection. Restore the
        // handle even on a stream error, as request() does, so the caller can
        // retry or close it without losing track of the connection.
        self.put_connection(connection_id, pending.connection)?;
        result
    }

    fn with_timeout<T>(
        &self,
        operation_name: &str,
        operation: impl Future<Output = Result<T, P2pError>>,
    ) -> Result<T, P2pError> {
        self.runtime
            .block_on(async {
                tokio::time::timeout(OPERATION_TIMEOUT, operation)
                    .await
                    .map_err(|_| {
                        P2pError::transport(format!("{operation_name} timed out after 15 seconds"))
                    })?
            })
            .map_err(|error| self.record_error(error))
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

    fn record_transport(&self, error: impl std::fmt::Display) -> P2pError {
        let error = P2pError::transport(error);
        self.record_error(error)
    }

    fn record_error(&self, error: P2pError) -> P2pError {
        if error.code() == crate::error::ErrorCode::TransportUnavailable {
            if let Ok(mut last_error) = self.last_error.lock() {
                *last_error = error.to_string();
            }
        }
        error
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

/// Direct socket addresses are ephemeral and become invalid when the endpoint
/// is restarted. Keep the home relay address in a shared ticket whenever one
/// is available; it is stable across endpoint restarts and network changes.
fn stable_ticket_address(address: EndpointAddr) -> EndpointAddr {
    let relay_addresses = address
        .relay_urls()
        .cloned()
        .map(TransportAddr::Relay)
        .collect::<Vec<_>>();
    if relay_addresses.is_empty() {
        return address;
    }
    EndpointAddr::from_parts(address.id, relay_addresses)
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
    use crate::protocol::FrameKind;

    fn loopback_endpoint(secret_key: [u8; 32]) -> Arc<IrohEndpointHandle> {
        let runtime = Arc::new(Runtime::new().expect("tokio runtime"));
        let endpoint = runtime.block_on(async {
            IrohEndpoint::builder(presets::Minimal)
                .secret_key(SecretKey::from_bytes(&secret_key))
                .alpns(vec![ALPN.to_vec()])
                .bind_addr("127.0.0.1:0")
                .expect("loopback address")
                .bind()
                .await
                .expect("loopback endpoint")
        });
        Arc::new(IrohEndpointHandle {
            runtime,
            endpoint,
            connections: Mutex::new(HashMap::new()),
            pending: Mutex::new(HashMap::new()),
            last_error: Mutex::new(String::new()),
            next_connection_id: AtomicU64::new(1),
        })
    }

    #[test]
    fn one_connection_survives_idle_polling_then_serves_hello_auth_push_and_pull() {
        let server = loopback_endpoint([41; 32]);
        let client = loopback_endpoint([42; 32]);
        let ticket = serde_json::to_string(&server.endpoint.addr()).expect("loopback ticket");
        let exchanges = [
            (FrameKind::Hello, FrameKind::AuthChallenge),
            (FrameKind::AuthResponse, FrameKind::Hello),
            (FrameKind::Push, FrameKind::PushResult),
            (FrameKind::Pull, FrameKind::PullResult),
        ];
        let (completed, results) = std::sync::mpsc::channel();
        let (idle_polled, idle_ready) = std::sync::mpsc::channel();
        let serving = {
            let server = Arc::clone(&server);
            let completed = completed.clone();
            std::thread::spawn(move || {
                let result = (|| -> Result<(), P2pError> {
                    let connection_id = server
                        .accept(Duration::from_secs(2))?
                        .ok_or(P2pError::TransportUnavailable)?;
                    let started = std::time::Instant::now();
                    assert!(server.receive_request(connection_id)?.is_empty());
                    assert!(started.elapsed() < Duration::from_secs(2));
                    idle_polled.send(()).unwrap();
                    for (request_kind, response_kind) in exchanges {
                        let request = loop {
                            let bytes = server.receive_request(connection_id)?;
                            if !bytes.is_empty() {
                                break Frame::decode(&bytes)?;
                            }
                        };
                        assert_eq!(request.kind, request_kind);
                        let response = Frame::new(response_kind, request.payload)?;
                        server.respond(connection_id, &response.encode())?;
                    }
                    assert!(server
                        .connections
                        .lock()
                        .unwrap()
                        .contains_key(&connection_id));
                    assert!(server.pending.lock().unwrap().is_empty());
                    let deadline = std::time::Instant::now() + Duration::from_secs(2);
                    while let Ok(bytes) = server.receive_request(connection_id) {
                        assert!(bytes.is_empty());
                        assert!(std::time::Instant::now() < deadline, "peer did not close");
                    }
                    assert!(!server
                        .connections
                        .lock()
                        .unwrap()
                        .contains_key(&connection_id));
                    Ok(())
                })();
                completed.send(("server", result)).unwrap();
            })
        };
        let requesting = {
            let client = Arc::clone(&client);
            std::thread::spawn(move || {
                let result = (|| -> Result<(), P2pError> {
                    let connection_id = client.connect(&ticket)?;
                    idle_ready.recv_timeout(Duration::from_secs(3)).unwrap();
                    for (request_kind, response_kind) in exchanges {
                        let request = Frame::new(request_kind, b"{}".to_vec())?;
                        let response =
                            Frame::decode(&client.request(connection_id, &request.encode())?)?;
                        assert_eq!(response.kind, response_kind);
                        assert_eq!(response.payload, request.payload);
                    }
                    Ok(())
                })();
                client.close();
                completed.send(("client", result)).unwrap();
            })
        };
        // On a regression, close both endpoints before joining to unblock any
        // native call waiting for a response that will never arrive.
        let server_or_client = results.recv_timeout(Duration::from_secs(5));
        let client_or_server = results.recv_timeout(Duration::from_secs(5));
        server.close();
        client.close();
        serving.join().expect("server thread");
        requesting.join().expect("client thread");
        for result in [server_or_client, client_or_server] {
            let (side, result) = result.expect("request/response exceeded the test deadline");
            assert!(result.is_ok(), "{side}: {result:?}");
        }
    }

    #[test]
    fn unanswered_request_times_out_and_retains_connection_for_cleanup() {
        let server = loopback_endpoint([43; 32]);
        let client = loopback_endpoint([44; 32]);
        let ticket = serde_json::to_string(&server.endpoint.addr()).expect("loopback ticket");
        let (completed, result) = std::sync::mpsc::channel();
        let requesting = {
            let client = Arc::clone(&client);
            std::thread::spawn(move || {
                let result = (|| -> Result<(), P2pError> {
                    let connection_id = client.connect(&ticket)?;
                    let frame = Frame::new(FrameKind::Hello, b"{}".to_vec())?;
                    let error = client.request(connection_id, &frame.encode()).unwrap_err();
                    assert_eq!(error.to_string(), "request timed out after 15 seconds");
                    assert_eq!(client.last_error(), error.to_string());
                    assert!(client
                        .connections
                        .lock()
                        .unwrap()
                        .contains_key(&connection_id));
                    Ok(())
                })();
                completed.send(result).unwrap();
            })
        };
        let connection_id = server
            .accept(Duration::from_secs(2))
            .expect("accept connection")
            .expect("incoming request");
        // Keep the connection open without responding. QUIC liveness cannot
        // substitute for an application request deadline.
        let completed = result.recv_timeout(OPERATION_TIMEOUT + Duration::from_secs(5));
        server.close();
        client.close();
        requesting.join().expect("client thread");
        assert!(completed
            .expect("request deadline was not enforced")
            .is_ok());
        assert!(!server
            .connections
            .lock()
            .unwrap()
            .contains_key(&connection_id));
    }

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

    #[test]
    fn local_endpoints_complete_the_alpn_handshake() {
        let runtime = Runtime::new().expect("tokio runtime");
        runtime.block_on(async {
            let server = IrohEndpoint::builder(presets::Minimal)
                .secret_key(SecretKey::from_bytes(&[11; 32]))
                .alpns(vec![ALPN.to_vec()])
                .bind_addr("127.0.0.1:0")
                .expect("server address")
                .bind()
                .await
                .expect("server endpoint");
            let client = IrohEndpoint::builder(presets::Minimal)
                .secret_key(SecretKey::from_bytes(&[12; 32]))
                .alpns(vec![ALPN.to_vec()])
                .bind_addr("127.0.0.1:0")
                .expect("client address")
                .bind()
                .await
                .expect("client endpoint");
            let address = EndpointAddr::from_parts(
                server.id(),
                server.addr().ip_addrs().cloned().map(TransportAddr::Ip),
            );
            let accepting = async {
                let incoming = server.accept().await.expect("incoming connection");
                incoming.into_future().await.expect("server handshake")
            };
            let connecting = client.connect(address, ALPN);
            let (server_result, client_result) = tokio::join!(accepting, connecting);
            assert_eq!(server_result.alpn(), ALPN);
            assert_eq!(client_result.expect("client handshake").alpn(), ALPN);
            server.close().await;
            client.close().await;
        });
    }

    #[test]
    fn serialized_endpoint_addr_round_trips_between_endpoints() {
        let runtime = Runtime::new().expect("tokio runtime");
        runtime.block_on(async {
            let server = IrohEndpoint::builder(presets::Minimal)
                .secret_key(SecretKey::from_bytes(&[21; 32]))
                .alpns(vec![ALPN.to_vec()])
                .bind_addr("127.0.0.1:0")
                .expect("server address")
                .bind()
                .await
                .expect("server endpoint");
            let client = IrohEndpoint::builder(presets::Minimal)
                .secret_key(SecretKey::from_bytes(&[22; 32]))
                .alpns(vec![ALPN.to_vec()])
                .bind_addr("127.0.0.1:0")
                .expect("client address")
                .bind()
                .await
                .expect("client endpoint");
            let ticket = serde_json::to_string(&server.addr()).expect("ticket");
            let address: EndpointAddr = serde_json::from_str(&ticket).expect("decoded ticket");
            let accepting = async {
                server
                    .accept()
                    .await
                    .expect("incoming connection")
                    .into_future()
                    .await
                    .expect("server handshake")
            };
            let connecting = client.connect(address, ALPN);
            let (server_result, client_result) = tokio::join!(accepting, connecting);
            assert_eq!(server_result.alpn(), ALPN);
            assert_eq!(client_result.expect("client handshake").alpn(), ALPN);
            server.close().await;
            client.close().await;
        });
    }

    #[test]
    fn ticket_address_drops_ephemeral_direct_addresses_when_relay_exists() {
        let id = SecretKey::from_bytes(&[31; 32]).public();
        let relay: iroh::RelayUrl = "https://relay.example.com".parse().expect("relay URL");
        let address = EndpointAddr::from_parts(
            id,
            [
                TransportAddr::Relay(relay.clone()),
                TransportAddr::Ip("192.0.2.10:1234".parse().expect("IP address")),
            ],
        );
        let stable = stable_ticket_address(address);
        assert_eq!(stable.id, id);
        assert_eq!(
            stable.relay_urls().cloned().collect::<Vec<_>>(),
            vec![relay]
        );
        assert_eq!(stable.ip_addrs().count(), 0);
    }
}
