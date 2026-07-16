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
import '../domain/multichain_chain.dart';
import '../providers/multichain_providers.dart';

/// Multichain balances: one row per active account (chain + derivation
/// variant) with the derived address, an on-demand balance, and a send
/// entry point. Alternate derivations of the same seed (other coin types,
/// BTC legacy) are probed in the background and surface automatically as
/// additional accounts when they hold funds.
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

  final Map<MultichainAccountRef, String> addresses;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final l10n = AppLocalizations.of(context);
    final chains = ref.watch(multichainActiveChainsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.sm),
        Text(
          l10n.multichainTitle,
          textAlign: TextAlign.center,
          style: AppTypography.headlineLarge.copyWith(
            color: colors.text.accent,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          l10n.multichainPublicChainsNote,
          textAlign: TextAlign.center,
          style: AppTypography.bodyMedium.copyWith(
            color: colors.text.secondary,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Center(
          child: AppButton(
            variant: AppButtonVariant.secondary,
            size: AppButtonSize.small,
            onPressed: () => context.go('/multichain/add'),
            child: Text(l10n.multichainAddChain),
          ),
        ),
        const SizedBox(height: AppSpacing.base),
        for (final chain in chains) _ChainSection(chain: chain, addresses: addresses),
      ],
    );
  }
}

/// One chain's selected account row plus auto-detected funded variants.
class _ChainSection extends ConsumerWidget {
  const _ChainSection({required this.chain, required this.addresses});

  final MultichainChain chain;
  final Map<MultichainAccountRef, String> addresses;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(multichainSelectedRefProvider(chain));
    final selectedAddress = addresses[selected];
    if (selectedAddress == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _AccountRow(accountRef: selected, address: selectedAddress),
        const SizedBox(height: AppSpacing.sm),
        for (final variant in multichainVariantRefs(selected))
          if (addresses.containsKey(variant))
            _FundedVariantProbe(
              accountRef: variant,
              address: addresses[variant]!,
            ),
      ],
    );
  }
}

/// Renders a full account row for an alternate derivation only when it
/// holds funds — this is how extra coin-type/path accounts appear
/// automatically for seeds that used several derivations.
class _FundedVariantProbe extends ConsumerWidget {
  const _FundedVariantProbe({required this.accountRef, required this.address});

  final MultichainAccountRef accountRef;
  final String address;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final balance = ref.watch(multichainBalanceProvider(accountRef));
    final funded = switch (balance) {
      AsyncData(:final value) => value,
      _ => null,
    };
    if (funded == null || funded == BigInt.zero) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _AccountRow(accountRef: accountRef, address: address, isVariant: true),
        const SizedBox(height: AppSpacing.sm),
      ],
    );
  }
}

class _AccountRow extends ConsumerWidget {
  const _AccountRow({
    required this.accountRef,
    required this.address,
    this.isVariant = false,
  });

  final MultichainAccountRef accountRef;
  final String address;

  /// True for auto-detected alternate-derivation rows.
  final bool isVariant;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final l10n = AppLocalizations.of(context);
    final chain = accountRef.chain;
    final balance = ref.watch(multichainBalanceProvider(accountRef));
    final derivation = multichainDerivationLabel(accountRef);
    final showChips = !isVariant &&
        chain.family == MultichainFamily.cosmos &&
        chain.cosmosCoinTypeCandidates.length > 1;

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
                  derivation.isEmpty || (!isVariant && !showChips)
                      ? '${chain.displayName} (${chain.symbol})'
                      : '${chain.displayName} (${chain.symbol}) · $derivation',
                  style: AppTypography.labelLarge.copyWith(
                    color: colors.text.accent,
                  ),
                  overflow: TextOverflow.ellipsis,
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
          if (showChips) ...[
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: [
                for (final candidate in chain.cosmosCoinTypeCandidates)
                  AppButton(
                    variant: candidate == accountRef.coinType
                        ? AppButtonVariant.primary
                        : AppButtonVariant.ghost,
                    size: AppButtonSize.small,
                    onPressed: () => ref
                        .read(multichainCoinTypesProvider.notifier)
                        .select(chain, candidate),
                    child: Text("m/44'/$candidate'"),
                  ),
              ],
            ),
          ],
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
                    ref.invalidate(multichainBalanceProvider(accountRef)),
                child: Text(l10n.multichainRefresh),
              ),
              const SizedBox(width: AppSpacing.xs),
              AppButton(
                variant: AppButtonVariant.primary,
                size: AppButtonSize.small,
                onPressed: () => context.go(
                  Uri(
                    path: '/multichain/send/${chain.name}',
                    queryParameters: {
                      if (accountRef.coinType != null)
                        'ct': '${accountRef.coinType}',
                      if (accountRef.btcLegacy) 'legacy': '1',
                    },
                  ).toString(),
                ),
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
