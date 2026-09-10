//! Read-only participation discovery. No spending key, hotkey, PIR or proof
//! generation is needed. Network transport stays at the wallet boundary.
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use prost13::Message;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tendermint::{block::signed_header::SignedHeader, validator};
use tendermint_light_client_verifier::operations::{
    commit_validator::{CommitValidator, ProdCommitValidator},
    voting_power::{ProdVotingPowerCalculator, VotingPowerCalculator},
};
use zcash_client_backend::data_api::{Account, WalletRead};
use zcash_voting::{governance, selection::select_snapshot_note_infos, types::NoteInfo};

use super::network::{voting_network, wallet_network};
use crate::wallet::sync::open_wallet_db_for_read;

// Explicit consensus-key trust, independent of the server returning a proof.
// Captured from the official production/stage RPCs on 2026-09-10. This narrow
// reader does NOT follow validator-set changes: unsupported sets fail closed.
// See docs/voting-participation.md before updating these trust anchors.
const PROD_VALIDATORS: &str = "621A1E2C532170C3C0BC2E951D26C1CCA7A0EFB009AA15820D648D336C64F6BD";
const STAGE_VALIDATORS: &str = "6E81F631CB63A527AB5A659529BA8942C46CCF78BA87D1B3AD4CF8AE5BDC2E8B";
const MAX_NOTES: usize = 1024;
const MAX_JSON: usize = 8 * 1024 * 1024;
const INVALID: &str = "Voting participation evidence could not be verified";

#[derive(Serialize, Deserialize)]
pub struct Candidates {
    pub keys: Vec<String>,
    pub fingerprint: String,
}

fn notes(
    db_path: &str,
    account: &str,
    network: &str,
    round: &str,
    snapshot: u64,
) -> Result<(Vec<NoteInfo>, Candidates), String> {
    let net = voting_network(crate::wallet::keys::parse_network(network)?);
    let db = open_wallet_db_for_read(db_path, wallet_network(net))?;
    let height = db
        .block_fully_scanned()
        .map_err(|_| INVALID)?
        .map(|m| u64::from(u32::from(m.block_height())))
        .unwrap_or(0);
    if height < snapshot {
        return Err("Voting snapshot is not synced".into());
    }
    let uuid = zcash_client_sqlite::AccountUuid::from_uuid(account.parse().map_err(|_| INVALID)?);
    let account_info = db.get_account(uuid).map_err(|_| INVALID)?.ok_or(INVALID)?;
    let fvk = account_info
        .ufvk()
        .and_then(|u| u.orchard())
        .ok_or(INVALID)?
        .to_bytes();
    let round_bytes = hex::decode(round).map_err(|_| INVALID)?;
    if round_bytes.len() != 32 {
        return Err(INVALID.into());
    }
    let dom = governance::compute_nullifier_domain(&round_bytes).map_err(|_| INVALID)?;
    let mut notes = select_snapshot_note_infos(&db, account, snapshot).map_err(|_| INVALID)?;
    notes.sort_by(|a, b| a.nullifier.cmp(&b.nullifier));
    notes.dedup_by(|a, b| a.nullifier == b.nullifier);
    if notes.len() > MAX_NOTES {
        return Err("Voting participation note limit exceeded".into());
    }
    let keys = notes
        .iter()
        .map(|n| {
            let nf = governance::derive_gov_nullifier(&fvk[32..64], &dom, &n.nullifier)
                .map_err(|_| INVALID)?;
            let mut key = vec![1, 0];
            key.extend_from_slice(&round_bytes);
            key.extend(nf);
            Ok(hex::encode(key))
        })
        .collect::<Result<Vec<_>, String>>()?;
    let fingerprint = hex::encode(Sha256::digest(
        serde_json::to_vec(&(network, round, snapshot, &keys)).map_err(|_| INVALID)?,
    ));
    Ok((notes, Candidates { keys, fingerprint }))
}

