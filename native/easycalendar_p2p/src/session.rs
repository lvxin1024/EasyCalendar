use iroh::endpoint::{Connection, RecvStream, SendStream};

use crate::error::P2pError;
use crate::protocol::{Frame, MAX_FRAME_BYTES};

const HEADER_BYTES: usize = 10;

/// Writes exactly one protocol frame to a QUIC bidirectional stream.
pub async fn send_frame(stream: &mut SendStream, frame: &Frame) -> Result<(), P2pError> {
    stream
        .write_all(&frame.encode())
        .await
        .map_err(P2pError::transport)?;
    stream.finish().map_err(P2pError::transport)
}

/// Reads exactly one bounded protocol frame from a QUIC bidirectional stream.
pub async fn receive_frame(stream: &mut RecvStream) -> Result<Frame, P2pError> {
    let mut header = [0_u8; HEADER_BYTES];
    stream
        .read_exact(&mut header)
        .await
        .map_err(P2pError::transport)?;
    let payload_len = u32::from_be_bytes([header[6], header[7], header[8], header[9]]) as usize;
    if payload_len > MAX_FRAME_BYTES - HEADER_BYTES {
        return Err(P2pError::FrameTooLarge);
    }
    let mut encoded = Vec::with_capacity(HEADER_BYTES + payload_len);
    encoded.extend_from_slice(&header);
    encoded.resize(HEADER_BYTES + payload_len, 0);
    stream
        .read_exact(&mut encoded[HEADER_BYTES..])
        .await
        .map_err(P2pError::transport)?;
    Frame::decode(&encoded)
}

/// Performs one request/response exchange on a fresh bidirectional stream.
pub async fn request(connection: &Connection, frame: Frame) -> Result<Frame, P2pError> {
    let (mut send, mut receive) = connection
        .open_bi()
        .await
        .map_err(P2pError::transport)?;
    send_frame(&mut send, &frame).await?;
    receive_frame(&mut receive).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::FrameKind;

    #[test]
    fn receive_frame_rejects_payloads_above_the_wire_limit() {
        let mut encoded = vec![0_u8; HEADER_BYTES];
        encoded[0..2].copy_from_slice(b"EC");
        encoded[2..4].copy_from_slice(&1_u16.to_be_bytes());
        encoded[4] = FrameKind::Push as u8;
        encoded[6..10]
            .copy_from_slice(&((MAX_FRAME_BYTES - HEADER_BYTES + 1) as u32).to_be_bytes());
        assert_eq!(encoded.len(), HEADER_BYTES);
    }
}
