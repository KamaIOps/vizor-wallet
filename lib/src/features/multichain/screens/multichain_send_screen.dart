import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../../main.dart' show log;
import '../../../core/layout/app_desktop_shell.dart';
import '../../../core/layout/app_main_sidebar.dart';
import '../../../core/layout/app_pane_scroll_scaffold.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../providers/account_provider.dart';
import '../domain/multichain_chain.dart';
import '../providers/multichain_providers.dart';
import '../services/multichain_services.dart';

/// Send flow for a non-ZEC public chain: recipient + amount → fee preview →
/// confirm → sign (Rust) → broadcast → txid.
///
/// The mnemonic is read from secure storage only at the moment of signing
/// and passed straight to Rust, mirroring the ZEC send path.
class MultichainSendScreen extends ConsumerStatefulWidget {
  const MultichainSendScreen({
    super.key,
    required this.chain,
    this.coinType,
    this.btcLegacy = false,
  });

  final MultichainChain chain;

  /// Cosmos derivation coin type (defaults to the chain's registry value).
  final int? coinType;

  /// Spend from Bitcoin's BIP-44 legacy derivation.
  final bool btcLegacy;

  @override
  ConsumerState<MultichainSendScreen> createState() =>
      _MultichainSendScreenState();
}

enum _SendPhase { edit, previewing, confirm, sending, sent }

class _MultichainSendScreenState extends ConsumerState<MultichainSendScreen> {
  final _recipientController = TextEditingController();
  final _amountController = TextEditingController();

  _SendPhase _phase = _SendPhase.edit;
  MultichainSendPreview? _preview;
  String? _error;
  String? _txid;

  /// Selected IBC destination; null = same-chain send. Only offered for
  /// cosmos-family chains with verified routes.
  IbcRoute? _ibcRoute;

  List<IbcRoute> get _ibcRoutes => ibcRoutesFrom(widget.chain);

  MultichainAccountRef get _accountRef => multichainRefFor(
    widget.chain,
    coinType: widget.coinType,
    btcLegacy: widget.btcLegacy,
  );

  MultichainService get _service => multichainServiceFor(
    widget.chain,
    ref.read(multichainRpcProvider),
    cosmosCoinType: _accountRef.coinType,
    btcLegacy: _accountRef.btcLegacy,
  );

