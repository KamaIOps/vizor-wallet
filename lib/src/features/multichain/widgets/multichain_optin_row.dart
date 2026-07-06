import 'package:flutter/widgets.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_icon.dart';
import '../../../core/widgets/app_tappable.dart';

/// Opt-in row for multichain balances, shown on the wallet create/import
/// final step (software flows only — hardware accounts have no seed on the
/// device to derive other chains from).
class MultichainOptInRow extends StatelessWidget {
  const MultichainOptInRow({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = AppLocalizations.of(context);

    return AppTappable(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: colors.background.neutralSubtleOpacity,
          borderRadius: BorderRadius.circular(AppRadii.small),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 20,
              height: 20,
              margin: const EdgeInsets.only(top: 1),
              decoration: BoxDecoration(
                color: value
                    ? colors.background.inverse
                    : colors.background.neutralSubtleOpacity,
                borderRadius: BorderRadius.circular(AppRadii.xSmall / 2),
              ),
              alignment: Alignment.center,
              child: value
                  ? AppIcon(
                      AppIcons.check,
                      size: 14,
                      color: colors.text.inverse,
                    )
                  : null,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.multichainOptInTitle,
                    style: AppTypography.labelLarge.copyWith(
                      color: colors.text.accent,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xxs),
                  Text(
                    l10n.multichainOptInSubtitle,
                    style: AppTypography.bodySmall.copyWith(
                      color: colors.text.secondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
