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
use sha3::Keccak256;

use super::{derive_secp256k1, hardened, hash160, Secp256k1Key};

/// How a chain hashes and identifies keys. `Standard` is plain Cosmos SDK
/// secp256k1 (sha256 sign-doc digest, hash160 addresses). `EthKey` is the
/// ethermint/Injective style (keccak256 sign-doc digest, ethereum-style
/// keccak addresses bech32-encoded) — matching Keplr's `isEthermintLike`
/// handling in keyring-cosmos.
fn derive(mnemonic: &str, coin_type: u32) -> Result<Secp256k1Key, String> {
    derive_secp256k1(
        mnemonic,
        &[hardened(44), hardened(coin_type), hardened(0), 0, 0],
    )
}

fn account_bytes(key: &Secp256k1Key, eth_key: bool) -> [u8; 20] {
    if eth_key {
        // Ethereum-style: keccak256 of the uncompressed pubkey, last 20 B.
        let uncompressed = key.public.serialize_uncompressed();
        let hash = Keccak256::digest(&uncompressed[1..]);
        let mut out = [0u8; 20];
        out.copy_from_slice(&hash[12..]);
        out
    } else {
        hash160(&key.public.serialize())
    }
}

/// Bech32 account address for the given prefix, derivation coin type, and
/// key style. The coin type only changes the HD path; the address format
/// follows `eth_key` (the chain), so e.g. an Evmos account derived at 118
/// still gets a keccak-style address, like Keplr's coin-type selection.
pub fn address(
    mnemonic: &str,
    hrp: &str,
    coin_type: u32,
    eth_key: bool,
) -> Result<String, String> {
    let key = derive(mnemonic, coin_type)?;
    let bytes = account_bytes(&key, eth_key);
    let hrp = Hrp::parse(hrp).map_err(|e| format!("Invalid bech32 prefix: {e}"))?;
    bech32::encode::<Bech32>(hrp, &bytes).map_err(|e| format!("bech32 encode failed: {e}"))
}

pub struct CosmosTxParams {
    pub chain_id: String,
    /// Bech32 prefix; the from-address is derived from the mnemonic with it.
    pub hrp: String,
    /// SLIP-44 coin type for the HD path (118 standard, 60 ethermint, 529
    /// secret, 931 thorchain, ...).
    pub coin_type: u32,
    /// Ethermint/Injective-style chain: keccak sign-doc digest and
    /// keccak-derived addresses.
    pub eth_key: bool,
    /// Any type url for the signer public key (resolved per chain like
    /// Keplr's getCosmosPubKeyTypeUrl).
    pub pubkey_type_url: String,
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
    let key = derive(mnemonic, params.coin_type)?;
    let from_address = address(mnemonic, &params.hrp, params.coin_type, params.eth_key)?;

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

    sign_body(
        &key,
        body,
        &params.chain_id,
        params.account_number,
        params.sequence,
        &params.fee_amount,
        &params.fee_denom,
        params.gas_limit,
        params.eth_key,
        &params.pubkey_type_url,
    )
}

pub struct CosmosIbcTransferParams {
    pub chain_id: String,
    /// Bech32 prefix of the SOURCE chain; the sender is derived with it.
    pub hrp: String,
    /// SLIP-44 coin type for the HD path.
    pub coin_type: u32,
    /// Ethermint/Injective-style source chain (keccak digest + addresses).
    pub eth_key: bool,
    /// Any type url for the signer public key.
    pub pubkey_type_url: String,
    pub account_number: u64,
    pub sequence: u64,
    /// Source-side transfer channel (e.g. "channel-141" on cosmoshub-4).
    pub source_channel: String,
    /// Receiver address on the DESTINATION chain (its own bech32 prefix).
    pub to_address: String,
    pub amount: String,
    pub denom: String,
    pub fee_amount: String,
    pub fee_denom: String,
    pub gas_limit: u64,
    /// Destination chain-id version (0 when the chain-id has no `-N` suffix).
    pub timeout_revision_number: u64,
    /// Destination latest height + margin (Keplr uses +150).
    pub timeout_revision_height: u64,
    pub memo: String,
}

