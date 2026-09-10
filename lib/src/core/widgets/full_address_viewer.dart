import 'package:flutter/widgets.dart';

import '../theme/app_theme.dart';
import 'app_button.dart';
import 'app_copy_feedback.dart';
import 'app_icon.dart';

/// How the full-address viewer presents the copy control.
///
/// Two design directions for VZR-152:
///
/// * [codeBlock] — recessed monospace surface with an inline Copy chip.
///   Copy sits on the address itself, like a code snippet.
/// * [actionFooter] — wrapping monospace body with Copy address as the
///   primary modal action. Copy is the reason the sheet is open.
enum FullAddressViewerLayout {
  /// Recessed monospace block with an inline Copy chip on the address surface.
  codeBlock,

  /// Wrapping monospace body with Copy address as a primary footer action.
  actionFooter,
}

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

/// Visible copy control used by both layouts. [compact] is the inline chip
/// on a code block; the default is the labeled modal/sheet action.
class FullAddressCopyButton extends StatelessWidget {
  const FullAddressCopyButton({
    required this.address,
    this.compact = false,
    this.expand = false,
    super.key,
  });

  final String address;
  final bool compact;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    return AppButton(
      key: const ValueKey('full_address_copy_button'),
      onPressed: () => copyFullAddress(context, address),
      variant: compact ? AppButtonVariant.ghost : AppButtonVariant.primary,
      size: compact ? AppButtonSize.small : AppButtonSize.mediumLarge,
      expand: expand,
      minWidth: compact ? null : kFullAddressCopyActionMinWidth,
      leading: const AppIcon(AppIcons.copy),
      child: Text(compact ? 'Copy' : 'Copy address'),
    );
  }
}

/// Minimum width for the labeled Copy address action, matching the
/// shared modal button floor.
const kFullAddressCopyActionMinWidth = 96.0;

/// Address body for [FullAddressViewerLayout]: a recessed code block with
/// an inline Copy chip, or plain wrapping monospace text.
class FullAddressBody extends StatelessWidget {
  const FullAddressBody({
    required this.address,
    required this.layout,
    super.key,
  });

  final String address;
  final FullAddressViewerLayout layout;

  @override
  Widget build(BuildContext context) {
    final text = FullAddressText(address: address);
    if (layout == FullAddressViewerLayout.actionFooter) {
      return text;
    }

    final colors = context.colors;
    return DecoratedBox(
      key: const ValueKey('full_address_code_block'),
      decoration: BoxDecoration(
        color: colors.background.raised,
        borderRadius: BorderRadius.circular(AppRadii.small),
        border: Border.all(color: colors.border.subtle),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.s,
          AppSpacing.s,
          AppSpacing.s,
          AppSpacing.xs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            text,
            const SizedBox(height: AppSpacing.xs),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FullAddressCopyButton(address: address, compact: true),
            ),
          ],
        ),
      ),
    );
  }
}
