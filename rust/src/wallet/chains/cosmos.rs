//! Cosmos SDK chains: bech32 address derivation and SIGN_MODE_DIRECT
//! bank MsgSend signing.
//!
//! Address derivation matches Keplr (`@keplr-wallet/crypto` key.ts):
//! `bech32(hrp, ripemd160(sha256(compressed_pubkey)))` at m/44'/118'/0'/0/0.
//! Transaction encoding is hand-rolled canonical proto3 (defaults omitted),
//! mirroring the cosmos-sdk `TxBody`/`AuthInfo`/`SignDoc`/`TxRaw` messages
//! Keplr builds via proto-types. The signature is the 64-byte compact r||s
//! over sha256(SignDoc), as asserted in Keplr's encodeSecp256k1Signature.
//!
//! The chain is parameterized (hrp/chain_id/denom) so Cosmos Hub is just the
//! first configuration, not a hardcode.

use base64::Engine;
use bech32::{Bech32, Hrp};
use secp256k1::{Message, Secp256k1};
use sha2::{Digest, Sha256};

use super::{derive_secp256k1, hardened, hash160, Secp256k1Key};

fn derive(mnemonic: &str) -> Result<Secp256k1Key, String> {
    derive_secp256k1(mnemonic, &[hardened(44), hardened(118), hardened(0), 0, 0])
}

/// Bech32 account address for the given prefix (e.g. "cosmos").
pub fn address(mnemonic: &str, hrp: &str) -> Result<String, String> {
    let key = derive(mnemonic)?;
    let hash = hash160(&key.public.serialize());
    let hrp = Hrp::parse(hrp).map_err(|e| format!("Invalid bech32 prefix: {e}"))?;
    bech32::encode::<Bech32>(hrp, &hash).map_err(|e| format!("bech32 encode failed: {e}"))
}

pub struct CosmosTxParams {
    pub chain_id: String,
    /// Bech32 prefix; the from-address is derived from the mnemonic with it.
    pub hrp: String,
    pub account_number: u64,
    pub sequence: u64,
    pub to_address: String,
    pub amount: String,
    pub denom: String,
    pub fee_amount: String,
    pub fee_denom: String,
    pub gas_limit: u64,
    pub memo: String,
}

/// Sign a bank MsgSend. Returns base64(TxRaw) for
/// `POST /cosmos/tx/v1beta1/txs`.
pub fn sign_transaction(mnemonic: &str, params: &CosmosTxParams) -> Result<String, String> {
    let key = derive(mnemonic)?;
    let from_address = address(mnemonic, &params.hrp)?;

    // cosmos.bank.v1beta1.MsgSend
    let mut coin = Vec::new();
    pb_string(&mut coin, 1, &params.denom);
    pb_string(&mut coin, 2, &params.amount);
    let mut msg_send = Vec::new();
    pb_string(&mut msg_send, 1, &from_address);
    pb_string(&mut msg_send, 2, &params.to_address);
    pb_bytes(&mut msg_send, 3, &coin);

    let mut any_msg = Vec::new();
    pb_string(&mut any_msg, 1, "/cosmos.bank.v1beta1.MsgSend");
    pb_bytes(&mut any_msg, 2, &msg_send);

    let mut body = Vec::new();
    pb_bytes(&mut body, 1, &any_msg);
    if !params.memo.is_empty() {
        pb_string(&mut body, 2, &params.memo);
    }

    // AuthInfo: SignerInfo{ Any(secp256k1.PubKey), ModeInfo::Single(DIRECT), sequence } + Fee
    let mut pub_key = Vec::new();
    pb_bytes(&mut pub_key, 1, &key.public.serialize());
    let mut any_key = Vec::new();
    pb_string(&mut any_key, 1, "/cosmos.crypto.secp256k1.PubKey");
    pb_bytes(&mut any_key, 2, &pub_key);

    let mut mode_single = Vec::new();
    pb_uint(&mut mode_single, 1, 1); // SIGN_MODE_DIRECT = 1
    let mut mode_info = Vec::new();
    pb_bytes(&mut mode_info, 1, &mode_single);

    let mut signer_info = Vec::new();
    pb_bytes(&mut signer_info, 1, &any_key);
    pb_bytes(&mut signer_info, 2, &mode_info);
    pb_uint(&mut signer_info, 3, params.sequence);

    let mut fee_coin = Vec::new();
    pb_string(&mut fee_coin, 1, &params.fee_denom);
    pb_string(&mut fee_coin, 2, &params.fee_amount);
    let mut fee = Vec::new();
    pb_bytes(&mut fee, 1, &fee_coin);
    pb_uint(&mut fee, 2, params.gas_limit);

    let mut auth_info = Vec::new();
    pb_bytes(&mut auth_info, 1, &signer_info);
    pb_bytes(&mut auth_info, 2, &fee);

    // SignDoc → sha256 → compact 64-byte secp256k1 signature.
    let mut sign_doc = Vec::new();
    pb_bytes(&mut sign_doc, 1, &body);
    pb_bytes(&mut sign_doc, 2, &auth_info);
    pb_string(&mut sign_doc, 3, &params.chain_id);
    pb_uint(&mut sign_doc, 4, params.account_number);

    let digest = Sha256::digest(&sign_doc);
    let msg = Message::from_digest_slice(&digest).map_err(|e| format!("Bad digest: {e}"))?;
    let secp = Secp256k1::new();
    let signature = secp.sign_ecdsa(&msg, &key.secret).serialize_compact();

    let mut tx_raw = Vec::new();
    pb_bytes(&mut tx_raw, 1, &body);
    pb_bytes(&mut tx_raw, 2, &auth_info);
    pb_bytes(&mut tx_raw, 3, &signature);

    Ok(base64::engine::general_purpose::STANDARD.encode(tx_raw))
}

