import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/multichain/domain/multichain_chain.dart';

void main() {
  group('multichain registry', () {
    test('catalog names are unique (route + persistence namespace)', () {
      final names = MultichainChain.catalog.map((c) => c.name).toList();
      expect(names.toSet().length, names.length);
      expect(MultichainChain.catalog.length,
          greaterThan(MultichainChain.builtIns.length));
    });

    test('byName resolves every catalog chain and rejects unknowns', () {
      for (final chain in MultichainChain.catalog) {
        expect(MultichainChain.byName(chain.name), same(chain));
      }
      expect(MultichainChain.byName('no-such-chain'), isNull);
    });

    test('evm chains carry a unique EIP-155 chain id', () {
      final evmChains = MultichainChain.catalog
          .where((c) => c.family == MultichainFamily.evm)
          .toList();
      expect(evmChains, isNotEmpty);
      final ids = evmChains.map((c) => c.evmChainId).toList();
      expect(ids, everyElement(isNotNull));
      expect(ids.toSet().length, ids.length,
          reason: 'chain ids must be unique');
    });

    test('non-evm chains have no EIP-155 chain id', () {
      for (final chain in MultichainChain.catalog) {
        if (chain.family != MultichainFamily.evm) {
          expect(chain.evmChainId, isNull, reason: chain.name);
        }
      }
    });

    test('known mainnet chain ids', () {
      expect(MultichainChain.eth.evmChainId, 1);
      expect(MultichainChain.base.evmChainId, 8453);
      expect(MultichainChain.arbitrum.evmChainId, 42161);
      expect(MultichainChain.polygon.evmChainId, 137);
      expect(MultichainChain.bnb.evmChainId, 56);
      expect(MultichainChain.monad.evmChainId, 143);
    });

    test('every catalog chain has https-only keyless endpoints', () {
      for (final chain in MultichainChain.catalog) {
        expect(chain.endpoints, isNotEmpty, reason: chain.name);
        for (final endpoint in chain.endpoints) {
          expect(endpoint, startsWith('https://'), reason: chain.name);
          expect(endpoint, isNot(contains(r'${')), reason: chain.name);
        }
      }
    });

    test('cosmos chains carry full SDK parameters', () {
      for (final chain in MultichainChain.catalog) {
        final isCosmos = chain.family == MultichainFamily.cosmos;
        expect(chain.cosmosChainId != null, isCosmos, reason: chain.name);
        expect(chain.cosmosHrp != null, isCosmos, reason: chain.name);
        expect(chain.cosmosDenom != null, isCosmos, reason: chain.name);
        expect(chain.cosmosGasPrice != null, isCosmos, reason: chain.name);
        if (isCosmos) {
          expect(chain.cosmosGasPrice, greaterThan(0), reason: chain.name);
        }
      }
    });

    test('cosmos chain-id version parses like Keplr ChainIdHelper', () {
      expect(MultichainChain.cosmos.cosmosChainIdVersion, 4);
      expect(MultichainChain.osmosis.cosmosChainIdVersion, 1);
      expect(MultichainChain.noble.cosmosChainIdVersion, 1);
      // No `-N` suffix → revision number 0.
      expect(MultichainChain.celestia.cosmosChainIdVersion, 0);
    });

    test('ibc routes connect cosmos chains with unique source channels', () {
      expect(kIbcRoutes, isNotEmpty);
      final seen = <String>{};
      for (final route in kIbcRoutes) {
        expect(route.from.family, MultichainFamily.cosmos);
        expect(route.to.family, MultichainFamily.cosmos);
        expect(route.from, isNot(route.to));
        expect(route.channelId, startsWith('channel-'));
        expect(
          seen.add('${route.from.name}/${route.channelId}'),
          isTrue,
          reason: 'duplicate source channel ${route.channelId}',
        );
      }
    });

    test('ibc routes exist in both directions', () {
      for (final route in kIbcRoutes) {
        expect(
          kIbcRoutes.any((r) => r.from == route.to && r.to == route.from),
          isTrue,
          reason: 'missing reverse route for '
              '${route.from.name}→${route.to.name}',
        );
      }
    });

    test('built-in names stay stable for send deep links', () {
      expect(
        MultichainChain.builtIns.map((c) => c.name),
        containsAll([
          'btc',
          'doge',
          'eth',
          'base',
          'arbitrum',
          'polygon',
          'bnb',
          'monad',
          'cosmos',
          'osmosis',
          'celestia',
          'noble',
          'sol',
          'sui',
          'aptos',
        ]),
      );
    });

    test('every cosmos chain carries a slip44 coin type', () {
      final cosmosChains = MultichainChain.catalog
          .where((c) => c.family == MultichainFamily.cosmos)
          .toList();
      expect(cosmosChains.length, greaterThan(150));
      for (final chain in cosmosChains) {
        expect(chain.cosmosSlip44, isNotNull, reason: chain.name);
        expect(chain.cosmosHrp, isNotEmpty, reason: chain.name);
      }
    });

    test('eth-key chains resolve Keplr-compatible pubkey type urls', () {
      final injective = MultichainChain.byName('injective')!;
      expect(injective.cosmosSlip44, 60);
      expect(injective.cosmosUsesEthKey, isTrue);
      expect(
        injective.cosmosPubkeyTypeUrl,
        '/injective.crypto.v1beta1.ethsecp256k1.PubKey',
      );
      final dymension = MultichainChain.byName('dymension')!;
      expect(dymension.cosmosUsesEthKey, isTrue);
      expect(
        dymension.cosmosPubkeyTypeUrl,
        '/ethermint.crypto.v1.ethsecp256k1.PubKey',
      );
      expect(MultichainChain.cosmos.cosmosUsesEthKey, isFalse);
      expect(
        MultichainChain.cosmos.cosmosPubkeyTypeUrl,
        '/cosmos.crypto.secp256k1.PubKey',
      );
    });

    test('known custom coin types survive generation', () {
      expect(MultichainChain.byName('secretnetwork')!.cosmosSlip44, 529);
      expect(MultichainChain.byName('thorchain')!.cosmosSlip44, 931);
    });

    test('coin-type candidates put the registry default first', () {
      expect(MultichainChain.cosmos.cosmosCoinTypeCandidates, [118, 60]);
      expect(
        MultichainChain.byName('injective')!.cosmosCoinTypeCandidates,
        [60, 118],
      );
      expect(
        MultichainChain.byName('secretnetwork')!.cosmosCoinTypeCandidates,
        [529, 118, 60],
      );
    });

    test('account refs cover derivation variants', () {
      final btcDefault = multichainRefFor(MultichainChain.btc);
      expect(btcDefault.btcLegacy, isFalse);
      expect(multichainDerivationLabel(btcDefault), "m/84'/0'");
      final variants = multichainVariantRefs(btcDefault);
      expect(variants, hasLength(1));
      expect(variants.single.btcLegacy, isTrue);
      expect(multichainDerivationLabel(variants.single), "m/44'/0'");

      final hub = multichainRefFor(MultichainChain.cosmos);
      expect(hub.coinType, 118);
      final hubVariants = multichainVariantRefs(hub);
      expect(hubVariants.map((v) => v.coinType), [60]);
      expect(multichainDerivationLabel(hubVariants.single), "m/44'/60'");

      // Non-btc, non-cosmos chains have no variants to probe.
      expect(multichainVariantRefs(multichainRefFor(MultichainChain.sol)),
          isEmpty);
    });
  });
}
