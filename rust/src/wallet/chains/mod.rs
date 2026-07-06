//! Multichain (non-Zcash) key derivation and transaction signing.
//!
//! Vizor's multichain support derives BTC/ETH/Cosmos/SOL keys from the same
//! per-account BIP-39 mnemonic used for Zcash. All key material stays inside
//! Rust: Dart passes the mnemonic in (same pattern as Zcash signing), gets
//! addresses or signed transaction bytes back, and does the networking.
//!
//! Derivation here is implemented directly against `hmac`/`secp256k1`/
//! `ed25519-dalek` rather than the pre-release `bip32` crate:
//! - BIP-32 secp256k1 (BTC/ETH/Cosmos), validated against the BIP-32 and
//!   BIP-84 published test vectors.
//! - SLIP-0010 ed25519 (SOL, hardened-only), validated against the SLIP-0010
//!   published test vectors.

pub mod btc;
pub mod cosmos;
pub mod eth;
pub mod sol;

use hmac::{Hmac, Mac};
use secp256k1::{PublicKey, Scalar, Secp256k1, SecretKey};
use secrecy::ExposeSecret;
use sha2::{Digest, Sha256, Sha512};
use zeroize::Zeroizing;

use crate::wallet::keys::mnemonic_to_seed;

const HARDENED: u32 = 0x8000_0000;

/// A derived secp256k1 key pair. The secret is zeroized on drop.
pub(crate) struct Secp256k1Key {
    pub secret: SecretKey,
    pub public: PublicKey,
}

/// BIP-32 CKDpriv over an absolute path from a BIP-39 mnemonic.
/// `path` entries with bit 31 set are hardened.
pub(crate) fn derive_secp256k1(mnemonic: &str, path: &[u32]) -> Result<Secp256k1Key, String> {
    let seed = mnemonic_to_seed(mnemonic)?;
    let secp = Secp256k1::new();

    let i = hmac_sha512(b"Bitcoin seed", seed.expose_secret());
    let mut key = Zeroizing::new(<[u8; 32]>::try_from(&i[..32]).expect("hmac output"));
    let mut chain_code = <[u8; 32]>::try_from(&i[32..]).expect("hmac output");

    let mut secret =
        SecretKey::from_slice(&key[..]).map_err(|e| format!("Invalid master key: {e}"))?;

    for &index in path {
        let mut data = Vec::with_capacity(37);
        if index >= HARDENED {
            data.push(0);
            data.extend_from_slice(&key[..]);
        } else {
            let parent_pub = PublicKey::from_secret_key(&secp, &secret);
            data.extend_from_slice(&parent_pub.serialize());
        }
        data.extend_from_slice(&index.to_be_bytes());

        let i = hmac_sha512(&chain_code, &data);
        let il = Zeroizing::new(<[u8; 32]>::try_from(&i[..32]).expect("hmac output"));
        chain_code = <[u8; 32]>::try_from(&i[32..]).expect("hmac output");

        let tweak = Scalar::from_be_bytes(*il)
            .map_err(|_| "BIP-32 derivation produced invalid tweak".to_string())?;
        secret = secret
            .add_tweak(&tweak)
            .map_err(|_| "BIP-32 derivation produced invalid child key".to_string())?;
        *key = secret.secret_bytes();
    }

    let public = PublicKey::from_secret_key(&secp, &secret);
    Ok(Secp256k1Key { secret, public })
}

/// SLIP-0010 ed25519 derivation (hardened-only path) from a BIP-39 mnemonic.
pub(crate) fn derive_ed25519(
    mnemonic: &str,
    path: &[u32],
) -> Result<ed25519_dalek::SigningKey, String> {
    let seed = mnemonic_to_seed(mnemonic)?;

    let i = hmac_sha512(b"ed25519 seed", seed.expose_secret());
    let mut key = Zeroizing::new(<[u8; 32]>::try_from(&i[..32]).expect("hmac output"));
    let mut chain_code = <[u8; 32]>::try_from(&i[32..]).expect("hmac output");

    for &index in path {
        if index < HARDENED {
            return Err("SLIP-0010 ed25519 supports hardened derivation only".into());
        }
        let mut data = Vec::with_capacity(37);
        data.push(0);
        data.extend_from_slice(&key[..]);
        data.extend_from_slice(&index.to_be_bytes());

        let i = hmac_sha512(&chain_code, &data);
        *key = <[u8; 32]>::try_from(&i[..32]).expect("hmac output");
        chain_code = <[u8; 32]>::try_from(&i[32..]).expect("hmac output");
    }

    Ok(ed25519_dalek::SigningKey::from_bytes(&key))
}

