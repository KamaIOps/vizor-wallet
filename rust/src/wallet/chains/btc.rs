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

fn derive(mnemonic: &str, legacy: bool) -> Result<Secp256k1Key, String> {
    let purpose = if legacy { 44 } else { 84 };
    derive_secp256k1(
        mnemonic,
        &[hardened(purpose), hardened(0), hardened(0), 0, 0],
    )
}

fn compressed(key: &Secp256k1Key) -> CompressedPublicKey {
    CompressedPublicKey(key.public)
}

/// Native segwit (bc1…) address for the account (BIP-84).
pub fn address(mnemonic: &str) -> Result<String, String> {
    let key = derive(mnemonic, false)?;
    Ok(Address::p2wpkh(&compressed(&key), Network::Bitcoin).to_string())
}

/// Legacy P2PKH (1…) address at the BIP-44 path — used to discover and
/// sweep funds sent to the account's pre-segwit derivation.
pub fn legacy_address(mnemonic: &str) -> Result<String, String> {
    let key = derive(mnemonic, true)?;
    Ok(Address::p2pkh(compressed(&key), Network::Bitcoin).to_string())
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
    /// Spend from the BIP-44 legacy P2PKH derivation instead of BIP-84
    /// P2WPKH. All inputs must belong to the selected derivation.
    pub legacy: bool,
}

/// Build and sign a transaction spending this account's P2WPKH (default) or
/// legacy P2PKH (`legacy`) outputs. Returns raw tx hex for broadcast.
pub fn sign_transaction(mnemonic: &str, params: &BtcTxParams) -> Result<String, String> {
    if params.utxos.is_empty() {
        return Err("No inputs provided".into());
    }
    let key = derive(mnemonic, params.legacy)?;
    let our_pubkey = compressed(&key);
    let our_address = if params.legacy {
        Address::p2pkh(our_pubkey, Network::Bitcoin)
    } else {
        Address::p2wpkh(&our_pubkey, Network::Bitcoin)
    };
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
        if params.legacy {
            let sighash = cache
                .legacy_signature_hash(i, &our_script, EcdsaSighashType::All.to_u32())
                .map_err(|e| format!("Sighash failed: {e}"))?;
            let msg = Message::from_digest(sighash.to_byte_array());
            let mut sig_bytes = secp.sign_ecdsa(&msg, &key.secret).serialize_der().to_vec();
            sig_bytes.push(EcdsaSighashType::All.to_u32() as u8);
            let sig_push = bitcoin::script::PushBytesBuf::try_from(sig_bytes)
                .map_err(|_| "Signature too long")?;
            let key_push =
                bitcoin::script::PushBytesBuf::try_from(key.public.serialize().to_vec())
                    .map_err(|_| "Pubkey too long")?;
            tx.input[i].script_sig = bitcoin::script::Builder::new()
                .push_slice(sig_push)
                .push_slice(key_push)
                .into_script();
        } else {
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
    fn derives_bip44_legacy_address() {
        // Widely published first BIP-44 address for the standard test
        // mnemonic at m/44'/0'/0'/0/0.
        assert_eq!(
            legacy_address(TEST_MNEMONIC).unwrap(),
            "1LqBGSKuX5yYUonjxT5qGfpUsXKYYWeabA"
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
            legacy: false,
        };
        let raw = sign_transaction(TEST_MNEMONIC, &params).unwrap();
        // Deterministic signing → stable output; sanity check segwit marker.
        assert_eq!(raw, sign_transaction(TEST_MNEMONIC, &params).unwrap());
        assert!(raw.starts_with("02000000")); // version 2
        assert_eq!(&raw[8..12], "0001"); // segwit marker + flag
    }

    #[test]
    fn signs_legacy_spend_without_witness() {
        let params = BtcTxParams {
            utxos: vec![BtcUtxo {
                txid: "1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100".into(),
                vout: 1,
                value_sats: 50_000,
            }],
            to_address: "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu".into(),
            amount_sats: 30_000,
            change_sats: 15_000,
            legacy: true,
        };
        let raw = sign_transaction(TEST_MNEMONIC, &params).unwrap();
        assert_eq!(raw, sign_transaction(TEST_MNEMONIC, &params).unwrap());
        assert_ne!(&raw[8..12], "0001"); // no segwit marker
        let tx: Transaction =
            bitcoin::consensus::encode::deserialize(&hex::decode(&raw).unwrap()).unwrap();
        assert!(!tx.input[0].script_sig.is_empty());
        assert!(tx.input[0].witness.is_empty());
        // Change output pays the legacy address' script.
        let legacy_script = Address::from_str(&legacy_address(TEST_MNEMONIC).unwrap())
            .unwrap()
            .require_network(Network::Bitcoin)
            .unwrap()
            .script_pubkey();
        assert_eq!(tx.output[1].script_pubkey, legacy_script);
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
            legacy: false,
        };
        assert!(sign_transaction(TEST_MNEMONIC, &params).is_err());
    }
}
