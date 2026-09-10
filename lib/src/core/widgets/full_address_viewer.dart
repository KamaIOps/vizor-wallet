import 'package:flutter/widgets.dart';

import '../theme/app_theme.dart';
import 'app_button.dart';
import 'app_copy_feedback.dart';
import 'app_icon.dart';

/// Exact string placed on the clipboard: trimmed, with no display spaces
/// or line breaks introduced for wrapping.
String fullAddressCopyText(String address) => address.trim();

/// Copies [address] without formatting spaces or line breaks and toasts
/// `Address copied`.
void copyFullAddress(BuildContext context, String address) {
  copyTextWithToast(
    context,
    text: fullAddressCopyText(address),
    toastMessage: 'Address copied',
  );
}

/// Continuous, wrapping Geist Mono address. Soft-wrap only — the string
/// itself stays unspaced so `O` / `0` sit in a fixed-width grid the eye
/// can scan, and a copy action can take the exact value.
class FullAddressText extends StatelessWidget {
  const FullAddressText({required this.address, this.color, super.key});

  final String address;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Text(
      fullAddressCopyText(address),
      key: const ValueKey('full_address_text'),
      softWrap: true,
      style: AppTypography.codeMedium.copyWith(
        color: color ?? context.colors.text.primary,
      ),
    );
  }
}

/// Primary Copy address action used by the full-address viewer.
class FullAddressCopyButton extends StatelessWidget {
  const FullAddressCopyButton({
    required this.address,
    this.expand = false,
    this.size = AppButtonSize.mediumLarge,
    super.key,
  });

  final String address;
  final bool expand;
  final AppButtonSize size;

  @override
  Widget build(BuildContext context) {
    return AppButton(
      key: const ValueKey('full_address_copy_button'),
      onPressed: () => copyFullAddress(context, address),
      variant: AppButtonVariant.primary,
      size: size,
      expand: expand,
      minWidth: kFullAddressCopyActionMinWidth,
      leading: const AppIcon(AppIcons.copy),
      child: const Text('Copy address'),
    );
  }
}

/// Minimum width for the labeled Copy address action, matching the
/// shared modal button floor.
const kFullAddressCopyActionMinWidth = 96.0;
