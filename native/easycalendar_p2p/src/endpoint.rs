use crate::error::P2pError;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EndpointState {
    Created,
    Running,
    Closed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EndpointConfig {
    pub endpoint_id: String,
    pub group_id: String,
}

/// Lifecycle boundary used by Flutter until the Iroh-backed provider is wired.
/// Networking is intentionally not implemented here; this prevents Dart from
/// depending on UDP, QUIC, or relay details.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Endpoint {
    config: EndpointConfig,
    state: EndpointState,
}

impl Endpoint {
    pub fn new(config: EndpointConfig) -> Result<Self, P2pError> {
        if config.endpoint_id.is_empty() || config.endpoint_id.len() > 200 {
            return Err(P2pError::InvalidArgument("endpoint id is invalid"));
        }
        if config.group_id.is_empty() || config.group_id.len() > 128 {
            return Err(P2pError::InvalidArgument("group id is invalid"));
        }
        Ok(Self {
            config,
            state: EndpointState::Created,
        })
    }

    pub fn start(&mut self) -> Result<(), P2pError> {
        if self.state == EndpointState::Closed {
            return Err(P2pError::EndpointClosed);
        }
        self.state = EndpointState::Running;
        Ok(())
    }

    pub fn close(&mut self) {
        self.state = EndpointState::Closed;
    }

    pub fn state(&self) -> EndpointState {
        self.state
    }

    pub fn config(&self) -> &EndpointConfig {
        &self.config
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn endpoint_lifecycle_is_explicit_and_close_is_terminal() {
        let mut endpoint = Endpoint::new(EndpointConfig {
            endpoint_id: "endpoint-1".into(),
            group_id: "group-1".into(),
        })
        .unwrap();
        assert_eq!(endpoint.state(), EndpointState::Created);
        endpoint.start().unwrap();
        assert_eq!(endpoint.state(), EndpointState::Running);
        endpoint.close();
        assert_eq!(endpoint.start(), Err(P2pError::EndpointClosed));
    }
}
