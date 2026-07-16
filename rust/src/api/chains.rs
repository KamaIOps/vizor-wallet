//! FRB API for multichain (non-Zcash) support: address derivation and
//! transaction signing for BTC / EVM / Cosmos / SOL.
//!
//! Flat structs and primitive params only, per the Rust API design
//! constraint. Dart owns networking (balances, nonces, UTXOs, blockhashes,
//! broadcast); these functions are pure key derivation / signing, and the
//! mnemonic never leaves Rust in derived form.

use crate::wallet::chains::{aptos, btc, cosmos, doge, eth, sol, sui};

/// One requested Cosmos address derivation: bech32 prefix, SLIP-44 coin
/// type for the HD path, and whether the chain uses ethermint-style keccak
/// addresses.
pub struct ApiCosmosAddressSpec {
    pub hrp: String,
    pub coin_type: u32,
    pub eth_key: bool,
}

/// Per-chain receive addresses derived from one account mnemonic.
///
/// `cosmos` holds one bech32 address per requested spec, in the same order
/// as the `cosmos_specs` argument. `btc_legacy` is the BIP-44 P2PKH
/// derivation used for fund discovery alongside the BIP-84 default.
pub struct MultichainAddresses {
    pub btc: String,
    pub btc_legacy: String,
    pub doge: String,
    pub eth: String,
    pub cosmos: Vec<String>,
    pub sol: String,
    pub sui: String,
    pub aptos: String,
}

pub fn get_multichain_addresses(
    mnemonic: String,
    cosmos_specs: Vec<ApiCosmosAddressSpec>,
) -> Result<MultichainAddresses, String> {
    Ok(MultichainAddresses {
        btc: btc::address(&mnemonic)?,
        btc_legacy: btc::legacy_address(&mnemonic)?,
        doge: doge::address(&mnemonic)?,
        eth: eth::address(&mnemonic)?,
        cosmos: cosmos_specs
            .iter()
            .map(|spec| cosmos::address(&mnemonic, &spec.hrp, spec.coin_type, spec.eth_key))
            .collect::<Result<Vec<_>, _>>()?,
        sol: sol::address(&mnemonic)?,
        sui: sui::address(&mnemonic)?,
        aptos: aptos::address(&mnemonic)?,
    })
}

/// Sign a legacy (type-0, EIP-155) transfer for chains without EIP-1559.
/// Returns 0x-prefixed raw tx hex for `eth_sendRawTransaction`.
pub fn sign_eth_legacy_transaction(
    mnemonic: String,
    chain_id: u64,
    nonce: u64,
    gas_price_wei: String,
    gas_limit: u64,
    to: String,
    value_wei: String,
) -> Result<String, String> {
    eth::sign_legacy_transaction(
        &mnemonic,
        &eth::EthLegacyTxParams {
            chain_id,
            nonce,
            gas_price_wei,
            gas_limit,
            to,
            value_wei,
        },
    )
}

pub struct ApiSuiGasObject {
    pub object_id: String,
    pub version: u64,
    /// Base58 object digest from `suix_getCoins`.
    pub digest: String,
}

pub struct ApiSuiSignedTransfer {
    /// base64(bcs(TransactionData)) for `sui_executeTransactionBlock`.
    pub tx_bytes_base64: String,
    /// base64(flag || sig || pubkey).
    pub signature_base64: String,
}

/// Build and sign a SUI transfer PTB (SplitCoins from gas +
/// TransferObjects). The provided coins are smashed into the gas object and
/// fund both the transfer amount and gas.
pub fn sign_sui_transfer(
    mnemonic: String,
    recipient: String,
    amount_mist: u64,
    gas_budget: u64,
    gas_price: u64,
    gas_objects: Vec<ApiSuiGasObject>,
) -> Result<ApiSuiSignedTransfer, String> {
    let signed = sui::sign_transfer(
        &mnemonic,
        &sui::SuiTxParams {
            recipient,
            amount_mist,
            gas_budget,
            gas_price,
            gas_objects: gas_objects
                .into_iter()
                .map(|g| sui::SuiGasObject {
                    object_id: g.object_id,
                    version: g.version,
                    digest: g.digest,
                })
                .collect(),
        },
    )?;
    Ok(ApiSuiSignedTransfer {
        tx_bytes_base64: signed.tx_bytes_base64,
        signature_base64: signed.signature_base64,
    })
}

