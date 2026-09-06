mod auth;
mod endpoint;
mod error;
mod protocol;

pub use auth::{challenge_response, verify_response};
pub use endpoint::{Endpoint, EndpointConfig, EndpointState};
pub use error::{ErrorCode, P2pError};
pub use protocol::{validate_frame, Frame, FrameKind, MAX_FRAME_BYTES, PROTOCOL_VERSION};

#[unsafe(no_mangle)]
pub extern "C" fn easycalendar_p2p_protocol_version() -> u32 {
    PROTOCOL_VERSION as u32
}

#[unsafe(no_mangle)]
pub extern "C" fn easycalendar_p2p_max_frame_bytes() -> u32 {
    MAX_FRAME_BYTES as u32
}

#[unsafe(no_mangle)]
pub extern "C" fn easycalendar_p2p_validate_frame(
    kind: u8,
    payload_len: usize,
) -> i32 {
    validate_frame(kind, payload_len)
        .map(|_| ErrorCode::Ok as i32)
        .unwrap_or_else(|error| error.code() as i32)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn easycalendar_p2p_verify_auth(
    secret_ptr: *const u8,
    secret_len: usize,
    nonce_ptr: *const u8,
    nonce_len: usize,
    endpoint_ptr: *const u8,
    endpoint_len: usize,
    response_ptr: *const u8,
    response_len: usize,
) -> i32 {
    let Some(secret) = read_bytes(secret_ptr, secret_len) else {
        return ErrorCode::InvalidArgument as i32;
    };
    let Some(nonce) = read_bytes(nonce_ptr, nonce_len) else {
        return ErrorCode::InvalidArgument as i32;
    };
    let Some(endpoint) = read_bytes(endpoint_ptr, endpoint_len) else {
        return ErrorCode::InvalidArgument as i32;
    };
    let Some(response) = read_bytes(response_ptr, response_len) else {
        return ErrorCode::InvalidArgument as i32;
    };
    let Ok(endpoint_id) = std::str::from_utf8(endpoint) else {
        return ErrorCode::InvalidArgument as i32;
    };
    verify_response(secret, nonce, endpoint_id, response)
        .map(|_| ErrorCode::Ok as i32)
        .unwrap_or_else(|error| error.code() as i32)
}

unsafe fn read_bytes<'a>(pointer: *const u8, length: usize) -> Option<&'a [u8]> {
    if length == 0 {
        return Some(&[]);
    }
    if pointer.is_null() {
        return None;
    }
    Some(unsafe { std::slice::from_raw_parts(pointer, length) })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn c_abi_validation_returns_stable_codes() {
        assert_eq!(easycalendar_p2p_protocol_version(), 1);
        assert_eq!(easycalendar_p2p_validate_frame(FrameKind::Push as u8, 4), 0);
        assert_eq!(easycalendar_p2p_validate_frame(99, 4), ErrorCode::InvalidCode as i32);
        assert_eq!(
            easycalendar_p2p_validate_frame(FrameKind::Push as u8, MAX_FRAME_BYTES),
            ErrorCode::FrameTooLarge as i32
        );
    }
}
