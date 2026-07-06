//! Solana: SLIP-0010 ed25519 derivation and system-program transfer signing.
//!
//! Keplr has no Solana support, so conventions here follow the de-facto
//! standard set by Phantom/Solflare: path m/44'/501'/0'/0' (hardened-only),
//! address = base58 of the 32-byte ed25519 public key, legacy (non-versioned)
//! transaction message format.

use base64::Engine;
use ed25519_dalek::Signer;

use super::{derive_ed25519, hardened};

const SYSTEM_PROGRAM_ID: [u8; 32] = [0u8; 32];
/// System program "transfer" instruction discriminant (u32 LE).
const TRANSFER_INSTRUCTION: u32 = 2;

fn derive(mnemonic: &str) -> Result<ed25519_dalek::SigningKey, String> {
    derive_ed25519(
        mnemonic,
        &[hardened(44), hardened(501), hardened(0), hardened(0)],
    )
}

/// Base58 account address.
pub fn address(mnemonic: &str) -> Result<String, String> {
    let key = derive(mnemonic)?;
    Ok(bs58::encode(key.verifying_key().to_bytes()).into_string())
}

pub struct SolTxParams {
    /// Base58 recent blockhash from `getLatestBlockhash`.
    pub recent_blockhash: String,
    pub to_address: String,
    pub lamports: u64,
}

/// Sign a system-program transfer. Returns base64 tx for `sendTransaction`.
pub fn sign_transfer(mnemonic: &str, params: &SolTxParams) -> Result<String, String> {
    let key = derive(mnemonic)?;
    let from = key.verifying_key().to_bytes();
    let to = decode_pubkey(&params.to_address, "recipient")?;
    let blockhash = decode_pubkey(&params.recent_blockhash, "blockhash")?;
    if to == from {
        return Err("Recipient is the sender address".into());
    }

    // Legacy message: header, account keys, blockhash, instructions.
    let mut message = Vec::new();
    message.push(1); // num_required_signatures
    message.push(0); // num_readonly_signed_accounts
    message.push(1); // num_readonly_unsigned_accounts (system program)

    shortvec_len(&mut message, 3);
    message.extend_from_slice(&from);
    message.extend_from_slice(&to);
    message.extend_from_slice(&SYSTEM_PROGRAM_ID);

    message.extend_from_slice(&blockhash);

    shortvec_len(&mut message, 1); // one instruction
    message.push(2); // program_id_index → system program
    shortvec_len(&mut message, 2); // two accounts
    message.push(0); // from
    message.push(1); // to
    let mut data = Vec::with_capacity(12);
    data.extend_from_slice(&TRANSFER_INSTRUCTION.to_le_bytes());
    data.extend_from_slice(&params.lamports.to_le_bytes());
    shortvec_len(&mut message, data.len() as u16);
    message.extend_from_slice(&data);

    let signature = key.sign(&message);

    let mut tx = Vec::with_capacity(1 + 64 + message.len());
    shortvec_len(&mut tx, 1); // one signature
    tx.extend_from_slice(&signature.to_bytes());
    tx.extend_from_slice(&message);

    Ok(base64::engine::general_purpose::STANDARD.encode(tx))
}

fn decode_pubkey(b58: &str, what: &str) -> Result<[u8; 32], String> {
    let bytes = bs58::decode(b58)
        .into_vec()
        .map_err(|e| format!("Invalid {what}: {e}"))?;
    <[u8; 32]>::try_from(bytes.as_slice()).map_err(|_| format!("Invalid {what}: must be 32 bytes"))
}

/// Solana "shortvec" (compact-u16) length encoding.
fn shortvec_len(buf: &mut Vec<u8>, mut v: u16) {
    loop {
        let byte = (v & 0x7f) as u8;
        v >>= 7;
        if v == 0 {
            buf.push(byte);
            return;
        }
        buf.push(byte | 0x80);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::Verifier;

    const TEST_MNEMONIC: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    #[test]
    fn derives_valid_base58_address() {
        let addr = address(TEST_MNEMONIC).unwrap();
        let decoded = bs58::decode(&addr).into_vec().unwrap();
        assert_eq!(decoded.len(), 32);
        assert_eq!(addr, address(TEST_MNEMONIC).unwrap());
    }

    #[test]
    fn signed_transfer_verifies() {
        let params = SolTxParams {
            // 32 bytes of 0x01 in base58 — a syntactically valid blockhash.
            recent_blockhash: bs58::encode([1u8; 32]).into_string(),
            to_address: bs58::encode([2u8; 32]).into_string(),
            lamports: 1_000_000,
        };
        let tx_b64 = sign_transfer(TEST_MNEMONIC, &params).unwrap();
        let tx = base64::engine::general_purpose::STANDARD.decode(tx_b64).unwrap();

        // Layout: shortvec(1) + 64-byte sig + message.
        assert_eq!(tx[0], 1);
        let sig = ed25519_dalek::Signature::from_bytes(tx[1..65].try_into().unwrap());
        let message = &tx[65..];
        let key = derive(TEST_MNEMONIC).unwrap();
        key.verifying_key().verify(message, &sig).expect("signature must verify");

        // Message header and account count.
        assert_eq!(&message[..3], &[1, 0, 1]);
        assert_eq!(message[3], 3);
    }

    #[test]
    fn shortvec_matches_known_encodings() {
        for (value, expected) in [(0u16, vec![0u8]), (127, vec![0x7f]), (128, vec![0x80, 0x01]), (300, vec![0xac, 0x02])] {
            let mut buf = Vec::new();
            shortvec_len(&mut buf, value);
            assert_eq!(buf, expected, "value {value}");
        }
    }

    #[test]
    fn rejects_self_send_and_bad_keys() {
        let self_addr = address(TEST_MNEMONIC).unwrap();
        let params = SolTxParams {
            recent_blockhash: bs58::encode([1u8; 32]).into_string(),
            to_address: self_addr,
            lamports: 1,
        };
        assert!(sign_transfer(TEST_MNEMONIC, &params).is_err());
        assert!(decode_pubkey("not-base58!", "x").is_err());
    }
}
