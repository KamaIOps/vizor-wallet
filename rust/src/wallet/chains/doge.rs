//! Dogecoin: BIP-44 legacy P2PKH address derivation and transaction signing.
//!
//! Doge has no segwit; transactions are pre-segwit v1 with legacy sighash.
//! rust-bitcoin's transaction, script, and legacy-sighash machinery is
//! network-independent, so this module reuses it and hand-rolls only the
//! base58check version bytes (P2PKH 0x1E 'D', P2SH 0x16 '9'/'A', per
//! libdogecoin). Coin selection, fees, and broadcast happen in Dart
//! (BlockCypher public API); inputs are assumed to be P2PKH outputs of this
//! account's single derived key, mirroring the BTC module.

use std::str::FromStr;

use bitcoin::absolute::LockTime;
use bitcoin::base58;
use bitcoin::hashes::Hash;
use bitcoin::script::PushBytesBuf;
use bitcoin::sighash::{EcdsaSighashType, SighashCache};
use bitcoin::transaction::Version;
use bitcoin::{
    Amount, OutPoint, PubkeyHash, ScriptBuf, ScriptHash, Sequence, Transaction, TxIn, TxOut, Txid,
    Witness,
};
use secp256k1::{Message, Secp256k1};

use super::{derive_secp256k1, hardened, hash160, Secp256k1Key};

/// Base58check version bytes (mainnet).
const DOGE_P2PKH_VERSION: u8 = 0x1e; // addresses starting with 'D'
const DOGE_P2SH_VERSION: u8 = 0x16; // addresses starting with '9' or 'A'

fn derive(mnemonic: &str) -> Result<Secp256k1Key, String> {
    derive_secp256k1(mnemonic, &[hardened(44), hardened(3), hardened(0), 0, 0])
}

fn pubkey_hash(key: &Secp256k1Key) -> [u8; 20] {
    hash160(&key.public.serialize())
}

/// Legacy base58check P2PKH ('D…') address for the account.
pub fn address(mnemonic: &str) -> Result<String, String> {
    let key = derive(mnemonic)?;
    let mut payload = Vec::with_capacity(21);
    payload.push(DOGE_P2PKH_VERSION);
    payload.extend_from_slice(&pubkey_hash(&key));
    Ok(base58::encode_check(&payload))
}

/// scriptPubKey for a Doge address (P2PKH and P2SH accepted).
fn script_pubkey_for(address: &str) -> Result<ScriptBuf, String> {
    let payload =
        base58::decode_check(address).map_err(|e| format!("Invalid Doge address: {e}"))?;
    if payload.len() != 21 {
        return Err("Invalid Doge address length".into());
    }
    let hash: [u8; 20] = payload[1..].try_into().expect("checked length");
    match payload[0] {
        DOGE_P2PKH_VERSION => Ok(ScriptBuf::new_p2pkh(&PubkeyHash::from_byte_array(hash))),
        DOGE_P2SH_VERSION => Ok(ScriptBuf::new_p2sh(&ScriptHash::from_byte_array(hash))),
        v => Err(format!("Not a mainnet Doge address (version byte {v})")),
    }
}

pub struct DogeUtxo {
    pub txid: String,
    pub vout: u32,
    pub value_koinu: u64,
}

pub struct DogeTxParams {
    pub utxos: Vec<DogeUtxo>,
    pub to_address: String,
    pub amount_koinu: u64,
    /// Change returned to our own address; omitted when the remainder is fee.
    pub change_koinu: u64,
}