pub fn prepare(
    db_path: &str,
    account: &str,
    network: &str,
    round: &str,
    snapshot: u64,
) -> Result<String, String> {
    serde_json::to_string(&notes(db_path, account, network, round, snapshot)?.1)
        .map_err(|_| INVALID.into())
}

#[derive(Deserialize)]
struct Envelope<T> {
    result: T,
}
#[derive(Deserialize)]
struct CommitResult {
    signed_header: SignedHeader,
}
#[derive(Deserialize)]
struct ValidatorsResult {
    validators: Vec<validator::Info>,
}
#[derive(Deserialize)]
struct QueryResult {
    response: QueryResponse,
}
#[derive(Deserialize)]
struct QueryResponse {
    code: u32,
    height: String,
    key: Option<String>,
    value: Option<String>,
    #[serde(rename = "proofOps")]
    proof_ops: ProofOps,
}
#[derive(Deserialize)]
struct ProofOps {
    ops: Vec<ProofOp>,
}
#[derive(Deserialize)]
struct ProofOp {
    r#type: String,
    key: String,
    data: String,
}
#[derive(Deserialize)]
struct Evidence {
    commit: Envelope<CommitResult>,
    validators: Envelope<ValidatorsResult>,
    queries: Vec<Envelope<QueryResult>>,
}

fn verify_header(
    commit: &CommitResult,
    validators: &ValidatorsResult,
    network: &str,
    now: i64,
) -> Result<(), String> {
    let (chain, pin) = match network {
        "main" => ("zvote-1", PROD_VALIDATORS),
        "test" => ("svote-1", STAGE_VALIDATORS),
        _ => return Err(INVALID.into()),
    };
    let s = &commit.signed_header;
    let h = &s.header;
    if validators.validators.is_empty() || validators.validators.len() > 100 {
        return Err(INVALID.into());
    }
    let power = validators
        .validators
        .iter()
        .try_fold(0u64, |sum, v| sum.checked_add(v.power.value()))
        .ok_or(INVALID)?;
    if power > (i64::MAX as u64) / 8
        || validators
            .validators
            .iter()
            .map(|v| v.address)
            .collect::<std::collections::HashSet<_>>()
            .len()
            != validators.validators.len()
    {
        return Err(INVALID.into());
    }
    let set = validator::Set::without_proposer(validators.validators.clone());
    let age = now.checked_sub(h.time.unix_timestamp()).ok_or(INVALID)?;
    if h.chain_id.as_str() != chain
        || h.validators_hash.to_string() != pin
        || set.hash() != h.validators_hash
        || h.hash() != s.commit.block_id.hash
        || h.height != s.commit.height
        || !(-60..=600).contains(&age)
    {
        return Err(INVALID.into());
    }
    ProdCommitValidator.validate(s, &set).map_err(|_| INVALID)?;
    ProdCommitValidator
        .validate_full(s, &set)
        .map_err(|_| INVALID)?;
    ProdVotingPowerCalculator::default()
        .check_signers_overlap(s, &set)
        .map_err(|_| INVALID)?;
    Ok(())
}

fn proof(data: &str) -> Result<ics23::CommitmentProof, String> {
    let bytes = B64.decode(data).map_err(|_| INVALID)?;
    ics23::CommitmentProof::decode(bytes.as_slice()).map_err(|_| INVALID.into())
}

