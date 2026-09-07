part of 'payment_link_service.dart';

/// Receipt display follows normal Receive at one confirmation. Recovery ends
/// only after six scanned confirmations, without holding the receipt UI open.
@visibleForTesting
Future<void> reconcilePaymentLinkClaimReceipt({
  required PaymentLinkReceivedRecord record,
  required List<rust_sync.TransactionInfo> transactions,
  required BigInt verifiedHeight,
  required PaymentLinkReceivedStore store,
  required Future<bool> Function(PaymentLinkReceivedRecord)
  deleteRetainedWallet,
}) async {
  final status = paymentLinkReceivedStatusForTransactions(
    claimTxids: record.claimTxids!,
    transactions: transactions,
    chainTipHeight: verifiedHeight,
  );
  switch (status) {
    case PaymentLinkReceivedStatus.readyToClaim:
      await store.markReadyToClaim(address: record.address);
    case PaymentLinkReceivedStatus.submitting:
      throw StateError(
        'Receipt reconciliation cannot produce submitting state.',
      );
    case PaymentLinkReceivedStatus.receiving:
      // A shallow reorg can unmine an already displayed receipt. Its secret
      // and retained wallet are still available for recovery at this point.
      if (record.status == PaymentLinkReceivedStatus.received) {
        await store.markReceiving(
          address: record.address,
          destinationAccountUuid: record.destinationAccountUuid!,
          claimTxids: record.claimTxids!,
        );
      }
    case PaymentLinkReceivedStatus.received:
      if (record.status != PaymentLinkReceivedStatus.received) {
        await store.markReceived(address: record.address);
      }
      final recoveryStatus = paymentLinkReceivedStatusForTransactions(
        claimTxids: record.claimTxids!,
        transactions: transactions,
        chainTipHeight: verifiedHeight,
        confirmationTarget: kPaymentLinkClaimRecoveryConfirmationTarget,
      );
      if (recoveryStatus == PaymentLinkReceivedStatus.received) {
        await finalizeConfirmedPaymentLinkClaim(
          record: record,
          deleteRetainedWallet: deleteRetainedWallet,
          clearClaimSecret: (address) =>
              store.clearConfirmedClaimSecret(address: address),
        );
      }
  }
}
