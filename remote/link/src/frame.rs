//! One sealed body, the same shape `lib/oclink.lua` builds with the data card,
//! and the length-and-channel framing around it.
//!
//! ```text
//! body = iv[16] .. aes_128_cbc_pkcs7(key, iv, text) .. hmac_sha256(mac, iv .. ct)[..16]
//! ```
//!
//! Keys come from a shared secret. A session is keyed off a nonce, so a
//! recorded frame verifies against nothing later.

use aes::cipher::{block_padding::Pkcs7, BlockDecryptMut, BlockEncryptMut, KeyIvInit};
use anyhow::{Context, Result};
use hmac::{Hmac, Mac};
use rand::RngCore;
use sha2::{Digest, Sha256};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

type Encryptor = cbc::Encryptor<aes::Aes128>;
type Decryptor = cbc::Decryptor<aes::Aes128>;
type HmacSha256 = Hmac<Sha256>;

/// the longest frame a length prefix can name, channel byte included
pub const MAX_FRAME: usize = 65535;
const IV: usize = 16;
const TAG: usize = 16;

#[derive(Clone)]
pub struct Keys {
    pub enc: [u8; 16],
    pub mac: [u8; 32],
}

fn sha256(parts: &[&[u8]]) -> [u8; 32] {
    let mut hasher = Sha256::new();
    for part in parts {
        hasher.update(part);
    }
    hasher.finalize().into()
}

impl Keys {
    pub fn from_secret(secret: &[u8]) -> Keys {
        let enc = sha256(&[secret, b"\0enc"]);
        Keys {
            enc: enc[..16].try_into().expect("16 of 32"),
            mac: sha256(&[secret, b"\0mac"]),
        }
    }

    pub fn session(&self, nonce: &[u8]) -> Keys {
        let enc = sha256(&[&self.enc, nonce]);
        Keys {
            enc: enc[..16].try_into().expect("16 of 32"),
            mac: sha256(&[&self.mac, nonce]),
        }
    }
}

fn tag(mac: &[u8; 32], iv_and_ct: &[u8]) -> [u8; TAG] {
    let mut hmac = HmacSha256::new_from_slice(mac).expect("any key length");
    hmac.update(iv_and_ct);
    let full = hmac.finalize().into_bytes();
    full[..TAG].try_into().expect("16 of 32")
}

#[derive(Debug)]
pub enum FrameError {
    TooLong,
    Short,
    BadTag,
    BadPadding,
}

impl std::fmt::Display for FrameError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FrameError::TooLong => write!(f, "message too long to frame"),
            FrameError::Short => write!(f, "short frame"),
            FrameError::BadTag => write!(f, "bad tag"),
            FrameError::BadPadding => write!(f, "will not decrypt"),
        }
    }
}

impl std::error::Error for FrameError {}

/// A sealed body, without the length or the channel in front.
pub fn seal(keys: &Keys, text: &[u8]) -> Vec<u8> {
    let mut iv = [0u8; IV];
    rand::thread_rng().fill_bytes(&mut iv);
    let sealed = Encryptor::new(&keys.enc.into(), &iv.into()).encrypt_padded_vec_mut::<Pkcs7>(text);
    let mut body = Vec::with_capacity(IV + sealed.len() + TAG);
    body.extend_from_slice(&iv);
    body.extend_from_slice(&sealed);
    let tag = tag(&keys.mac, &body);
    body.extend_from_slice(&tag);
    body
}

/// The text inside one sealed body.
pub fn open(keys: &Keys, body: &[u8]) -> Result<Vec<u8>, FrameError> {
    if body.len() < IV + 16 + TAG {
        return Err(FrameError::Short);
    }
    let (iv_and_ct, given) = body.split_at(body.len() - TAG);
    if tag(&keys.mac, iv_and_ct) != given {
        return Err(FrameError::BadTag);
    }
    let (iv, ct) = iv_and_ct.split_at(IV);
    let iv: [u8; IV] = iv.try_into().expect("split at 16");
    Decryptor::new(&keys.enc.into(), &iv.into())
        .decrypt_padded_vec_mut::<Pkcs7>(ct)
        .map_err(|_| FrameError::BadPadding)
}

/// A whole frame as it goes on the wire.
pub fn frame(channel: u8, body: &[u8]) -> Result<Vec<u8>, FrameError> {
    if body.len() + 1 > MAX_FRAME {
        return Err(FrameError::TooLong);
    }
    let mut out = Vec::with_capacity(3 + body.len());
    out.extend_from_slice(&((body.len() + 1) as u16).to_be_bytes());
    out.push(channel);
    out.extend_from_slice(body);
    Ok(out)
}

pub async fn read_frame<R: AsyncRead + Unpin>(reader: &mut R) -> Result<(u8, Vec<u8>)> {
    let mut length = [0u8; 2];
    reader
        .read_exact(&mut length)
        .await
        .context("reading a frame length")?;
    let length = u16::from_be_bytes(length) as usize;
    if length == 0 {
        anyhow::bail!("empty frame");
    }
    let mut rest = vec![0u8; length];
    reader
        .read_exact(&mut rest)
        .await
        .context("reading a frame body")?;
    let channel = rest[0];
    rest.remove(0);
    Ok((channel, rest))
}

pub async fn write_frame<W: AsyncWrite + Unpin>(
    writer: &mut W,
    channel: u8,
    body: &[u8],
) -> Result<()> {
    let frame = frame(channel, body)?;
    writer.write_all(&frame).await.context("writing a frame")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_body_opens_under_the_same_keys_only() {
        let keys = Keys::from_secret(b"a shared secret");
        let body = seal(&keys, b"hello there");
        assert_eq!(open(&keys, &body).unwrap(), b"hello there");

        let other = Keys::from_secret(b"some other secret");
        assert!(matches!(open(&other, &body), Err(FrameError::BadTag)));

        let mut forged = body.clone();
        forged[20] ^= 1;
        assert!(open(&keys, &forged).is_err());
    }

    #[test]
    fn a_frame_names_its_length_and_channel() {
        let frame = frame(1, b"abc").unwrap();
        assert_eq!(frame, vec![0, 4, 1, b'a', b'b', b'c']);
    }

    #[test]
    fn session_keys_differ_by_nonce() {
        let keys = Keys::from_secret(b"s");
        assert_ne!(keys.session(b"one").enc, keys.session(b"two").enc);
        assert_ne!(keys.session(b"one").mac, keys.mac);
    }

    /// Values read off a real data card, so the card and this crate are known
    /// to agree on the cipher and the HMAC.
    #[test]
    fn matches_the_data_card() {
        let key: [u8; 16] = *b"0123456789abcdef";
        let iv: [u8; 16] = *b"fedcba9876543210";
        let ct =
            Encryptor::new(&key.into(), &iv.into()).encrypt_padded_vec_mut::<Pkcs7>(b"hello there");
        assert_eq!(crate::hex(&ct), "d3b1273b643679ce3989adcda41661db");
        let ct = Encryptor::new(&key.into(), &iv.into())
            .encrypt_padded_vec_mut::<Pkcs7>(b"0123456789abcdef");
        assert_eq!(
            crate::hex(&ct),
            "6575cf6b37479d9215337ff9767fe7866673e70d7e0bf17498019ee1bc7b945f"
        );

        let mut hmac = HmacSha256::new_from_slice(b"key").unwrap();
        hmac.update(b"abc");
        assert_eq!(
            crate::hex(&hmac.finalize().into_bytes()),
            "9c196e32dc0175f86f4b1cb89289d6619de6bee699e4c378e68309ed97a1a6ab"
        );
    }
}