fn hmac_sha512(key: &[u8], data: &[u8]) -> [u8; 64] {
    let mut mac = Hmac::<Sha512>::new_from_slice(key).expect("hmac accepts any key length");
    mac.update(data);
    mac.finalize().into_bytes().into()
}

/// RIPEMD160(SHA256(data)) — shared by BTC and Cosmos address derivation.
pub(crate) fn hash160(data: &[u8]) -> [u8; 20] {
    use ripemd::Ripemd160;
    let sha = Sha256::digest(data);
    let mut out = [0u8; 20];
    out.copy_from_slice(&Ripemd160::digest(sha));
    out
}

pub(crate) fn hardened(i: u32) -> u32 {
    HARDENED | i
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Standard BIP-39 test mnemonic used by the BIP-84 spec vectors.
    pub(crate) const TEST_MNEMONIC: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    #[test]
    fn slip10_ed25519_vector_1() {
        // SLIP-0010 test vector 1 (ed25519), seed 000102030405060708090a0b0c0d0e0f.
        // Derivation here starts from a seed, not a mnemonic, so exercise the
        // inner loop directly.
        let seed = hex::decode("000102030405060708090a0b0c0d0e0f").unwrap();
        let i = hmac_sha512(b"ed25519 seed", &seed);
        assert_eq!(
            hex::encode(&i[..32]),
            "2b4be7f19ee27bbf30c667b642d5f4aa69fd169872f8fc3059c08ebae2eb19e7"
        );
        assert_eq!(
            hex::encode(&i[32..]),
            "90046a93de5380a72b5e45010748567d5ea02bbf6522f979e05c0d8d8ca9fffb"
        );

        // m/0' child.
        let mut data = vec![0u8];
        data.extend_from_slice(&i[..32]);
        data.extend_from_slice(&hardened(0).to_be_bytes());
        let child = hmac_sha512(&i[32..], &data);
        assert_eq!(
            hex::encode(&child[..32]),
            "68e0fe46dfb67e368c75379acec591dad19df3cde26e63b93a8e704f1dade7a3"
        );
    }

    #[test]
    fn bip32_master_key_vector_1() {
        // BIP-32 test vector 1, seed 000102030405060708090a0b0c0d0e0f.
        let seed = hex::decode("000102030405060708090a0b0c0d0e0f").unwrap();
        let i = hmac_sha512(b"Bitcoin seed", &seed);
        assert_eq!(
            hex::encode(&i[..32]),
            "e8f32e723decf4051aefac8e2c93c9c5b214313817cdb01a1494b917c8436b35"
        );
        assert_eq!(
            hex::encode(&i[32..]),
            "873dff81c02f525623fd1fe5167eac3a55a049de3d314bb42ee227ffed37d508"
        );
    }

    #[test]
    fn ed25519_full_path_is_deterministic() {
        let a = derive_ed25519(TEST_MNEMONIC, &[hardened(44), hardened(501), hardened(0), hardened(0)])
            .unwrap();
        let b = derive_ed25519(TEST_MNEMONIC, &[hardened(44), hardened(501), hardened(0), hardened(0)])
            .unwrap();
        assert_eq!(a.to_bytes(), b.to_bytes());
    }

    #[test]
    fn ed25519_rejects_non_hardened() {
        let err = derive_ed25519(TEST_MNEMONIC, &[44]).unwrap_err();
        assert!(err.contains("hardened"));
    }
}
