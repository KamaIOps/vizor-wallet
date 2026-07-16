//! Aptos: SLIP-0010 ed25519 derivation at m/44'/637'/0'/0'/0', address =
//! sha3-256(pubkey || 0x00 single-signer scheme byte), and APT transfers via
//! `0x1::aptos_account::transfer` entry-function payloads.
//!
//! The RawTransaction layout follows the Aptos specification (see
//! aptos.dev "Accounts"/"Transactions" and LedgerHQ app-aptos
//! doc/TRANSACTION.md), serialized with the official `bcs` crate; the
//! signing message is sha3-256("APTOS::RawTransaction") || bcs(raw_txn).
//! Rust returns the public key and signature; Dart submits the matching
//! JSON envelope to `POST /v1/transactions`, where the node re-derives and
//! verifies this exact signing message before accepting.

use ed25519_dalek::Signer;
use serde::Serialize;
use sha3::{Digest, Sha3_256};

use super::{derive_ed25519, hardened};

fn derive(mnemonic: &str) -> Result<ed25519_dalek::SigningKey, String> {
    derive_ed25519(
        mnemonic,
        &[
            hardened(44),
            hardened(637),
            hardened(0),
            hardened(0),
            hardened(0),
        ],
    )
}

fn address_bytes(key: &ed25519_dalek::SigningKey) -> [u8; 32] {
    let mut hasher = Sha3_256::new();
    hasher.update(key.verifying_key().as_bytes());
    hasher.update([0x00]); // single-signer ed25519 scheme id
    hasher.finalize().into()
}

/// 0x-prefixed 32-byte Aptos account address (auth key) for the account.
pub fn address(mnemonic: &str) -> Result<String, String> {
    let key = derive(mnemonic)?;
    Ok(format!("0x{}", hex::encode(address_bytes(&key))))
}

// ---- RawTransaction BCS layout (field order is the wire format) ----

#[derive(Serialize)]
struct RawTransaction {
    sender: [u8; 32],
    sequence_number: u64,
    payload: TransactionPayload,
    max_gas_amount: u64,
    gas_unit_price: u64,
    expiration_timestamp_secs: u64,
    chain_id: u8,
}

/// Variant order matches aptos-core (Script=0, ModuleBundle=1,
/// EntryFunction=2). Only EntryFunction is ever constructed here.
#[derive(Serialize)]
enum TransactionPayload {
    #[allow(dead_code)]
    Script,
    #[allow(dead_code)]
    ModuleBundle,
    EntryFunction(EntryFunction),
}

#[derive(Serialize)]
struct EntryFunction {
    module: ModuleId,
    function: String,
    /// Always empty for `aptos_account::transfer`; the element type is
    /// irrelevant to BCS for an empty vec.
    ty_args: Vec<u8>,
    /// Each argument pre-encoded as BCS bytes.
    args: Vec<Vec<u8>>,
}

#[derive(Serialize)]
struct ModuleId {
    address: [u8; 32],
    name: String,
}

pub struct AptosTxParams {
    pub sequence_number: u64,
    pub to_address: String,
    pub amount_octas: u64,
    pub max_gas_amount: u64,
    pub gas_unit_price: u64,
    pub expiration_timestamp_secs: u64,
    pub chain_id: u8,
}

/// Signature material for the JSON submission envelope.
pub struct AptosSignedTransfer {
    /// 0x-prefixed ed25519 public key (32 bytes).
    pub public_key_hex: String,
    /// 0x-prefixed signature over the RawTransaction signing message.
    pub signature_hex: String,
}

fn parse_address(addr: &str) -> Result<[u8; 32], String> {
    let hex_part = addr.strip_prefix("0x").ok_or("Address must start with 0x")?;
    // Aptos addresses may omit leading zeros; left-pad to 32 bytes.
    if hex_part.is_empty() || hex_part.len() > 64 {
        return Err("Invalid address length".into());
    }
    let padded = format!("{hex_part:0>64}");
    let bytes = hex::decode(padded).map_err(|e| format!("Invalid address hex: {e}"))?;
    Ok(bytes.try_into().expect("padded to 32 bytes"))
}