/// Build and sign a legacy P2PKH transaction. Returns raw tx hex.
pub fn sign_transaction(mnemonic: &str, params: &DogeTxParams) -> Result<String, String> {
    if params.utxos.is_empty() {
        return Err("No inputs provided".into());
    }
    let key = derive(mnemonic)?;
    let our_script = ScriptBuf::new_p2pkh(&PubkeyHash::from_byte_array(pubkey_hash(&key)));

    let total_in: u64 = params.utxos.iter().map(|u| u.value_koinu).sum();
    let total_out = params
        .amount_koinu
        .checked_add(params.change_koinu)
        .ok_or("Output overflow")?;
    if total_out >= total_in {
        return Err("Outputs plus fee exceed inputs".into());
    }

    let to_script = script_pubkey_for(&params.to_address)?;

    let input = params
        .utxos
        .iter()
        .map(|u| {
            let txid = Txid::from_str(&u.txid).map_err(|e| format!("Invalid txid: {e}"))?;
            Ok(TxIn {
                previous_output: OutPoint { txid, vout: u.vout },
                script_sig: ScriptBuf::new(),
                sequence: Sequence::MAX,
                witness: Witness::default(),
            })
        })
        .collect::<Result<Vec<_>, String>>()?;

    let mut output = vec![TxOut {
        value: Amount::from_sat(params.amount_koinu),
        script_pubkey: to_script,
    }];
    if params.change_koinu > 0 {
        output.push(TxOut {
            value: Amount::from_sat(params.change_koinu),
            script_pubkey: our_script.clone(),
        });
    }

    let mut tx = Transaction {
        version: Version::ONE,
        lock_time: LockTime::ZERO,
        input,
        output,
    };

    let secp = Secp256k1::new();
    let cache = SighashCache::new(tx.clone());
    for i in 0..params.utxos.len() {
        let sighash = cache
            .legacy_signature_hash(i, &our_script, EcdsaSighashType::All.to_u32())
            .map_err(|e| format!("Sighash failed: {e}"))?;
        let msg = Message::from_digest(sighash.to_byte_array());
        let mut sig_bytes = secp.sign_ecdsa(&msg, &key.secret).serialize_der().to_vec();
        sig_bytes.push(EcdsaSighashType::All.to_u32() as u8);

        let sig_push = PushBytesBuf::try_from(sig_bytes).map_err(|_| "Signature too long")?;
        let key_push = PushBytesBuf::try_from(key.public.serialize().to_vec())
            .map_err(|_| "Pubkey too long")?;
        tx.input[i].script_sig = bitcoin::script::Builder::new()
            .push_slice(sig_push)
            .push_slice(key_push)
            .into_script();
    }

    Ok(hex::encode(bitcoin::consensus::encode::serialize(&tx)))
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_MNEMONIC: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    #[test]
    fn derives_known_doge_address() {
        // Cross-checked with bip_utils (Bip44Coins.DOGECOIN) for the standard
        // test mnemonic at m/44'/3'/0'/0/0.
        assert_eq!(
            address(TEST_MNEMONIC).unwrap(),
            "DBus3bamQjgJULBJtYXpEzDWQRwF5iwxgC"
        );
    }

    #[test]
    fn accepts_p2pkh_and_p2sh_recipients_only() {
        assert!(script_pubkey_for("DBus3bamQjgJULBJtYXpEzDWQRwF5iwxgC").unwrap().is_p2pkh());
        // BTC mainnet P2PKH (version 0x00) must be rejected.
        assert!(script_pubkey_for("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa").is_err());
        assert!(script_pubkey_for("not-an-address").is_err());
    }

    #[test]
    fn signs_legacy_v1_transaction() {
        let params = DogeTxParams {
            utxos: vec![DogeUtxo {
                txid: "1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100".into(),
                vout: 1,
                value_koinu: 500_000_000,
            }],
            to_address: "DBus3bamQjgJULBJtYXpEzDWQRwF5iwxgC".into(),
            amount_koinu: 300_000_000,
            change_koinu: 150_000_000,
        };
        let raw = sign_transaction(TEST_MNEMONIC, &params).unwrap();
        // RFC-6979 determinism, tx version 1, and no segwit marker.
        assert_eq!(raw, sign_transaction(TEST_MNEMONIC, &params).unwrap());
        assert!(raw.starts_with("01000000"));
        assert_ne!(&raw[8..12], "0001");
        // Round-trips through consensus decoding with a signed script_sig.
        let bytes = hex::decode(&raw).unwrap();
        let tx: Transaction = bitcoin::consensus::encode::deserialize(&bytes).unwrap();
        assert_eq!(tx.version, Version::ONE);
        assert!(!tx.input[0].script_sig.is_empty());
        assert_eq!(tx.output.len(), 2);
    }

    #[test]
    fn rejects_fee_underflow() {
        let params = DogeTxParams {
            utxos: vec![DogeUtxo {
                txid: "1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100".into(),
                vout: 0,
                value_koinu: 1_000,
            }],
            to_address: "DBus3bamQjgJULBJtYXpEzDWQRwF5iwxgC".into(),
            amount_koinu: 1_000,
            change_koinu: 0,
        };
        assert!(sign_transaction(TEST_MNEMONIC, &params).is_err());
    }
}
