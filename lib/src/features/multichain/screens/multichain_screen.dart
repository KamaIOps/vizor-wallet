import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../core/layout/app_desktop_shell.dart';
import '../../../core/layout/app_main_sidebar.dart';
import '../../../core/layout/app_pane_scroll_scaffold.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_copy_feedback.dart';
import '../../../rust/api/chains.dart' as rust;
import '../domain/multichain_chain.dart';
import '../providers/multichain_providers.dart';

/// Multichain balances: one row per public chain with the account's derived
/// address, an on-demand balance, and a send entry point.
class MultichainScreen extends ConsumerWidget {
  const MultichainScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final addresses = ref.watch(multichainAddressesProvider);

    return AppDesktopShell(
      sidebar: const AppMainSidebar(),
      pane: AppDesktopPane(
        padding: EdgeInsets.zero,
        child: AppPaneScrollScaffold(
          toolbar: const AppPaneToolbar(backLinkMinWidth: 60),
          child: switch (addresses) {
            AsyncData(value: final resolved) when resolved != null =>
              _MultichainList(addresses: resolved),
            AsyncData() => _CenteredNote(
              AppLocalizations.of(context).multichainUnavailable,
            ),
            AsyncError(:final error) => _CenteredNote('$error'),
            _ => const _CenteredNote(''),
          },
        ),
      ),
    );
  }
}

class _MultichainList extends ConsumerWidget {
  const _MultichainList({required this.addresses});

  final rust.MultichainAddresses addresses;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.sm),
        Text(
          AppLocalizations.of(context).multichainTitle,
          textAlign: TextAlign.center,
          style: AppTypography.headlineLarge.copyWith(
            color: colors.text.accent,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.base),
          child: Text(
            AppLocalizations.of(context).multichainPublicChainsNote,
            textAlign: TextAlign.center,
            style: AppTypography.bodyMedium.copyWith(
              color: colors.text.secondary,
            ),
          ),
        ),
        for (final chain in MultichainChain.values) ...[
          _ChainRow(
            chain: chain,
            address: multichainAddressFor(addresses, chain),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }
}

class _ChainRow extends ConsumerWidget {
  const _ChainRow({required this.chain, required this.address});

  final MultichainChain chain;
  final String address;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final l10n = AppLocalizations.of(context);
    final balance = ref.watch(multichainBalanceProvider(chain));

    return Container(
      padding: const EdgeInsets.all(AppSpacing.base),
      decoration: BoxDecoration(
        color: colors.background.neutralSubtleOpacity,
        borderRadius: BorderRadius.circular(AppRadii.medium),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${chain.displayName} (${chain.symbol})',
                  style: AppTypography.labelLarge.copyWith(
                    color: colors.text.accent,
                  ),
                ),
              ),
              Text(
                switch (balance) {
                  AsyncData(:final value) =>
                    '${formatMultichainAmount(value, chain.decimals)} '
                        '${chain.symbol}',
                  AsyncError() => l10n.multichainBalanceError,
                  _ => '…',
                },
                style: AppTypography.labelLarge.copyWith(
                  color: balance is AsyncError
                      ? colors.text.destructive
                      : colors.text.accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xxs),
          Text(
            l10n.multichainPublicChainLabel,
            style: AppTypography.bodySmall.copyWith(color: colors.text.muted),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: Text(
                  address,
                  style: AppTypography.bodySmall.copyWith(
                    color: colors.text.secondary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              AppButton(
                variant: AppButtonVariant.secondary,
                size: AppButtonSize.small,
                onPressed: () => copyTextWithToast(
                  context,
                  text: address,
                  toastMessage: l10n.multichainAddressCopied(chain.symbol),
                ),
                child: Text(l10n.commonCopy),
              ),
              const SizedBox(width: AppSpacing.xs),
              AppButton(
                variant: AppButtonVariant.ghost,
                size: AppButtonSize.small,
                onPressed: () =>
                    ref.invalidate(multichainBalanceProvider(chain)),
                child: Text(l10n.multichainRefresh),
              ),
              const SizedBox(width: AppSpacing.xs),
              AppButton(
                variant: AppButtonVariant.primary,
                size: AppButtonSize.small,
                onPressed: () => context.go('/multichain/send/${chain.name}'),
                child: Text(l10n.multichainSend),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CenteredNote extends StatelessWidget {
  const _CenteredNote(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Center(
        child: Text(
          message,
          style: AppTypography.bodyMedium.copyWith(
            color: colors.text.secondary,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
