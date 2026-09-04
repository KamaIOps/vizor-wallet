import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/app_theme_host.dart';
import 'package:zcash_wallet/src/features/donation/widgets/donation_views.dart';

Widget _host(Widget child) => MaterialApp(
  home: AppThemeHost(
    themeMode: ThemeMode.light,
    child: Scaffold(body: child),
  ),
);

void main() {
  testWidgets('composer exposes presets and disables empty continue', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _host(
        SizedBox(
          height: 672,
          child: DonationComposeView(
            controller: controller,
            mode: DonationAmountMode.zec,
            conversionText: r'$ 0',
            selectedPreset: null,
            onAmountChanged: (_) {},
            onToggleMode: () {},
            onPresetSelected: (_) {},
            onContinue: null,
          ),
        ),
      ),
    );

    expect(find.text('Support Vizor'), findsOneWidget);
    expect(find.text('0.02 ZEC'), findsOneWidget);
    expect(find.text('0.12 ZEC'), findsOneWidget);
    expect(find.text('Shielded balance'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('donation_amount_field')),
          )
          .autofocus,
      isTrue,
    );
    expect(
      tester
          .widget<GestureDetector>(
            find
                .ancestor(
                  of: find.text('Continue'),
                  matching: find.byType(GestureDetector),
                )
                .last,
          )
          .onTap,
      isNull,
    );
  });

  testWidgets('amount formatter preserves and remaps text selection', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    Future<TextInputFormatter> pumpFormatter(DonationAmountMode mode) async {
      await tester.pumpWidget(
        _host(
          SizedBox(
            height: 672,
            child: DonationComposeView(
              controller: controller,
              mode: mode,
              conversionText: r'$ 0',
              selectedPreset: null,
              onAmountChanged: (_) {},
              onToggleMode: () {},
              onPresetSelected: (_) {},
              onContinue: null,
            ),
          ),
        ),
      );
      return tester
          .widget<TextField>(
            find.byKey(const ValueKey('donation_amount_field')),
          )
          .inputFormatters!
          .single;
    }

    var formatter = await pumpFormatter(DonationAmountMode.zec);
    const validMiddleEdit = TextEditingValue(
      text: '1293.45',
      selection: TextSelection.collapsed(offset: 3),
    );
    expect(
      formatter.formatEditUpdate(
        const TextEditingValue(
          text: '123.45',
          selection: TextSelection.collapsed(offset: 2),
        ),
        validMiddleEdit,
      ),
      validMiddleEdit,
    );

    expect(
      formatter.formatEditUpdate(
        TextEditingValue.empty,
        const TextEditingValue(
          text: '12,3',
          selection: TextSelection.collapsed(offset: 4),
        ),
      ),
      const TextEditingValue(
        text: '12.3',
        selection: TextSelection.collapsed(offset: 4),
      ),
    );
    expect(
      formatter.formatEditUpdate(
        TextEditingValue.empty,
        const TextEditingValue(
          text: '1a23',
          selection: TextSelection(baseOffset: 1, extentOffset: 3),
        ),
      ),
      const TextEditingValue(
        text: '123',
        selection: TextSelection(baseOffset: 1, extentOffset: 2),
      ),
    );
    expect(
      formatter.formatEditUpdate(
        TextEditingValue.empty,
        const TextEditingValue(
          text: '.5',
          selection: TextSelection.collapsed(offset: 2),
        ),
      ),
      const TextEditingValue(
        text: '0.5',
        selection: TextSelection.collapsed(offset: 3),
      ),
    );
    expect(
      formatter.formatEditUpdate(
        TextEditingValue.empty,
        const TextEditingValue(
          text: '1.123456789',
          selection: TextSelection.collapsed(offset: 11),
        ),
      ),
      const TextEditingValue(
        text: '1.12345678',
        selection: TextSelection.collapsed(offset: 10),
      ),
    );
    expect(
      formatter.formatEditUpdate(
        TextEditingValue.empty,
        const TextEditingValue(
          text: '123456789012345678',
          selection: TextSelection.collapsed(offset: 18),
        ),
      ),
      const TextEditingValue(
        text: '12345678901234567',
        selection: TextSelection.collapsed(offset: 17),
      ),
    );
    expect(
      formatter.formatEditUpdate(
        const TextEditingValue(
          text: '1',
          selection: TextSelection.collapsed(offset: 1),
        ),
        TextEditingValue.empty,
      ),
      TextEditingValue.empty,
    );

    formatter = await pumpFormatter(DonationAmountMode.usd);
    expect(
      formatter.formatEditUpdate(
        TextEditingValue.empty,
        const TextEditingValue(
          text: '1.234',
          selection: TextSelection.collapsed(offset: 5),
        ),
      ),
      const TextEditingValue(
        text: '1.23',
        selection: TextSelection.collapsed(offset: 4),
      ),
    );
  });

  testWidgets('donation review uses dedicated recipient and CTA', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        DonationReviewContentView(
          amountText: '0.05 ZEC',
          fiatText: r'$2.50',
          feeText: '0.0001 ZEC',
          confirmLabel: 'Confirm donation',
          confirmIcon: 'donation',
          onConfirm: () {},
        ),
      ),
    );

    expect(find.text('Review Amount'), findsOneWidget);
    expect(find.text('Vizor Wallet'), findsOneWidget);
    expect(find.text('Confirm donation'), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
  });

  testWidgets('success view thanks the donor', (tester) async {
    await tester.pumpWidget(
      _host(SizedBox.expand(child: DonationSuccessView(onDone: () {}))),
    );
    expect(find.text('Thank you for supporting Vizor'), findsOneWidget);
    expect(find.text('Your support keeps Vizor going.'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
  });
}