fn verify_query(
    q: &QueryResponse,
    key: &[u8],
    app_hash: &[u8],
    height: u64,
) -> Result<bool, String> {
    if q.code != 0
        || q.height.parse::<u64>().ok() != Some(height)
        || q.key.as_ref().and_then(|k| B64.decode(k).ok()).as_deref() != Some(key)
        || q.proof_ops.ops.len() != 2
    {
        return Err(INVALID.into());
    }
    let ops = &q.proof_ops.ops;
    if ops[0].r#type != "ics23:iavl"
        || ops[1].r#type != "ics23:simple"
        || B64.decode(&ops[0].key).map_err(|_| INVALID)? != key
        || B64.decode(&ops[1].key).map_err(|_| INVALID)? != b"vote"
    {
        return Err(INVALID.into());
    }
    let store = proof(&ops[1].data)?;
    let Some(ics23::commitment_proof::Proof::Exist(ex)) = &store.proof else {
        return Err(INVALID.into());
    };
    let root = ex.value.clone();
    if !ics23::verify_membership::<ics23::HostFunctionsManager>(
        &store,
        &ics23::tendermint_spec(),
        &app_hash.to_vec(),
        b"vote",
        &root,
    ) {
        return Err(INVALID.into());
    }
    let p = proof(&ops[0].data)?;
    let value = q
        .value
        .as_ref()
        .map(|v| B64.decode(v))
        .transpose()
        .map_err(|_| INVALID)?
        .unwrap_or_default();
    let valid = if value == [1] {
        ics23::verify_membership::<ics23::HostFunctionsManager>(
            &p,
            &ics23::iavl_spec(),
            &root,
            key,
            &[1],
        )
    } else if value.is_empty() {
        ics23::verify_non_membership::<ics23::HostFunctionsManager>(
            &p,
            &ics23::iavl_spec(),
            &root,
            key,
        )
    } else {
        false
    };
    if !valid {
        return Err(INVALID.into());
    }
    Ok(!value.is_empty())
}

pub fn verify(
    keys: &[String],
    network: &str,
    evidence: &str,
    now: i64,
) -> Result<Vec<bool>, String> {
    if evidence.len() > MAX_JSON || keys.len() > MAX_NOTES {
        return Err(INVALID.into());
    }
    let e: Evidence = serde_json::from_str(evidence).map_err(|_| INVALID)?;
    verify_header(&e.commit.result, &e.validators.result, network, now)?;
    if keys.len() != e.queries.len() {
        return Err(INVALID.into());
    }
    let h = &e.commit.result.signed_header.header;
    let height = h.height.value().checked_sub(1).ok_or(INVALID)?;
    keys.iter()
        .zip(&e.queries)
        .map(|(key, q)| {
            let key = hex::decode(key).map_err(|_| INVALID)?;
            if key.len() != 66 || key[..2] != [1, 0] {
                return Err(INVALID.into());
            }
            verify_query(&q.result.response, &key, h.app_hash.as_bytes(), height)
        })
        .collect()
}

/// Re-read the note set after network I/O, rejecting a changed restore/snapshot.
/// No remote result can mark a different account or note set as unavailable.
pub fn evaluate(
    db_path: &str,
    account: &str,
    network: &str,
    round: &str,
    snapshot: u64,
    fingerprint: &str,
    evidence: &str,
    now: i64,
    max_real_notes: Option<u32>,
) -> Result<String, String> {
    let (notes, candidates) = notes(db_path, account, network, round, snapshot)?;
    if candidates.fingerprint != fingerprint {
        return Err(INVALID.into());
    }
    let used = verify(&candidates.keys, network, evidence, now)?;
    let excluded: Vec<String> = notes
        .iter()
        .zip(&used)
        .filter_map(|(n, u)| u.then(|| hex::encode(&n.nullifier)))
        .collect();
    let remaining: Vec<_> = notes
        .into_iter()
        .zip(&used)
        .filter_map(|(n, used)| (!used).then_some(n))
        .collect();
    let policy = match max_real_notes {
        None => zcash_voting::recoverable_bundle_policy_v1(),
        Some(n) => zcash_voting::BundlePolicy::from_optional_max_real_notes_per_bundle(Some(n))
            .map_err(|_| INVALID)?,
    };
    let eligible = if remaining.is_empty() {
        false
    } else {
        zcash_voting::minimum_voting_eligibility_and_plan_for_notes(&remaining, policy)
            .map_err(|_| INVALID)?
            .0
            .is_eligible()
    };
    let local_state = save_exclusions(db_path, account, round, snapshot, &excluded)?;
    serde_json::to_string(&serde_json::json!({
        "localState": local_state,
        "fingerprint": fingerprint,
        "usedCount": used.iter().filter(|v| **v).count(),
        "noteCount": used.len(),
        "remainingEligible": eligible,
    }))
    .map_err(|_| INVALID.into())
}

