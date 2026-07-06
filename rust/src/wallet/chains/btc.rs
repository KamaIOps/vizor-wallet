//! Bitcoin: BIP-84 P2WPKH address derivation and transaction signing.
//!
//! Coin selection, fee calculation, and broadcast happen in Dart (Esplora
//! public endpoints); this module only derives the key, builds the
//! transaction from fully-specified inputs/outputs, and signs every input.
//! All inputs are assumed to be P2WPKH outputs of this account's single
//! derived key (index 0), which is the only address Vizor hands out for v1.

use std::str::FromStr;

use bitcoin::absolute::LockTime;
use bitcoin::hashes::Hash;
use bitcoin::sighash::{EcdsaSighashType, SighashCache};
use bitcoin::transaction::Version;
use bitcoin::{
    Address, Amount, CompressedPublicKey, Network, OutPoint, ScriptBuf, Sequence, Transaction,
    TxIn, TxOut, Txid, Witness,
};
use secp256k1::{Message, Secp256k1};

use super::{derive_secp256k1, hardened, Secp256k1Key};

fn derive(mnemonic: &str) -> Result<Secp256k1Key, String> {
    derive_secp256k1(mnemonic, &[hardened(84), hardened(0), hardened(0), 0, 0])
}

fn compressed(key: &Secp256k1Key) -> CompressedPublicKey {
    CompressedPublicKey(key.public)
}

/// Native segwit (bc1…) address for the account.
pub fn address(mnemonic: &str) -> Result<String, String> {
    let key = derive(mnemonic)?;
    Ok(Address::p2wpkh(&compressed(&key), Network::Bitcoin).to_string())
}

pub struct BtcUtxo {
    pub txid: String,
    pub vout: u32,
    pub value_sats: u64,
}

pub struct BtcTxParams {
    pub utxos: Vec<BtcUtxo>,
    pub to_address: String,
    pub amount_sats: u64,
    /// Change returned to our own address; omitted when the remainder is fee.
    pub change_sats: u64,
}

/// Build and sign a P2WPKH transaction. Returns raw tx hex for broadcast.
pub fn sign_transaction(mnemonic: &str, params: &BtcTxParams) -> Result<String, String> {
    if params.utxos.is_empty() {
        return Err("No inputs provided".into());
    }
    let key = derive(mnemonic)?;
    let our_pubkey = compressed(&key);
    let our_address = Address::p2wpkh(&our_pubkey, Network::Bitcoin);
    let our_script = our_address.script_pubkey();

    let total_in: u64 = params.utxos.iter().map(|u| u.value_sats).sum();
    let total_out = params
        .amount_sats
        .checked_add(params.change_sats)
        .ok_or("Output overflow")?;
    if total_out >= total_in {
        return Err("Outputs plus fee exceed inputs".into());
    }

    let to = Address::from_str(&params.to_address)
        .map_err(|e| format!("Invalid recipient address: {e}"))?
        .require_network(Network::Bitcoin)
        .map_err(|_| "Recipient address is not a mainnet address".to_string())?;

    let input = params
        .utxos
        .iter()
        .map(|u| {
            let txid = Txid::from_str(&u.txid).map_err(|e| format!("Invalid txid: {e}"))?;
            Ok(TxIn {
                previous_output: OutPoint { txid, vout: u.vout },
                script_sig: ScriptBuf::new(),
                sequence: Sequence::ENABLE_RBF_NO_LOCKTIME,
                witness: Witness::default(),
            })
        })
        .collect::<Result<Vec<_>, String>>()?;

    let mut output = vec![TxOut {
        value: Amount::from_sat(params.amount_sats),
        script_pubkey: to.script_pubkey(),
    }];
    if params.change_sats > 0 {
        output.push(TxOut {
            value: Amount::from_sat(params.change_sats),
            script_pubkey: our_script.clone(),
        });
    }

    let mut tx = Transaction {
        version: Version::TWO,
        lock_time: LockTime::ZERO,
        input,
        output,
    };

    let secp = Secp256k1::new();
    let mut cache = SighashCache::new(tx.clone());
    for (i, utxo) in params.utxos.iter().enumerate() {
        let sighash = cache
            .p2wpkh_signature_hash(
                i,
                &our_script,
                Amount::from_sat(utxo.value_sats),
                EcdsaSighashType::All,
            )
            .map_err(|e| format!("Sighash failed: {e}"))?;
        let msg = Message::from_digest(sighash.to_byte_array());
        let signature = bitcoin::ecdsa::Signature {
            signature: secp.sign_ecdsa(&msg, &key.secret),
            sighash_type: EcdsaSighashType::All,
        };
        tx.input[i].witness = Witness::p2wpkh(&signature, &key.public);
    }

    Ok(hex::encode(bitcoin::consensus::encode::serialize(&tx)))
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_MNEMONIC: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    #[test]
    fn derives_bip84_spec_address() {
        // First receiving address from the BIP-84 specification test vectors.
        assert_eq!(
            address(TEST_MNEMONIC).unwrap(),
            "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu"
        );
    }

    #[test]
    fn signs_and_serializes() {
        let params = BtcTxParams {
            utxos: vec![BtcUtxo {
                txid: "1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100".into(),
                vout: 1,
                value_sats: 50_000,
            }],
            to_address: "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu".into(),
            amount_sats: 30_000,
            change_sats: 15_000,
        };
        let raw = sign_transaction(TEST_MNEMONIC, &params).unwrap();
        // Deterministic signing → stable output; sanity check segwit marker.
        assert_eq!(raw, sign_transaction(TEST_MNEMONIC, &params).unwrap());
        assert!(raw.starts_with("02000000")); // version 2
        assert_eq!(&raw[8..12], "0001"); // segwit marker + flag
    }

    #[test]
    fn rejects_fee_underflow() {
        let params = BtcTxParams {
            utxos: vec![BtcUtxo {
                txid: "1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100".into(),
                vout: 0,
                value_sats: 1_000,
            }],
            to_address: "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu".into(),
            amount_sats: 1_000,
            change_sats: 0,
        };
        assert!(sign_transaction(TEST_MNEMONIC, &params).is_err());
    }
}
