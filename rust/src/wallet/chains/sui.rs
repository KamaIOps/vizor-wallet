//! Sui: SLIP-0010 ed25519 derivation at m/44'/784'/0'/0'/0', address =
//! blake2b-256(0x00 flag || pubkey), and SUI transfers as programmable
//! transaction blocks (SplitCoins from gas + TransferObjects).
//!
//! Transaction construction and intent signing are delegated to Mysten's
//! sui-sdk-types / sui-crypto / sui-transaction-builder crates — the BCS
//! layout of TransactionData and the signing intent are theirs, not
//! hand-rolled. Dart owns networking: it supplies gas coin references and
//! broadcasts via `sui_executeTransactionBlock`.

use std::str::FromStr;

use base64::Engine;
use sui_crypto::ed25519::Ed25519PrivateKey;
use sui_crypto::SuiSigner;
use sui_sdk_types::{Address, Digest};
use sui_transaction_builder::{ObjectInput, TransactionBuilder};

use super::{derive_ed25519, hardened};

fn derive(mnemonic: &str) -> Result<Ed25519PrivateKey, String> {
    let key = derive_ed25519(
        mnemonic,
        &[
            hardened(44),
            hardened(784),
            hardened(0),
            hardened(0),
            hardened(0),
        ],
    )?;
    Ok(Ed25519PrivateKey::new(key.to_bytes()))
}

/// 0x-prefixed 32-byte Sui address for the account.
pub fn address(mnemonic: &str) -> Result<String, String> {
    Ok(derive(mnemonic)?.public_key().derive_address().to_string())
}

/// An owned coin object usable as gas payment (from `suix_getCoins`).
pub struct SuiGasObject {
    pub object_id: String,
    pub version: u64,
    /// Base58 object digest.
    pub digest: String,
}

pub struct SuiTxParams {
    pub recipient: String,
    pub amount_mist: u64,
    pub gas_budget: u64,
    pub gas_price: u64,
    pub gas_objects: Vec<SuiGasObject>,
}

/// The signed transfer, ready for `sui_executeTransactionBlock`.
pub struct SuiSignedTransfer {
    /// base64(bcs(TransactionData))
    pub tx_bytes_base64: String,
    /// base64(flag || sig || pubkey)
    pub signature_base64: String,
}

/// Build and sign a SUI transfer PTB. Gas coins are smashed into the gas
/// object, the amount is split off it and transferred, so the same coins can
/// fund both the transfer and gas.
pub fn sign_transfer(mnemonic: &str, params: &SuiTxParams) -> Result<SuiSignedTransfer, String> {
    if params.gas_objects.is_empty() {
        return Err("No gas coins provided".into());
    }
    let key = derive(mnemonic)?;
    let sender = key.public_key().derive_address();
    let recipient = Address::from_str(&params.recipient)
        .map_err(|e| format!("Invalid recipient address: {e}"))?;
    if recipient == sender {
        return Err("Recipient is the sender".into());
    }

    let mut tx = TransactionBuilder::new();
    let amount = tx.pure(&params.amount_mist);
    let gas = tx.gas();
    let coins = tx.split_coins(gas, vec![amount]);
    let recipient_arg = tx.pure(&recipient);
    tx.transfer_objects(coins, recipient_arg);
    tx.set_sender(sender);
    tx.set_gas_budget(params.gas_budget);
    tx.set_gas_price(params.gas_price);
    for gas_object in &params.gas_objects {
        let id = Address::from_str(&gas_object.object_id)
            .map_err(|e| format!("Invalid gas object id: {e}"))?;
        let digest = Digest::from_str(&gas_object.digest)
            .map_err(|e| format!("Invalid gas object digest: {e}"))?;
        tx.add_gas_objects([ObjectInput::owned(id, gas_object.version, digest)]);
    }

    let transaction = tx.try_build().map_err(|e| format!("PTB build failed: {e}"))?;
    let signature = key
        .sign_transaction(&transaction)
        .map_err(|e| format!("Signing failed: {e}"))?;
    let tx_bytes =
        bcs::to_bytes(&transaction).map_err(|e| format!("BCS serialization failed: {e}"))?;

    Ok(SuiSignedTransfer {
        tx_bytes_base64: base64::engine::general_purpose::STANDARD.encode(tx_bytes),
        signature_base64: signature.to_base64(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_MNEMONIC: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    #[test]
    fn derives_known_sui_address() {
        // Cross-checked with bip_utils (Bip44Coins.SUI) for the standard test
        // mnemonic at m/44'/784'/0'/0'/0'.
        assert_eq!(
            address(TEST_MNEMONIC).unwrap(),
            "0x5e93a736d04fbb25737aa40bee40171ef79f65fae833749e3c089fe7cc2161f1"
        );
    }

    #[test]
    fn signs_transfer_deterministically() {
        let params = SuiTxParams {
            recipient: "0x0000000000000000000000000000000000000000000000000000000000000dad"
                .into(),
            amount_mist: 1_000_000_000,
            gas_budget: 10_000_000,
            gas_price: 750,
            gas_objects: vec![SuiGasObject {
                object_id:
                    "0x0000000000000000000000000000000000000000000000000000000000000abc".into(),
                version: 42,
                digest: "11111111111111111111111111111111".into(),
            }],
        };
        let a = sign_transfer(TEST_MNEMONIC, &params).unwrap();
        let b = sign_transfer(TEST_MNEMONIC, &params).unwrap();
        assert_eq!(a.tx_bytes_base64, b.tx_bytes_base64);
        assert_eq!(a.signature_base64, b.signature_base64);
        // Ed25519 user signature: flag(0x00) || sig(64) || pubkey(32).
        let sig = base64::engine::general_purpose::STANDARD
            .decode(&a.signature_base64)
            .unwrap();
        assert_eq!(sig.len(), 97);
        assert_eq!(sig[0], 0x00);
    }

    #[test]
    fn rejects_bad_inputs() {
        let base = SuiTxParams {
            recipient: "0x0000000000000000000000000000000000000000000000000000000000000dad"
                .into(),
            amount_mist: 1,
            gas_budget: 10_000_000,
            gas_price: 750,
            gas_objects: vec![],
        };
        assert!(sign_transfer(TEST_MNEMONIC, &base).is_err()); // no gas coins
        let self_send = SuiTxParams {
            recipient: address(TEST_MNEMONIC).unwrap(),
            gas_objects: vec![SuiGasObject {
                object_id:
                    "0x0000000000000000000000000000000000000000000000000000000000000abc".into(),
                version: 1,
                digest: "11111111111111111111111111111111".into(),
            }],
            ..base
        };
        assert!(sign_transfer(TEST_MNEMONIC, &self_send).is_err());
    }
}