const TABLE: &str = "CREATE TABLE IF NOT EXISTS vizor_voting_participation (
 wallet_id TEXT NOT NULL, round_id TEXT NOT NULL, snapshot INTEGER NOT NULL,
 excluded TEXT NOT NULL, PRIMARY KEY(wallet_id, round_id))";

fn save_exclusions(
    db_path: &str,
    account: &str,
    round: &str,
    snapshot: u64,
    excluded: &[String],
) -> Result<bool, String> {
    super::db::with_voting_sidecar_write_lock(db_path, || {
        let db = super::db::open_voting_db(db_path, account)?;
        db.conn().execute_batch(TABLE).map_err(|_| INVALID)?;
        // Never replan a round someone has already started locally, including
        // a concurrently prepared round. Existing recovery remains authoritative.
        if db.get_bundle_count(round).map_err(|_| INVALID)? > 0 {
            return Ok(true);
        }
        db.conn()
            .execute(
                "INSERT OR REPLACE INTO vizor_voting_participation VALUES (?1,?2,?3,?4)",
                rusqlite::params![
                    account,
                    round,
                    snapshot,
                    serde_json::to_string(excluded).map_err(|_| INVALID)?
                ],
            )
            .map_err(|_| INVALID)?;
        Ok(false)
    })
}

pub fn filter_notes(
    db: &zcash_voting::storage::VotingDb,
    round: &str,
    snapshot: u64,
    notes: &[NoteInfo],
) -> Result<Vec<NoteInfo>, String> {
    use rusqlite::OptionalExtension;
    let conn = db.conn();
    let exists: bool = conn.query_row("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='vizor_voting_participation')", [], |r| r.get(0)).map_err(|_| INVALID)?;
    if !exists {
        return Ok(notes.to_vec());
    }
    let excluded: Option<String> = conn.query_row("SELECT excluded FROM vizor_voting_participation WHERE wallet_id=?1 AND round_id=?2 AND snapshot=?3",
        rusqlite::params![db.wallet_id(),round,snapshot], |r| r.get(0)).optional().map_err(|_| INVALID)?;
    let Some(raw) = excluded else {
        return Ok(notes.to_vec());
    };
    let excluded: std::collections::HashSet<String> =
        serde_json::from_str(&raw).map_err(|_| INVALID)?;
    Ok(notes
        .iter()
        .filter(|n| !excluded.contains(&hex::encode(&n.nullifier)))
        .cloned()
        .collect())
}

pub fn clear_account(db: &zcash_voting::storage::VotingDb) -> Result<(), String> {
    let conn = db.conn();
    let exists: bool = conn.query_row("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='vizor_voting_participation')", [], |r| r.get(0)).map_err(|_| INVALID)?;
    if exists {
        conn.execute(
            "DELETE FROM vizor_voting_participation WHERE wallet_id=?1",
            [db.wallet_id()],
        )
        .map_err(|_| INVALID)?;
    }
    Ok(())
}