/// Sign an ics-20 MsgTransfer (SIGN_MODE_DIRECT). Returns base64(TxRaw) for
/// `POST /cosmos/tx/v1beta1/txs`.
///
/// Message construction mirrors Keplr (`stores/src/account/cosmos.ts`
/// makeIBCTransferTx): port "transfer", timeout_height = destination latest
/// height + 150 with the destination chain-id version as revision_number,
/// timeout_timestamp omitted.
pub fn sign_ibc_transfer(
    mnemonic: &str,
    params: &CosmosIbcTransferParams,
) -> Result<String, String> {
    let key = derive(mnemonic, params.coin_type)?;
    let from_address = address(mnemonic, &params.hrp, params.coin_type, params.eth_key)?;

    // ibc.applications.transfer.v1.MsgTransfer
    let mut token = Vec::new();
    pb_string(&mut token, 1, &params.denom);
    pb_string(&mut token, 2, &params.amount);

    let mut timeout_height = Vec::new();
    pb_uint(&mut timeout_height, 1, params.timeout_revision_number);
    pb_uint(&mut timeout_height, 2, params.timeout_revision_height);

    let mut msg = Vec::new();
    pb_string(&mut msg, 1, "transfer");
    pb_string(&mut msg, 2, &params.source_channel);
    pb_bytes(&mut msg, 3, &token);
    pb_string(&mut msg, 4, &from_address);
    pb_string(&mut msg, 5, &params.to_address);
    pb_bytes(&mut msg, 6, &timeout_height);
    // Field 7 timeout_timestamp stays 0 (omitted), like Keplr's non-eip712
    // path. Field 8 memo is omitted when empty.
    if !params.memo.is_empty() {
        pb_string(&mut msg, 8, &params.memo);
    }

    let mut any_msg = Vec::new();
    pb_string(&mut any_msg, 1, "/ibc.applications.transfer.v1.MsgTransfer");
    pb_bytes(&mut any_msg, 2, &msg);

    let mut body = Vec::new();
    pb_bytes(&mut body, 1, &any_msg);

    sign_body(
        &key,
        body,
        &params.chain_id,
        params.account_number,
        params.sequence,
        &params.fee_amount,
        &params.fee_denom,
        params.gas_limit,
        params.eth_key,
        &params.pubkey_type_url,
    )
}