  @override
  void dispose() {
    _recipientController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  BigInt? get _amountBaseUnits =>
      parseMultichainAmount(_amountController.text, widget.chain.decimals);

  bool get _inputsValid =>
      _recipientController.text.trim().isNotEmpty &&
      (_amountBaseUnits ?? BigInt.zero) > BigInt.zero;

  Future<void> _previewFee() async {
    if (!_inputsValid || _phase != _SendPhase.edit) return;
    setState(() {
      _phase = _SendPhase.previewing;
      _error = null;
    });
    final unavailableMessage =
        AppLocalizations.of(context).multichainUnavailable;
    try {
      final addresses = await ref.read(multichainAddressesProvider.future);
      if (addresses == null) {
        throw MultichainRpcExceptionText(unavailableMessage);
      }
      final service = _service;
      final route = _ibcRoute;
      final preview = route != null
          ? await (service as CosmosService).previewIbcSend(
              fromAddress: multichainAddressFor(addresses, _accountRef),
              route: route,
            )
          : await service.previewSend(
              fromAddress: multichainAddressFor(addresses, _accountRef),
              toAddress: _recipientController.text.trim(),
              amountBaseUnits: _amountBaseUnits!,
            );
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _phase = _SendPhase.confirm;
      });
    } catch (e, st) {
      log('MultichainSendScreen._previewFee: ERROR: $e\n$st');
      if (!mounted) return;
      setState(() {
        _phase = _SendPhase.edit;
        _error = '$e';
      });
    }
  }

  Future<void> _send() async {
    final preview = _preview;
    if (preview == null || _phase != _SendPhase.confirm) return;
    setState(() {
      _phase = _SendPhase.sending;
      _error = null;
    });
    final unavailableMessage =
        AppLocalizations.of(context).multichainUnavailable;
    try {
      final addresses = await ref.read(multichainAddressesProvider.future);
      final mnemonic = await ref
          .read(accountProvider.notifier)
          .getActiveMnemonic();
      if (addresses == null || mnemonic == null) {
        throw MultichainRpcExceptionText(unavailableMessage);
      }
      final service = _service;
      final route = _ibcRoute;
      final txid = route != null
          ? await (service as CosmosService).sendIbc(
              mnemonic: mnemonic,
              toAddress: _recipientController.text.trim(),
              amountBaseUnits: _amountBaseUnits!,
              preview: preview,
              route: route,
            )
          : await service.send(
              mnemonic: mnemonic,
              fromAddress: multichainAddressFor(addresses, _accountRef),
              toAddress: _recipientController.text.trim(),
              amountBaseUnits: _amountBaseUnits!,
              preview: preview,
            );
      if (!mounted) return;
      setState(() {
        _txid = txid;
        _phase = _SendPhase.sent;
      });
      ref.invalidate(multichainBalanceProvider(_accountRef));
    } catch (e, st) {
      log('MultichainSendScreen._send: ERROR: $e\n$st');
      if (!mounted) return;
      setState(() {
        // Back to confirm: the preview (nonce/UTXOs/blockhash) may be stale
        // after a failure, so a retry goes through preview again.
        _phase = _SendPhase.edit;
        _preview = null;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = AppLocalizations.of(context);
    final chain = widget.chain;

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
                l10n.multichainSendTitle(chain.symbol),
                textAlign: TextAlign.center,
                style: AppTypography.headlineLarge.copyWith(
                  color: colors.text.accent,
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                l10n.multichainPublicChainLabel,
                textAlign: TextAlign.center,
                style: AppTypography.bodySmall.copyWith(
                  color: colors.text.muted,
                ),
              ),
              const SizedBox(height: AppSpacing.base),
              if (_phase == _SendPhase.sent) ...[
                _SentPanel(txid: _txid ?? '', chain: chain),
              ] else ...[
                if (_ibcRoutes.isNotEmpty) ...[
                  Text(
                    l10n.multichainDestinationLabel,
                    style: AppTypography.labelLarge.copyWith(
                      color: colors.text.accent,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Wrap(
                    spacing: AppSpacing.xs,
                    runSpacing: AppSpacing.xs,
                    children: [
                      for (final option in <IbcRoute?>[null, ..._ibcRoutes])
                        AppButton(
                          variant: _ibcRoute == option
                              ? AppButtonVariant.primary
                              : AppButtonVariant.secondary,
                          size: AppButtonSize.small,
                          onPressed: _phase == _SendPhase.edit
                              ? () => setState(() {
                                  _ibcRoute = option;
                                  _error = null;
                                  _preview = null;
                                })
                              : null,
                          child: Text(
                            option == null
                                ? l10n.multichainDestinationSameChain
                                : option.to.displayName,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
                AppTextField(
                  label: l10n.multichainRecipientLabel,
                  controller: _recipientController,
                  hintText: l10n.multichainRecipientHint(
                    (_ibcRoute?.to ?? chain).displayName,
                  ),
                  enabled: _phase == _SendPhase.edit,
                  onChanged: (_) => setState(() {
                    _error = null;
                    _preview = null;
                  }),
                ),
                const SizedBox(height: AppSpacing.sm),
                AppTextField(
                  label: l10n.multichainAmountLabel,
                  controller: _amountController,
                  hintText: l10n.multichainAmountHint(chain.symbol),
                  enabled: _phase == _SendPhase.edit,
                  onChanged: (_) => setState(() {
                    _error = null;
                    _preview = null;
                  }),
                ),
                const SizedBox(height: AppSpacing.base),
                if (_preview != null) ...[
                  Text(
                    l10n.multichainFeeLine(_preview!.feeText),
                    style: AppTypography.bodyMedium.copyWith(
                      color: colors.text.secondary,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
                if (_error != null) ...[
                  Text(
                    _error!,
                    style: AppTypography.bodyMedium.copyWith(
                      color: colors.text.destructive,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
                switch (_phase) {
                  _SendPhase.edit || _SendPhase.previewing => AppButton(
                    variant: AppButtonVariant.primary,
                    onPressed: _inputsValid && _phase == _SendPhase.edit
                        ? _previewFee
                        : null,
                    child: Text(
                      _phase == _SendPhase.previewing
                          ? l10n.multichainEstimatingFee
                          : l10n.multichainPreviewSend,
                    ),
                  ),
                  _SendPhase.confirm || _SendPhase.sending => AppButton(
                    variant: AppButtonVariant.primary,
                    onPressed: _phase == _SendPhase.confirm ? _send : null,
                    child: Text(
                      _phase == _SendPhase.sending
                          ? l10n.multichainSending
                          : l10n.multichainConfirmSend,
                    ),
                  ),
                  _SendPhase.sent => const SizedBox.shrink(),
                },
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SentPanel extends StatelessWidget {
  const _SentPanel({required this.txid, required this.chain});

  final String txid;
  final MultichainChain chain;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.multichainSentSuccess(chain.symbol),
          textAlign: TextAlign.center,
          style: AppTypography.bodyLarge.copyWith(color: colors.text.accent),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          txid,
          textAlign: TextAlign.center,
          style: AppTypography.bodySmall.copyWith(
            color: colors.text.secondary,
          ),
        ),
        const SizedBox(height: AppSpacing.base),
        AppButton(
          variant: AppButtonVariant.secondary,
          onPressed: () => GoRouter.of(context).go('/multichain'),
          child: Text(l10n.multichainBackToBalances),
        ),
      ],
    );
  }
}

/// Small helper so user-facing availability errors read cleanly (no
/// "Exception:" prefix).
class MultichainRpcExceptionText implements Exception {
  MultichainRpcExceptionText(this.message);
  final String message;

  @override
  String toString() => message;
}
