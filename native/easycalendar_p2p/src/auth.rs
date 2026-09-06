use hmac::{Hmac, Mac};
use sha2::Sha256;

use crate::error::P2pError;
use crate::protocol::PROTOCOL_VERSION;

type HmacSha256 = Hmac<Sha256>;
const AUTH_DOMAIN: &[u8] = b"easycalendar.sync.auth.v1\0";
const SECRET_BYTES: usize = 32;
const NONCE_MAX_BYTES: usize = 64;
const ENDPOINT_MAX_BYTES: usize = 200;

pub fn challenge_response(
    group_secret: &[u8],
    nonce: &[u8],
    endpoint_id: &str,
) -> Result<[u8; 32], P2pError> {
    validate_inputs(group_secret, nonce, endpoint_id)?;
    let mut message = Vec::with_capacity(AUTH_DOMAIN.len() + nonce.len() + endpoint_id.len() + 2);
    message.extend_from_slice(AUTH_DOMAIN);
    message.extend_from_slice(nonce);
    message.extend_from_slice(endpoint_id.as_bytes());
    message.extend_from_slice(&PROTOCOL_VERSION.to_be_bytes());
    let mut mac = HmacSha256::new_from_slice(group_secret)
        .map_err(|_| P2pError::InvalidArgument("group secret must be 32 bytes"))?;
    mac.update(&message);
    let digest = mac.finalize().into_bytes();
    let mut response = [0_u8; 32];
    response.copy_from_slice(&digest);
    Ok(response)
}

pub fn verify_response(
    group_secret: &[u8],
    nonce: &[u8],
    endpoint_id: &str,
    response: &[u8],
) -> Result<(), P2pError> {
    if response.len() != 32 {
        return Err(P2pError::AuthenticationFailed);
    }
    validate_inputs(group_secret, nonce, endpoint_id)?;
    let mut message = Vec::with_capacity(AUTH_DOMAIN.len() + nonce.len() + endpoint_id.len() + 2);
    message.extend_from_slice(AUTH_DOMAIN);
    message.extend_from_slice(nonce);
    message.extend_from_slice(endpoint_id.as_bytes());
    message.extend_from_slice(&PROTOCOL_VERSION.to_be_bytes());
    let mut mac = HmacSha256::new_from_slice(group_secret)
        .map_err(|_| P2pError::InvalidArgument("group secret must be 32 bytes"))?;
    mac.update(&message);
    mac.verify_slice(response)
        .map_err(|_| P2pError::AuthenticationFailed)
}

fn validate_inputs(group_secret: &[u8], nonce: &[u8], endpoint_id: &str) -> Result<(), P2pError> {
    if group_secret.len() != SECRET_BYTES {
        return Err(P2pError::InvalidArgument("group secret must be 32 bytes"));
    }
    if nonce.is_empty() || nonce.len() > NONCE_MAX_BYTES {
        return Err(P2pError::InvalidArgument("nonce length is invalid"));
    }
    if endpoint_id.is_empty() || endpoint_id.len() > ENDPOINT_MAX_BYTES {
        return Err(P2pError::InvalidArgument("endpoint id length is invalid"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn challenge_response_verifies_and_rejects_tampering() {
        let secret = [7_u8; SECRET_BYTES];
        let nonce = b"nonce";
        let response = challenge_response(&secret, nonce, "endpoint-1").unwrap();
        assert!(verify_response(&secret, nonce, "endpoint-1", &response).is_ok());
        assert_eq!(
            verify_response(&secret, nonce, "endpoint-2", &response),
            Err(P2pError::AuthenticationFailed)
        );
    }
}