// ---- Minimal canonical proto3 writer (defaults omitted) ----

fn pb_varint(buf: &mut Vec<u8>, mut v: u64) {
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

fn pb_uint(buf: &mut Vec<u8>, field: u32, v: u64) {
    if v == 0 {
        return; // proto3 canonical: default values are omitted
    }
    pb_varint(buf, ((field as u64) << 3) | 0);
    pb_varint(buf, v);
}

fn pb_bytes(buf: &mut Vec<u8>, field: u32, data: &[u8]) {
    pb_varint(buf, ((field as u64) << 3) | 2);
    pb_varint(buf, data.len() as u64);
    buf.extend_from_slice(data);
}

fn pb_string(buf: &mut Vec<u8>, field: u32, s: &str) {
    if s.is_empty() {
        return;
    }
    pb_bytes(buf, field, s.as_bytes());
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_MNEMONIC: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    #[test]
    fn derives_known_cosmos_address() {
        // Canonical cosmjs (DirectSecp256k1HdWallet) test-vector address for
        // the standard test mnemonic at m/44'/118'/0'/0/0.
        assert_eq!(
            address(TEST_MNEMONIC, "cosmos").unwrap(),
            "cosmos19rl4cm2hmr8afy4kldpxz3fka4jguq0auqdal4"
        );
    }

    #[test]
    fn varint_encoding() {
        let mut buf = Vec::new();
        pb_varint(&mut buf, 0);
        assert_eq!(buf, [0]);
        buf.clear();
        pb_varint(&mut buf, 300);
        assert_eq!(buf, [0xac, 0x02]);
    }

    #[test]
    fn signs_msgsend_deterministically() {
        let params = CosmosTxParams {
            chain_id: "cosmoshub-4".into(),
            hrp: "cosmos".into(),
            account_number: 12345,
            sequence: 2,
            to_address: "cosmos1vqpjljwsynsn58dugz0w8ut7kun7t8ls2qkmsq".into(),
            amount: "1000000".into(),
            denom: "uatom".into(),
            fee_amount: "2500".into(),
            fee_denom: "uatom".into(),
            gas_limit: 100_000,
            memo: String::new(),
        };
        let a = sign_transaction(TEST_MNEMONIC, &params).unwrap();
        let b = sign_transaction(TEST_MNEMONIC, &params).unwrap();
        assert_eq!(a, b);
        // TxRaw must decode as base64 and start with field 1 (body_bytes).
        let raw = base64::engine::general_purpose::STANDARD.decode(&a).unwrap();
        assert_eq!(raw[0], 0x0a);
    }
}
