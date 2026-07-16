import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../core/layout/app_desktop_shell.dart';
import '../../../core/layout/app_main_sidebar.dart';
import '../../../core/layout/app_pane_scroll_scaffold.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_text_field.dart';
import '../domain/multichain_chain.dart';
import '../providers/multichain_providers.dart';

/// Maximum search results rendered at once (the catalog holds ~1600 chains).
const int kMultichainSearchResultCap = 50;

/// Browse the full EVM + Cosmos chain catalog and enable chains manually.
/// Built-in defaults are always active; added chains are persisted per
/// wallet and appear on the multichain balances screen.
class MultichainAddChainScreen extends ConsumerStatefulWidget {
  const MultichainAddChainScreen({super.key});

  @override
  ConsumerState<MultichainAddChainScreen> createState() =>
      _MultichainAddChainScreenState();
}

class _MultichainAddChainScreenState
    extends ConsumerState<MultichainAddChainScreen> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<MultichainChain> _matches(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    return [
      for (final chain in MultichainChain.catalog)
        if (chain.displayName.toLowerCase().contains(needle) ||
            chain.symbol.toLowerCase().contains(needle) ||
            chain.name.toLowerCase().contains(needle))
          chain,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = AppLocalizations.of(context);
    final custom =
        ref.watch(multichainCustomChainsProvider).value ?? const <String>[];
    final query = _searchController.text;
    final matches = _matches(query);
    final capped = matches.length > kMultichainSearchResultCap
        ? matches.sublist(0, kMultichainSearchResultCap)
        : matches;

    return AppDesktopShell(
      sidebar: const AppMainSidebar(),
      pane: AppDesktopPane(
        padding: EdgeInsets.zero,
        child: AppPaneScrollScaffold(
          toolbar: const AppPaneToolbar(backLinkMinWidth: 60),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: AppSpacing.sm),
              Text(
                l10n.multichainAddChainTitle,
                textAlign: TextAlign.center,
                style: AppTypography.headlineLarge.copyWith(
                  color: colors.text.accent,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                l10n.multichainAddChainNote(
                  MultichainChain.catalog.length,
                ),
                textAlign: TextAlign.center,
                style: AppTypography.bodyMedium.copyWith(
                  color: colors.text.secondary,
                ),
              ),
              const SizedBox(height: AppSpacing.base),
              AppTextField(
                label: l10n.multichainSearchChainsLabel,
                controller: _searchController,
                hintText: l10n.multichainSearchChainsHint,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: AppSpacing.base),
              if (query.trim().isEmpty) ...[
                if (custom.isNotEmpty) ...[
                  Text(
                    l10n.multichainAddedChainsHeader,
                    style: AppTypography.labelLarge.copyWith(
                      color: colors.text.accent,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  for (final name in custom)
                    if (MultichainChain.byName(name) != null) ...[
                      _CatalogRow(
                        chain: MultichainChain.byName(name)!,
                        added: true,
                        builtIn: false,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                    ],
                ],
              ] else if (capped.isEmpty) ...[
                Text(
                  l10n.multichainNoSearchResults,
                  textAlign: TextAlign.center,
                  style: AppTypography.bodyMedium.copyWith(
                    color: colors.text.muted,
                  ),
                ),
              ] else ...[
                for (final chain in capped) ...[
                  _CatalogRow(
                    chain: chain,
                    added: custom.contains(chain.name),
                    builtIn: MultichainChain.builtIns.contains(chain),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                ],
                if (matches.length > capped.length) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    l10n.multichainRefineSearch(matches.length),
                    textAlign: TextAlign.center,
                    style: AppTypography.bodySmall.copyWith(
                      color: colors.text.muted,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CatalogRow extends ConsumerWidget {
  const _CatalogRow({
    required this.chain,
    required this.added,
    required this.builtIn,
  });

  final MultichainChain chain;
  final bool added;
  final bool builtIn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final l10n = AppLocalizations.of(context);
    final familyLabel = switch (chain.family) {
      MultichainFamily.evm => 'EVM',
      MultichainFamily.cosmos => 'Cosmos',
      MultichainFamily.utxo => 'UTXO',
      MultichainFamily.sol => 'Solana',
      MultichainFamily.sui => 'Sui',
      MultichainFamily.aptos => 'Aptos',
    };

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.base,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.background.neutralSubtleOpacity,
        borderRadius: BorderRadius.circular(AppRadii.medium),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${chain.displayName} (${chain.symbol})',
                  style: AppTypography.labelLarge.copyWith(
                    color: colors.text.accent,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppSpacing.xxs),
                Text(
                  familyLabel,
                  style: AppTypography.bodySmall.copyWith(
                    color: colors.text.muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          if (builtIn)
            Text(
              l10n.multichainBuiltInChain,
              style: AppTypography.bodySmall.copyWith(
                color: colors.text.muted,
              ),
            )
          else
            AppButton(
              variant: added
                  ? AppButtonVariant.secondary
                  : AppButtonVariant.primary,
              size: AppButtonSize.small,
              onPressed: () => added
                  ? ref
                        .read(multichainCustomChainsProvider.notifier)
                        .remove(chain.name)
                  : ref
                        .read(multichainCustomChainsProvider.notifier)
                        .add(chain.name),
              child: Text(
                added ? l10n.multichainRemoveChain : l10n.multichainAddChain,
              ),
            ),
        ],
      ),
    );
  }
}