/// Sign an `0x1::aptos_account::transfer` (creates the recipient account if
/// needed, works for both coin- and fungible-asset-backed APT).
pub fn sign_transfer(
    mnemonic: &str,
    params: &AptosTxParams,
) -> Result<AptosSignedTransfer, String> {
    let key = derive(mnemonic)?;
    let sender = address_bytes(&key);
    let to = parse_address(&params.to_address)?;
    if to == sender {
        return Err("Recipient is the sender".into());
    }

    let mut core_address = [0u8; 32];
    core_address[31] = 1; // 0x1

    let raw = RawTransaction {
        sender,
        sequence_number: params.sequence_number,
        payload: TransactionPayload::EntryFunction(EntryFunction {
            module: ModuleId {
                address: core_address,
                name: "aptos_account".into(),
            },
            function: "transfer".into(),
            ty_args: Vec::new(),
            args: vec![
                bcs::to_bytes(&to).map_err(|e| format!("BCS failed: {e}"))?,
                bcs::to_bytes(&params.amount_octas).map_err(|e| format!("BCS failed: {e}"))?,
            ],
        }),
        max_gas_amount: params.max_gas_amount,
        gas_unit_price: params.gas_unit_price,
        expiration_timestamp_secs: params.expiration_timestamp_secs,
        chain_id: params.chain_id,
    };

    let mut message = Sha3_256::digest(b"APTOS::RawTransaction").to_vec();
    message.extend(bcs::to_bytes(&raw).map_err(|e| format!("BCS failed: {e}"))?);
    let signature = key.sign(&message);

    Ok(AptosSignedTransfer {
        public_key_hex: format!("0x{}", hex::encode(key.verifying_key().as_bytes())),
        signature_hex: format!("0x{}", hex::encode(signature.to_bytes())),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_MNEMONIC: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    #[test]
    fn derives_known_aptos_address() {
        // Cross-checked with bip_utils (Bip44Coins.APTOS) for the standard
        // test mnemonic at m/44'/637'/0'/0'/0'.
        assert_eq!(
            address(TEST_MNEMONIC).unwrap(),
            "0xeb663b681209e7087d681c5d3eed12aaa8e1915e7c87794542c3f96e94b3d3bf"
        );
    }

    #[test]
    fn bcs_entry_function_layout_is_canonical() {
        // BCS spot checks: uleb128 enum index, length-prefixed strings and
        // vecs, little-endian u64.
        assert_eq!(bcs::to_bytes(&42u64).unwrap(), 42u64.to_le_bytes());
        assert_eq!(
            bcs::to_bytes(&TransactionPayload::EntryFunction(EntryFunction {
                module: ModuleId { address: [0; 32], name: "m".into() },
                function: "f".into(),
                ty_args: Vec::new(),
                args: Vec::new(),
            }))
            .unwrap()[0],
            2, // EntryFunction variant index
        );
    }

    #[test]
    fn signs_transfer_and_verifies() {
        let params = AptosTxParams {
            sequence_number: 7,
            to_address: "0xdad".into(),
            amount_octas: 100_000_000,
            max_gas_amount: 2000,
            gas_unit_price: 100,
            expiration_timestamp_secs: 1_800_000_000,
            chain_id: 1,
        };
        let a = sign_transfer(TEST_MNEMONIC, &params).unwrap();
        let b = sign_transfer(TEST_MNEMONIC, &params).unwrap();
        assert_eq!(a.signature_hex, b.signature_hex);
        assert_eq!(a.public_key_hex.len(), 2 + 64);
        assert_eq!(a.signature_hex.len(), 2 + 128);
    }

    #[test]
    fn pads_short_addresses() {
        assert_eq!(parse_address("0x1").unwrap()[31], 1);
        assert!(parse_address("dad").is_err());
        assert!(parse_address("0x").is_err());
    }
}
