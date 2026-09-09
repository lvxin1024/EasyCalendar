use std::fmt;

/// Stable error identifiers shared by the Rust bridge and Dart transport.
#[repr(i32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ErrorCode {
    Ok = 0,
    InvalidCode = 1,
    UnsupportedProtocol = 2,
    AuthenticationFailed = 3,
    MemberRevoked = 4,
    PrimaryUnavailable = 5,
    FrameTooLarge = 6,
    InvalidChange = 7,
    CursorInvalid = 8,
    TransportUnavailable = 9,
    InvalidArgument = 10,
    EndpointClosed = 11,
    BufferTooSmall = 12,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum P2pError {
    InvalidCode,
    UnsupportedProtocol,
    AuthenticationFailed,
    MemberRevoked,
    PrimaryUnavailable,
    FrameTooLarge,
    InvalidChange,
    CursorInvalid,
    TransportUnavailable,
    Transport(String),
    InvalidArgument(&'static str),
    EndpointClosed,
    BufferTooSmall,
}

impl P2pError {
    pub const fn code(&self) -> ErrorCode {
        match self {
            Self::InvalidCode => ErrorCode::InvalidCode,
            Self::UnsupportedProtocol => ErrorCode::UnsupportedProtocol,
            Self::AuthenticationFailed => ErrorCode::AuthenticationFailed,
            Self::MemberRevoked => ErrorCode::MemberRevoked,
            Self::PrimaryUnavailable => ErrorCode::PrimaryUnavailable,
            Self::FrameTooLarge => ErrorCode::FrameTooLarge,
            Self::InvalidChange => ErrorCode::InvalidChange,
            Self::CursorInvalid => ErrorCode::CursorInvalid,
            Self::TransportUnavailable => ErrorCode::TransportUnavailable,
            Self::Transport(_) => ErrorCode::TransportUnavailable,
            Self::InvalidArgument(_) => ErrorCode::InvalidArgument,
            Self::EndpointClosed => ErrorCode::EndpointClosed,
            Self::BufferTooSmall => ErrorCode::BufferTooSmall,
        }
    }
}

impl fmt::Display for P2pError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidArgument(message) => formatter.write_str(message),
            Self::Transport(message) => formatter.write_str(message),
            _ => formatter.write_str(match self.code() {
                ErrorCode::InvalidCode => "invalid_code",
                ErrorCode::UnsupportedProtocol => "unsupported_protocol",
                ErrorCode::AuthenticationFailed => "authentication_failed",
                ErrorCode::MemberRevoked => "member_revoked",
                ErrorCode::PrimaryUnavailable => "primary_unavailable",
                ErrorCode::FrameTooLarge => "frame_too_large",
                ErrorCode::InvalidChange => "invalid_change",
                ErrorCode::CursorInvalid => "cursor_invalid",
                ErrorCode::TransportUnavailable => "transport_unavailable",
                ErrorCode::EndpointClosed => "endpoint_closed",
                ErrorCode::InvalidArgument => "invalid_argument",
                ErrorCode::BufferTooSmall => "buffer_too_small",
                ErrorCode::Ok => "ok",
            }),
        }
    }
}

impl P2pError {
    pub fn transport(error: impl fmt::Display) -> Self {
        Self::Transport(format!("{error:#}"))
    }
}

impl std::error::Error for P2pError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transport_errors_preserve_the_native_message() {
        let error = P2pError::transport("connection terminated during handshake");
        assert_eq!(error.code(), ErrorCode::TransportUnavailable);
        assert_eq!(error.to_string(), "connection terminated during handshake");
    }
}
