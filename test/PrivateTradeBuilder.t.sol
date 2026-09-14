// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IERC20} from "cowprotocol/contracts/interfaces/IERC20.sol";
import {GPv2Trade} from "cowprotocol/contracts/libraries/GPv2Trade.sol";
import {GPv2Order} from "cowprotocol/contracts/libraries/GPv2Order.sol";
import {IConditionalOrder} from "composable-cow/interfaces/IConditionalOrder.sol";

import {PrivateTradeTerms, PrivateTradeRole} from "../src/interfaces/IPrivateTrade.sol";
import {PrivateTradeBuilder} from "../src/libraries/PrivateTradeBuilder.sol";
import {PrivateTradeLib} from "../src/libraries/PrivateTradeLib.sol";
import {PrivateTradeAppData} from "../src/libraries/PrivateTradeAppData.sol";
import {PrivateTradeTestBase} from "./utils/PrivateTradeTestBase.sol";

/// @notice Cross-checks the production builder against this repository's own expected construction.
///
/// @dev The settlement suites build their payload from hand-written fixtures; the submitter builds
/// it with `PrivateTradeBuilder`. If the two ever disagree, the suites that run on real chains
/// would be proving something about the fixtures rather than about the submitter.
contract PrivateTradeBuilderTest is PrivateTradeTestBase {
  function test_tokensMatchReference() public view {
    PrivateTradeTerms memory terms = _terms(address(bob), address(bob));

    IERC20[] memory built = PrivateTradeBuilder.tokens(terms);
    IERC20[] memory expected = _tokens();

    assertEq(built.length, expected.length);
    assertEq(address(built[0]), address(expected[0]));
    assertEq(address(built[1]), address(expected[1]));
  }

  /// @dev The builder derives prices as `[buyAmount, sellAmount]`; the fixtures hardcode
  /// `[WBTC_AMOUNT, USDC_AMOUNT]`. Same numbers, different reasoning, so assert they agree.
  function test_clearingPricesMatchReference() public view {
    PrivateTradeTerms memory terms = _terms(address(bob), address(bob));

    uint256[] memory built = PrivateTradeBuilder.clearingPrices(terms);
    uint256[] memory expected = _clearingPrices();

    assertEq(built[0], expected[0]);
    assertEq(built[1], expected[1]);
    assertTrue(PrivateTradeLib.isReciprocal(terms, built[0], built[1]), "prices not reciprocal");
  }

  function test_ordersAndTradesMatchReference() public view {
    PrivateTradeTerms memory terms = _terms(address(bob), address(bob));
    bytes32 appData = keccak256("app-data");

    (
      IConditionalOrder.ConditionalOrderParams memory makerParams,
      IConditionalOrder.ConditionalOrderParams memory takerParams
    ) = PrivateTradeBuilder.conditionalOrderParams(address(handler), terms);

    assertEq(uint256(_roleOf(makerParams)), uint256(PrivateTradeRole.Maker));
    assertEq(uint256(_roleOf(takerParams)), uint256(PrivateTradeRole.Taker));

    GPv2Order.Data memory maker = PrivateTradeLib.makerOrder(terms, appData);
    GPv2Order.Data memory taker = PrivateTradeLib.takerOrder(terms, appData);

    assertEq(address(maker.sellToken), terms.offer.sellToken);
    assertEq(address(maker.buyToken), terms.offer.buyToken);
    assertEq(maker.sellAmount, terms.offer.sellAmount);
    assertEq(maker.buyAmount, terms.offer.buyAmount);
    assertEq(address(taker.sellToken), terms.offer.buyToken);
    assertEq(address(taker.buyToken), terms.offer.sellToken);
    assertEq(taker.sellAmount, terms.offer.buyAmount);
    assertEq(taker.buyAmount, terms.offer.sellAmount);

    // The builder's trades are `[maker, taker]`, with token indices in that order.
    GPv2Trade.Data[] memory trades = PrivateTradeBuilder.trades(terms, makerParams, takerParams, appData);
    assertEq(trades.length, 2);
    assertEq(trades[0].sellTokenIndex, 0);
    assertEq(trades[0].buyTokenIndex, 1);
    assertEq(trades[1].sellTokenIndex, 1);
    assertEq(trades[1].buyTokenIndex, 0);

    // Both orders must commit to the same appData document, which the wrapper enforces.
    assertEq(trades[0].appData, trades[1].appData);
  }

  /// @dev The appData hash is the hash of the document declaring the bundle, and the chain is
  /// `[uint16 len][data]` with nothing after it: the wrapper must be the last bundle.
  function test_appDataAndChainMatchReference() public view {
    PrivateTradeTerms memory terms = _terms(address(bob), address(bob));

    assertEq(
      PrivateTradeBuilder.appDataHash(terms, address(wrapper)),
      PrivateTradeAppData.documentHash(address(wrapper), _wrapperData(terms))
    );

    bytes memory chain = PrivateTradeBuilder.chainedWrapperData(terms, address(wrapper));
    assertEq(chain, _chainedWrapperData(terms));
    assertEq(chain.length, 2 + _wrapperData(terms).length);
  }

  /// @dev The salt a fresh offer carries has to be a fresh random value, and this is what it buys:
  /// two offers that differ only in the salt are two different offers, with two different order
  /// identities, conditional-order salts and hook nonces. ComposableCoW asks for a cryptographically
  /// secure salt exactly so this separation cannot be predicted by whoever is watching.
  function test_saltSeparatesTwoOtherwiseIdenticalOffers() public view {
    PrivateTradeTerms memory first = _terms(address(bob), address(bob));
    PrivateTradeTerms memory second = _terms(address(bob), address(bob));
    second.offer.salt = keccak256("a different random 32 bytes");

    assertTrue(first.offer.salt != second.offer.salt, "fixture salts must differ");
    assertTrue(
      PrivateTradeLib.offerId(first.offer) != PrivateTradeLib.offerId(second.offer), "offers share an identity"
    );

    (
      IConditionalOrder.ConditionalOrderParams memory firstMaker,
      IConditionalOrder.ConditionalOrderParams memory firstTaker
    ) = PrivateTradeBuilder.conditionalOrderParams(address(handler), first);
    (
      IConditionalOrder.ConditionalOrderParams memory secondMaker,
      IConditionalOrder.ConditionalOrderParams memory secondTaker
    ) = PrivateTradeBuilder.conditionalOrderParams(address(handler), second);

    assertTrue(firstMaker.salt != secondMaker.salt, "maker conditional orders share a salt");
    assertTrue(firstTaker.salt != secondTaker.salt, "taker conditional orders share a salt");
  }

  /// @dev Reusing a salt with the same terms reproduces the same offer exactly, which is the reason
  /// a repeated offer has to carry a new one: the second relay would collide on a consumed hook
  /// nonce rather than create a second offer.
  function test_reusingASaltReproducesTheSameOffer() public view {
    PrivateTradeTerms memory first = _terms(address(bob), address(bob));
    PrivateTradeTerms memory second = _terms(address(bob), address(bob));

    assertEq(PrivateTradeLib.offerId(first.offer), PrivateTradeLib.offerId(second.offer), "identity should match");
  }

  function _roleOf(IConditionalOrder.ConditionalOrderParams memory params)
    private
    pure
    returns (PrivateTradeRole role)
  {
    (role,) = abi.decode(params.staticInput, (PrivateTradeRole, PrivateTradeTerms));
  }
}