pub struct ApiAptosSignedTransfer {
    /// 0x-prefixed ed25519 public key for the JSON submission envelope.
    pub public_key_hex: String,
    /// 0x-prefixed signature over the RawTransaction signing message.
    pub signature_hex: String,
}

/// Sign an Aptos `0x1::aptos_account::transfer`. Dart submits the matching
/// JSON envelope to `POST /v1/transactions`; the node re-derives and
/// verifies this signing message, so any field mismatch is rejected there.
#[allow(clippy::too_many_arguments)]
pub fn sign_aptos_transfer(
    mnemonic: String,
    sequence_number: u64,
    to_address: String,
    amount_octas: u64,
    max_gas_amount: u64,
    gas_unit_price: u64,
    expiration_timestamp_secs: u64,
    chain_id: u8,
) -> Result<ApiAptosSignedTransfer, String> {
    let signed = aptos::sign_transfer(
        &mnemonic,
        &aptos::AptosTxParams {
            sequence_number,
            to_address,
            amount_octas,
            max_gas_amount,
            gas_unit_price,
            expiration_timestamp_secs,
            chain_id,
        },
    )?;
    Ok(ApiAptosSignedTransfer {
        public_key_hex: signed.public_key_hex,
        signature_hex: signed.signature_hex,
    })
}

/// Sign a Dogecoin legacy P2PKH transaction spending the given UTXOs. The
/// implicit fee is `sum(utxos) - amount - change` and must be positive.
/// Returns raw tx hex for BlockCypher `POST /txs/push`.
pub fn sign_doge_transaction(
    mnemonic: String,
    utxos: Vec<ApiBtcUtxo>,
    to_address: String,
    amount_koinu: u64,
    change_koinu: u64,
) -> Result<String, String> {
    doge::sign_transaction(
        &mnemonic,
        &doge::DogeTxParams {
            utxos: utxos
                .into_iter()
                .map(|u| doge::DogeUtxo {
                    txid: u.txid,
                    vout: u.vout,
                    value_koinu: u.value_sats,
                })
                .collect(),
            to_address,
            amount_koinu,
            change_koinu,
        },
    )
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

/// Sign a transaction spending the given UTXOs from the BIP-84 P2WPKH
/// derivation (default) or the BIP-44 legacy P2PKH derivation (`legacy`).
/// The implicit fee is `sum(utxos) - amount - change` and must be positive.
/// Returns raw tx hex for Esplora `POST /tx`.
pub fn sign_btc_transaction(
    mnemonic: String,
    utxos: Vec<ApiBtcUtxo>,
    to_address: String,
    amount_sats: u64,
    change_sats: u64,
    legacy: bool,
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
            legacy,
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
    coin_type: u32,
    eth_key: bool,
    pubkey_type_url: String,
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
            coin_type,
            eth_key,
            pubkey_type_url,
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

/// Sign an ics-20 IBC MsgTransfer (SIGN_MODE_DIRECT). Returns base64(TxRaw)
/// for `POST /cosmos/tx/v1beta1/txs` on the SOURCE chain. Timeout fields
/// describe the DESTINATION chain (Keplr convention: latest height + 150,
/// revision number from the dest chain-id version, 0 when suffix-less).
#[allow(clippy::too_many_arguments)]
pub fn sign_cosmos_ibc_transfer(
    mnemonic: String,
    chain_id: String,
    hrp: String,
    coin_type: u32,
    eth_key: bool,
    pubkey_type_url: String,
    account_number: u64,
    sequence: u64,
    source_channel: String,
    to_address: String,
    amount: String,
    denom: String,
    fee_amount: String,
    fee_denom: String,
    gas_limit: u64,
    timeout_revision_number: u64,
    timeout_revision_height: u64,
    memo: String,
) -> Result<String, String> {
    cosmos::sign_ibc_transfer(
        &mnemonic,
        &cosmos::CosmosIbcTransferParams {
            chain_id,
            hrp,
            coin_type,
            eth_key,
            pubkey_type_url,
            account_number,
            sequence,
            source_channel,
            to_address,
            amount,
            denom,
            fee_amount,
            fee_denom,
            gas_limit,
            timeout_revision_number,
            timeout_revision_height,
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
