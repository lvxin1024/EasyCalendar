mod auth;
mod endpoint;
mod error;
mod iroh_endpoint;
mod protocol;
mod session;

use std::ptr;

pub use auth::{challenge_response, verify_response};
pub use endpoint::{Endpoint, EndpointConfig, EndpointState};
pub use error::{ErrorCode, P2pError};
pub use iroh_endpoint::{ALPN, IrohEndpointHandle};
pub use protocol::{validate_frame, Frame, FrameKind, MAX_FRAME_BYTES, PROTOCOL_VERSION};
pub use session::{receive_frame, request, send_frame};

fn copy_string(value: &str, output: *mut u8, capacity: usize) -> Result<usize, P2pError> {
    if value.len() > capacity {
        return Err(P2pError::BufferTooSmall);
    }
    if !value.is_empty() && output.is_null() {
        return Err(P2pError::InvalidArgument("output buffer is null"));
    }
    if !value.is_empty() {
        unsafe { ptr::copy_nonoverlapping(value.as_ptr(), output, value.len()) };
    }
    Ok(value.len())
}

/// Creates an Iroh endpoint with a stable secret key.
///
/// The returned pointer is owned by the caller and must be released with
/// `easycalendar_p2p_endpoint_close`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn easycalendar_p2p_endpoint_bind(
    secret_ptr: *const u8,
    secret_len: usize,
) -> *mut IrohEndpointHandle {
    let Some(secret) = read_bytes(secret_ptr, secret_len) else {
        return ptr::null_mut();
    };
    let Ok(secret_key) = <[u8; 32]>::try_from(secret) else {
        return ptr::null_mut();
    };
    match IrohEndpointHandle::bind(secret_key) {
        Ok(endpoint) => Box::into_raw(Box::new(endpoint)),
        Err(_) => ptr::null_mut(),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn easycalendar_p2p_endpoint_id_len(
    handle: *const IrohEndpointHandle,
) -> usize {
    let Some(handle) = handle.as_ref() else {
        return 0;
    };
    handle.endpoint_id().len()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn easycalendar_p2p_endpoint_id_copy(
    handle: *const IrohEndpointHandle,
    output: *mut u8,
    capacity: usize,
) -> i32 {
    let Some(handle) = handle.as_ref() else {
        return ErrorCode::InvalidArgument as i32;
    };
    copy_string(&handle.endpoint_id(), output, capacity)
        .map(|_| ErrorCode::Ok as i32)
        .unwrap_or_else(|error| error.code() as i32)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn easycalendar_p2p_endpoint_ticket(
    handle: *const IrohEndpointHandle,
    output: *mut u8,
    capacity: usize,
) -> i32 {
    let Some(handle) = handle.as_ref() else {
        return ErrorCode::InvalidArgument as i32;
    };
    let Ok(ticket) = handle.endpoint_ticket() else {
        return ErrorCode::TransportUnavailable as i32;
    };
    copy_string(&ticket, output, capacity)
        .map(|_| ErrorCode::Ok as i32)
        .unwrap_or_else(|error| error.code() as i32)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn easycalendar_p2p_endpoint_connect(
    handle: *const IrohEndpointHandle,
    ticket_ptr: *const u8,
    ticket_len: usize,
) -> i32 {
    let Some(handle) = handle.as_ref() else {
        return ErrorCode::InvalidArgument as i32;
    };
    let Some(ticket) = read_bytes(ticket_ptr, ticket_len) else {
        return ErrorCode::InvalidArgument as i32;
    };
    let Ok(ticket) = std::str::from_utf8(ticket) else {
        return ErrorCode::InvalidArgument as i32;
    };
    handle
        .connect(ticket)
        .map(|_| ErrorCode::Ok as i32)
        .unwrap_or_else(|error| error.code() as i32)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn easycalendar_p2p_endpoint_close(
    handle: *mut IrohEndpointHandle,
) {
    if handle.is_null() {
        return;
    }
    drop(Box::from_raw(handle));
}

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
