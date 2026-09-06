use crate::error::P2pError;

pub const PROTOCOL_VERSION: u16 = 1;
pub const MAX_FRAME_BYTES: usize = 1024 * 1024;
const HEADER_BYTES: usize = 10;
const MAGIC: [u8; 2] = *b"EC";

#[repr(u8)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FrameKind {
    Hello = 1,
    AuthChallenge = 2,
    AuthResponse = 3,
    Push = 4,
    PushResult = 5,
    Pull = 6,
    PullResult = 7,
    ChangesAvailable = 8,
    Error = 255,
}

impl TryFrom<u8> for FrameKind {
    type Error = P2pError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::Hello),
            2 => Ok(Self::AuthChallenge),
            3 => Ok(Self::AuthResponse),
            4 => Ok(Self::Push),
            5 => Ok(Self::PushResult),
            6 => Ok(Self::Pull),
            7 => Ok(Self::PullResult),
            8 => Ok(Self::ChangesAvailable),
            255 => Ok(Self::Error),
            _ => Err(P2pError::InvalidCode),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Frame {
    pub kind: FrameKind,
    pub payload: Vec<u8>,
}

impl Frame {
    pub fn new(kind: FrameKind, payload: Vec<u8>) -> Result<Self, P2pError> {
        if payload.len() > MAX_FRAME_BYTES - HEADER_BYTES {
            return Err(P2pError::FrameTooLarge);
        }
        Ok(Self { kind, payload })
    }

    /// Encodes one complete length-delimited frame for a QUIC stream.
    pub fn encode(&self) -> Vec<u8> {
        let mut encoded = Vec::with_capacity(HEADER_BYTES + self.payload.len());
        encoded.extend_from_slice(&MAGIC);
        encoded.extend_from_slice(&PROTOCOL_VERSION.to_be_bytes());
        encoded.push(self.kind as u8);
        encoded.push(0);
        encoded.extend_from_slice(&(self.payload.len() as u32).to_be_bytes());
        encoded.extend_from_slice(&self.payload);
        encoded
    }

    pub fn decode(encoded: &[u8]) -> Result<Self, P2pError> {
        if encoded.len() < HEADER_BYTES {
            return Err(P2pError::InvalidCode);
        }
        if encoded[0..2] != MAGIC {
            return Err(P2pError::InvalidCode);
        }
        let version = u16::from_be_bytes([encoded[2], encoded[3]]);
        if version != PROTOCOL_VERSION {
            return Err(P2pError::UnsupportedProtocol);
        }
        if encoded[5] != 0 {
            return Err(P2pError::InvalidCode);
        }
        let payload_len = u32::from_be_bytes([
            encoded[6], encoded[7], encoded[8], encoded[9],
        ]) as usize;
        if payload_len > MAX_FRAME_BYTES - HEADER_BYTES {
            return Err(P2pError::FrameTooLarge);
        }
        if encoded.len() != HEADER_BYTES + payload_len {
            return Err(P2pError::InvalidCode);
        }
        Frame::new(FrameKind::try_from(encoded[4])?, encoded[HEADER_BYTES..].to_vec())
    }
}

pub fn validate_frame(kind: u8, payload_len: usize) -> Result<(), P2pError> {
    FrameKind::try_from(kind)?;
    if payload_len > MAX_FRAME_BYTES - HEADER_BYTES {
        return Err(P2pError::FrameTooLarge);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_round_trip_preserves_kind_and_payload() {
        let frame = Frame::new(FrameKind::Push, b"payload".to_vec()).unwrap();
        assert_eq!(Frame::decode(&frame.encode()).unwrap(), frame);
    }

    #[test]
    fn frame_rejects_wrong_version_and_trailing_bytes() {
        let frame = Frame::new(FrameKind::Pull, vec![]).unwrap();
        let mut encoded = frame.encode();
        encoded[3] = 2;
        assert_eq!(Frame::decode(&encoded), Err(P2pError::UnsupportedProtocol));
        let mut encoded = frame.encode();
        encoded.push(1);
        assert_eq!(Frame::decode(&encoded), Err(P2pError::InvalidCode));
    }
}