/// Assemble SDK bundles from the participation-filtered snapshot note set.
/// Keep proof/signature/witness algorithms owned by the pinned SDK.
pub fn prepare_bundle(
    db: &zcash_voting::storage::VotingDb,
    wallet: &crate::wallet::db::WalletDatabase,
    params: zcash_voting::delegate::PrepareDelegationBundleParams<'_>,
) -> Result<zcash_voting::delegate::PreparedDelegationBundle, zcash_voting::VotingError> {
    use zcash_voting::{delegate, selection, VotingError};
    let err = |message: String| VotingError::InvalidInput { message };
    let lwd = params.lwd;
    if lwd.network != params.voting_hotkey.network() {
        return Err(err("Voting network mismatch".into()));
    }
    delegate::ensure_round_context(
        db,
        lwd.network,
        &lwd.round_params,
        &lwd.resolved_round_name,
        params.session_json,
    )?;
    let scanned = wallet
        .block_fully_scanned()
        .map_err(|_| err(INVALID.into()))?
        .map(|m| u64::from(u32::from(m.block_height())))
        .unwrap_or(0);
    let inputs =
        selection::gather_delegation_wallet_inputs(selection::GatherDelegationWalletParams {
            wallet_db: wallet,
            account_uuid: params.account_uuid,
            voting_hotkey: params.voting_hotkey,
            snapshot_height: lwd.round_params.snapshot_height,
            scanned_height: scanned,
            anchor_tree_state_bytes: lwd.anchor_tree_state_bytes,
            resolved_round_name: lwd.resolved_round_name.clone(),
        })?;
    let round = lwd.round_params.vote_round_id.as_str();
    let notes = filter_notes(
        db,
        round,
        lwd.round_params.snapshot_height,
        &inputs.round_note_infos,
    )
    .map_err(err)?;
    let layout =
        db.ensure_bundles_with_skipped_suffix_with_policy(round, &notes, params.bundle_policy)?;
    let bundle_note_infos = zcash_voting::round::bundle_notes_for_index_for_round(
        &notes,
        &layout,
        params.bundle_index,
        db,
        round,
    )?;
    let prepared = delegate::PreparedDelegationBundle {
        round_id: round.to_string(),
        round_params: lwd.round_params,
        bundle_index: params.bundle_index,
        layout,
        bundle_note_infos,
        delegation_keys: inputs.delegation_keys,
        branch_id_provider: lwd.branch_id_provider,
        anchor_tree_state_bytes: inputs.anchor_tree_state_bytes,
        network: lwd.network,
        round_name: lwd.resolved_round_name,
    };
    prepared.ensure_witnesses(db, wallet)?;
    Ok(prepared)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture(network: &str) -> (serde_json::Value, Vec<String>, i64) {
        let text = match network {
            "main" => include_str!("../../../tests/fixtures/voting-participation/main.json"),
            _ => include_str!("../../../tests/fixtures/voting-participation/test.json"),
        };
        let value: serde_json::Value = serde_json::from_str(text).unwrap();
        let keys = serde_json::from_value(value["keys"].clone()).unwrap();
        let header: SignedHeader =
            serde_json::from_value(value["commit"]["result"]["signed_header"].clone()).unwrap();
        let now = header.header.time.unix_timestamp();
        (value, keys, now)
    }
    #[test]
    fn verifies_real_membership_and_absence_on_both_chains() {
        for network in ["main", "test"] {
            let (v, k, now) = fixture(network);
            assert_eq!(
                verify(&k, network, &v.to_string(), now).unwrap(),
                [true, false]
            );
        }
    }
    #[test]
    fn rejects_wrong_network_key_height_stale_and_modified_proofs() {
        let (v, k, now) = fixture("main");
        assert!(verify(&k, "test", &v.to_string(), now).is_err());
        assert!(verify(&k, "main", &v.to_string(), now + 601).is_err());
        assert!(verify(&k, "main", &v.to_string(), now - 61).is_err());
        let mut keys = k.clone();
        keys.reverse();
        assert!(verify(&keys, "main", &v.to_string(), now).is_err());
        for path in ["value", "height"] {
            let mut corrupt = v.clone();
            corrupt["queries"][0]["result"]["response"][path] = serde_json::json!("0");
            assert!(verify(&k, "main", &corrupt.to_string(), now).is_err());
        }
        let mut corrupt = v.clone();
        corrupt["queries"][0]["result"]["response"]["proofOps"]["ops"][0]["data"] =
            serde_json::json!("AA==");
        assert!(verify(&k, "main", &corrupt.to_string(), now).is_err());
        let mut corrupt = v.clone();
        corrupt["commit"]["result"]["signed_header"]["header"]["app_hash"] =
            serde_json::json!("00".repeat(32));
        assert!(verify(&k, "main", &corrupt.to_string(), now).is_err());
        let mut corrupt = v.clone();
        corrupt["validators"]["result"]["validators"][0]["voting_power"] = serde_json::json!("1");
        assert!(verify(&k, "main", &corrupt.to_string(), now).is_err());
        let mut corrupt = v.clone();
        corrupt["commit"]["result"]["signed_header"]["commit"]["signatures"][0]["signature"] =
            serde_json::json!(B64.encode([0; 64]));
        assert!(verify(&k, "main", &corrupt.to_string(), now).is_err());
    }
    #[test]
    fn exclusions_persist_and_never_rewrite_an_existing_bundle_plan() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("wallet.db");
        let path = path.to_str().unwrap();
        let account = super::super::test_support::TEST_ACCOUNT_UUID;
        let params = super::super::test_support::test_api_round_params();
        let first = super::super::test_support::test_note_info(1);
        let second = super::super::test_support::test_note_info(2);
        let excluded = vec![hex::encode(&first.nullifier)];
        assert!(!save_exclusions(path, account, &params.vote_round_id, 100, &excluded).unwrap());
        let db = super::super::db::open_voting_db(path, account).unwrap();
        db.ensure_round(zcash_voting::Network::Mainnet, &params, None)
            .unwrap();
        let remaining = filter_notes(
            &db,
            &params.vote_round_id,
            100,
            &[first.clone(), second.clone()],
        )
        .unwrap();
        assert_eq!(remaining.len(), 1);
        db.ensure_bundles_with_skipped_suffix_with_policy(
            &params.vote_round_id,
            &remaining,
            zcash_voting::recoverable_bundle_policy_v1(),
        )
        .unwrap();
        assert!(save_exclusions(
            path,
            account,
            &params.vote_round_id,
            100,
            &[hex::encode(&second.nullifier)]
        )
        .unwrap());
        let reopened = super::super::db::open_voting_db(path, account).unwrap();
        let unchanged = filter_notes(
            &reopened,
            &params.vote_round_id,
            100,
            &[first, second.clone()],
        )
        .unwrap();
        assert_eq!(unchanged[0].nullifier, second.nullifier);
    }

    #[test]
    fn filtering_is_scoped_and_account_cleanup_preserves_others() {
        let db = zcash_voting::storage::VotingDb::open_in_memory().unwrap();
        db.set_wallet_id("test-wallet");
        let wallet = db.wallet_id();
        db.conn().execute_batch(TABLE).unwrap();
        let first = super::super::test_support::test_note_info(1);
        let second = super::super::test_support::test_note_info(2);
        db.conn()
            .execute(
                "INSERT INTO vizor_voting_participation VALUES (?1,'round',100,?2)",
                rusqlite::params![
                    wallet,
                    serde_json::to_string(&vec![hex::encode(&first.nullifier)]).unwrap()
                ],
            )
            .unwrap();
        db.conn()
            .execute(
                "INSERT INTO vizor_voting_participation VALUES ('other','round',100,'[]')",
                [],
            )
            .unwrap();
        let notes = vec![first, second.clone()];
        assert_eq!(filter_notes(&db, "round", 100, &notes).unwrap().len(), 1);
        assert_eq!(filter_notes(&db, "round", 101, &notes).unwrap().len(), 2);
        assert_eq!(
            filter_notes(&db, "different", 100, &notes).unwrap().len(),
            2
        );
        clear_account(&db).unwrap();
        assert_eq!(filter_notes(&db, "round", 100, &notes).unwrap().len(), 2);
        let count: i64 = db
            .conn()
            .query_row("SELECT COUNT(*) FROM vizor_voting_participation", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(count, 1);
    }
}
