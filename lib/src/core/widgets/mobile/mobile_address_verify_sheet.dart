import 'package:flutter/widgets.dart';

import '../../layout/mobile/app_mobile_sheet.dart';
import '../../theme/app_theme.dart';
import '../full_address_viewer.dart';

/// Full-address verification sheet — identity title on top, a continuous
/// wrapping Geist Mono address, a visible copy control, and a Cancel
/// action. [layout] selects the recessed code-block treatment or the
/// primary Copy address footer.
Future<void> showMobileAddressVerifySheet(
  BuildContext context, {
  required String title,
  required String address,
  Widget? leading,
  FullAddressViewerLayout layout = FullAddressViewerLayout.codeBlock,
}) {
  return showAppMobileSheet<void>(
    context: context,
    builder: (sheetContext) {
      return MobileAddressVerifySheet(
        title: title,
        address: address,
        leading: leading,
        layout: layout,
        onClose: () => Navigator.of(sheetContext).pop(),
      );
    },
  );
}

/// Sheet body extracted so Widgetbook / figma-compare can render either
/// layout without opening a route.
class MobileAddressVerifySheet extends StatelessWidget {
  const MobileAddressVerifySheet({
    required this.title,
    required this.address,
    required this.onClose,
    this.leading,
    this.layout = FullAddressViewerLayout.codeBlock,
    super.key,
  });

  final String title;
  final String address;
  final Widget? leading;
  final FullAddressViewerLayout layout;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MobileModalScaffold(
      title: title,
      leading: leading,
      titleStyle: AppTypography.labelLarge.copyWith(
        fontWeight: FontWeight.w600,
        color: colors.text.accent,
      ),
      bodyGap: AppSpacing.md,
      bottomPadding: AppSpacing.base,
      onClose: onClose,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            key: const ValueKey('mobile_address_verify_chunks'),
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s),
            child: FullAddressBody(address: address, layout: layout),
          ),
          const SizedBox(height: AppSpacing.md),
          if (layout == FullAddressViewerLayout.actionFooter) ...[
            FullAddressCopyButton(address: address, expand: true),
            const SizedBox(height: AppSpacing.xs),
          ],
          _MobileAddressVerifyCancel(onTap: onClose),
        ],
      ),
    );
  }
}

class _MobileAddressVerifyCancel extends StatelessWidget {
  const _MobileAddressVerifyCancel({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          height: AppButtonSizing.largeHeight,
          child: Center(
            child: Text(
              'Cancel',
              style: AppTypography.labelLarge.copyWith(
                color: context.colors.text.primary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
