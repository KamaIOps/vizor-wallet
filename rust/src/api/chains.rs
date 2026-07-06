//! FRB API for multichain (non-Zcash) support: address derivation and
//! transaction signing for BTC / EVM / Cosmos / SOL.
//!
//! Flat structs and primitive params only, per the Rust API design
//! constraint. Dart owns networking (balances, nonces, UTXOs, blockhashes,
//! broadcast); these functions are pure key derivation / signing, and the
//! mnemonic never leaves Rust in derived form.

use crate::wallet::chains::{btc, cosmos, eth, sol};

/// Per-chain receive addresses derived from one account mnemonic.
pub struct MultichainAddresses {
    pub btc: String,
    pub eth: String,
    pub cosmos: String,
    pub sol: String,
}

pub fn get_multichain_addresses(mnemonic: String) -> Result<MultichainAddresses, String> {
    Ok(MultichainAddresses {
        btc: btc::address(&mnemonic)?,
        eth: eth::address(&mnemonic)?,
        cosmos: cosmos::address(&mnemonic, "cosmos")?,
        sol: sol::address(&mnemonic)?,
    })
}

/// Sign an EIP-1559 native transfer. Returns 0x-prefixed raw tx hex for
/// `eth_sendRawTransaction`. Amounts are decimal wei strings.
#[allow(clippy::too_many_arguments)]
pub fn sign_eth_transaction(
    mnemonic: String,
    chain_id: u64,
    nonce: u64,
    max_priority_fee_per_gas_wei: String,
    max_fee_per_gas_wei: String,
    gas_limit: u64,
    to: String,
    value_wei: String,
) -> Result<String, String> {
    eth::sign_transaction(
        &mnemonic,
        &eth::EthTxParams {
            chain_id,
            nonce,
            max_priority_fee_per_gas_wei,
            max_fee_per_gas_wei,
            gas_limit,
            to,
            value_wei,
        },
    )
}

pub struct ApiBtcUtxo {
    pub txid: String,
    pub vout: u32,
    pub value_sats: u64,
}

/// Sign a P2WPKH transaction spending the given UTXOs. The implicit fee is
/// `sum(utxos) - amount - change` and must be positive. Returns raw tx hex
/// for Esplora `POST /tx`.
pub fn sign_btc_transaction(
    mnemonic: String,
    utxos: Vec<ApiBtcUtxo>,
    to_address: String,
    amount_sats: u64,
    change_sats: u64,
) -> Result<String, String> {
    btc::sign_transaction(
        &mnemonic,
        &btc::BtcTxParams {
            utxos: utxos
                .into_iter()
                .map(|u| btc::BtcUtxo {
                    txid: u.txid,
                    vout: u.vout,
                    value_sats: u.value_sats,
                })
                .collect(),
            to_address,
            amount_sats,
            change_sats,
        },
    )
}

/// Sign a Cosmos SDK bank MsgSend (SIGN_MODE_DIRECT). Returns base64(TxRaw)
/// for `POST /cosmos/tx/v1beta1/txs`. The from-address is derived from the
/// mnemonic and `hrp`.
#[allow(clippy::too_many_arguments)]
pub fn sign_cosmos_send(
    mnemonic: String,
    chain_id: String,
    hrp: String,
    account_number: u64,
    sequence: u64,
    to_address: String,
    amount: String,
    denom: String,
    fee_amount: String,
    fee_denom: String,
    gas_limit: u64,
    memo: String,
) -> Result<String, String> {
    cosmos::sign_transaction(
        &mnemonic,
        &cosmos::CosmosTxParams {
            chain_id,
            hrp,
            account_number,
            sequence,
            to_address,
            amount,
            denom,
            fee_amount,
            fee_denom,
            gas_limit,
            memo,
        },
    )
}

/// Sign a Solana system-program transfer. Returns base64 tx for
/// `sendTransaction`.
pub fn sign_sol_transfer(
    mnemonic: String,
    recent_blockhash: String,
    to_address: String,
    lamports: u64,
) -> Result<String, String> {
    sol::sign_transfer(
        &mnemonic,
        &sol::SolTxParams {
            recent_blockhash,
            to_address,
            lamports,
        },
    )
}