/// Shared AuthInfo/SignDoc/TxRaw assembly for SIGN_MODE_DIRECT single-signer
/// transactions over an already-encoded TxBody. `eth_key` selects the
/// keccak256 sign-doc digest used by ethermint-like chains (Keplr:
/// `isEthermintLike ? "keccak256" : "sha256"`); the pubkey Any type url is
/// chain-specific for those chains.
#[allow(clippy::too_many_arguments)]
fn sign_body(
    key: &Secp256k1Key,
    body: Vec<u8>,
    chain_id: &str,
    account_number: u64,
    sequence: u64,
    fee_amount: &str,
    fee_denom: &str,
    gas_limit: u64,
    eth_key: bool,
    pubkey_type_url: &str,
) -> Result<String, String> {
    let mut pub_key = Vec::new();
    pb_bytes(&mut pub_key, 1, &key.public.serialize());
    let mut any_key = Vec::new();
    pb_string(&mut any_key, 1, pubkey_type_url);
    pb_bytes(&mut any_key, 2, &pub_key);

    let mut mode_single = Vec::new();
    pb_uint(&mut mode_single, 1, 1); // SIGN_MODE_DIRECT = 1
    let mut mode_info = Vec::new();
    pb_bytes(&mut mode_info, 1, &mode_single);

    let mut signer_info = Vec::new();
    pb_bytes(&mut signer_info, 1, &any_key);
    pb_bytes(&mut signer_info, 2, &mode_info);
    pb_uint(&mut signer_info, 3, sequence);

    let mut fee_coin = Vec::new();
    pb_string(&mut fee_coin, 1, fee_denom);
    pb_string(&mut fee_coin, 2, fee_amount);
    let mut fee = Vec::new();
    pb_bytes(&mut fee, 1, &fee_coin);
    pb_uint(&mut fee, 2, gas_limit);

    let mut auth_info = Vec::new();
    pb_bytes(&mut auth_info, 1, &signer_info);
    pb_bytes(&mut auth_info, 2, &fee);

    let mut sign_doc = Vec::new();
    pb_bytes(&mut sign_doc, 1, &body);
    pb_bytes(&mut sign_doc, 2, &auth_info);
    pb_string(&mut sign_doc, 3, chain_id);
    pb_uint(&mut sign_doc, 4, account_number);

    let digest: [u8; 32] = if eth_key {
        Keccak256::digest(&sign_doc).into()
    } else {
        Sha256::digest(&sign_doc).into()
    };
    let msg = Message::from_digest(digest);
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
            address(TEST_MNEMONIC, "cosmos", 118, false).unwrap(),
            "cosmos19rl4cm2hmr8afy4kldpxz3fka4jguq0auqdal4"
        );
    }

    #[test]
    fn eth_key_address_matches_eth_account() {
        // Ethermint-style addresses are the ETH account bytes (keccak of the
        // m/44'/60' pubkey) bech32-encoded — cross-check against the
        // canonical ETH address for the test mnemonic.
        let inj = address(TEST_MNEMONIC, "inj", 60, true).unwrap();
        let (hrp, data) = bech32::decode(&inj).unwrap();
        assert_eq!(hrp.as_str(), "inj");
        assert_eq!(
            hex::encode(data),
            "9858effd232b4033e47d90003d41ec34ecaeda94"
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
    fn address_payload_is_prefix_independent() {
        // Same key hash under every bech32 prefix: decoding the cosmos and
        // osmo addresses must yield identical payloads.
        let (hrp_a, data_a) =
            bech32::decode(&address(TEST_MNEMONIC, "cosmos", 118, false).unwrap()).unwrap();
        let (hrp_b, data_b) =
            bech32::decode(&address(TEST_MNEMONIC, "osmo", 118, false).unwrap()).unwrap();
        assert_eq!(hrp_a.as_str(), "cosmos");
        assert_eq!(hrp_b.as_str(), "osmo");
        assert_eq!(data_a, data_b);
    }

    #[test]
    fn signs_ibc_transfer_deterministically() {
        let params = CosmosIbcTransferParams {
            chain_id: "cosmoshub-4".into(),
            hrp: "cosmos".into(),
            coin_type: 118,
            eth_key: false,
            pubkey_type_url: "/cosmos.crypto.secp256k1.PubKey".into(),
            account_number: 12345,
            sequence: 3,
            source_channel: "channel-141".into(),
            to_address: "osmo1vqpjljwsynsn58dugz0w8ut7kun7t8ls5va3fg".into(),
            amount: "1000000".into(),
            denom: "uatom".into(),
            fee_amount: "11250".into(),
            fee_denom: "uatom".into(),
            gas_limit: 450_000,
            timeout_revision_number: 1,
            timeout_revision_height: 12_345_678,
            memo: String::new(),
        };
        let a = sign_ibc_transfer(TEST_MNEMONIC, &params).unwrap();
        let b = sign_ibc_transfer(TEST_MNEMONIC, &params).unwrap();
        assert_eq!(a, b);
        let raw = base64::engine::general_purpose::STANDARD.decode(&a).unwrap();
        assert_eq!(raw[0], 0x0a); // field 1: body_bytes
        let needle = b"/ibc.applications.transfer.v1.MsgTransfer";
        assert!(
            raw.windows(needle.len()).any(|w| w == needle),
            "TxRaw must embed the MsgTransfer type url"
        );
        let receiver = b"osmo1vqpjljwsynsn58dugz0w8ut7kun7t8ls5va3fg";
        assert!(raw.windows(receiver.len()).any(|w| w == receiver));
    }

    #[test]
    fn ibc_timeout_height_omits_zero_revision_number() {
        // Chains without a `-N` chain-id suffix (e.g. celestia) have revision
        // number 0, which canonical proto3 omits — the timeout_height message
        // must then contain only revision_height.
        let mut timeout_height = Vec::new();
        pb_uint(&mut timeout_height, 1, 0);
        pb_uint(&mut timeout_height, 2, 100);
        assert_eq!(timeout_height, vec![0x10, 100]); // field 2 varint only
    }

    #[test]
    fn signs_msgsend_deterministically() {
        let params = CosmosTxParams {
            chain_id: "cosmoshub-4".into(),
            hrp: "cosmos".into(),
            coin_type: 118,
            eth_key: false,
            pubkey_type_url: "/cosmos.crypto.secp256k1.PubKey".into(),
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
