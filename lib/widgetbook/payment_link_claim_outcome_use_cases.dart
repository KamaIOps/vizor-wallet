import 'package:flutter/widgets.dart';
import '../src/core/layout/app_desktop_shell.dart';
import '../src/core/layout/app_form_factor.dart';
import '../src/features/payment_links/services/payment_link_received_store.dart';
import '../src/features/payment_links/widgets/payment_link_claim_outcome_view.dart';

Widget buildClaimNoBalanceUseCase(BuildContext context) =>
    _outcome(PaymentLinkAvailability.noBalance);
Widget buildClaimedElsewhereUseCase(BuildContext context) =>
    _outcome(PaymentLinkAvailability.claimedElsewhere);
Widget buildClaimFailedUseCase(BuildContext context) =>
    _outcome(PaymentLinkAvailability.failed);
Widget buildClaimCheckingUseCase(BuildContext context) =>
    _outcome(PaymentLinkAvailability.checking);
Widget _outcome(PaymentLinkAvailability availability) {
  final view = PaymentLinkClaimOutcomeView(
    availability: availability,
    onBack: () {},
    onCheck: () {},
    onArchive: availability == PaymentLinkAvailability.checking ? null : () {},
  );
  return kAppFormFactor == AppFormFactor.mobile
      ? view
      : AppDesktopPane(padding: EdgeInsets.zero, child: view);
}
