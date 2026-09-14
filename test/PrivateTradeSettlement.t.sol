// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IERC20} from "cowprotocol/contracts/interfaces/IERC20.sol";
import {GPv2Trade} from "cowprotocol/contracts/libraries/GPv2Trade.sol";
import {GPv2Order} from "cowprotocol/contracts/libraries/GPv2Order.sol";
import {GPv2Interaction} from "cowprotocol/contracts/libraries/GPv2Interaction.sol";
import {GPv2Signing} from "cowprotocol/contracts/mixins/GPv2Signing.sol";
import {IConditionalOrder} from "composable-cow/interfaces/IConditionalOrder.sol";

import {
  PrivateOffer,
  PrivateTradeTerms,
  PrivateTradeRole,
  PrivateTradeOfferState,
  PrivateTrade_NoActiveTrade,
  PrivateTrade_WrongActiveOffer,
  PrivateTrade_BadSettlementShape,
  PrivateTrade_InteractionsNotAllowed,
  PrivateTrade_OrderMismatch,
  PrivateTrade_NotReciprocal,
  PrivateTrade_TakerNotAllowed,
  PrivateTrade_NotSettlementCaller,
  PrivateTrade_NotLastWrapper,
  PrivateTrade_BadTaker,
  PrivateTrade_OfferIdMismatch,
  PrivateTrade_InvalidSettleData,
  PrivateTrade_OfferConsumed
} from "../src/interfaces/IPrivateTrade.sol";
import {PrivateTradeLib} from "../src/libraries/PrivateTradeLib.sol";
import {PrivateTradeBuilder} from "../src/libraries/PrivateTradeBuilder.sol";
import {CowWrapper, ICowWrapper} from "../src/vendor/CowWrapper.sol";
import {PrivateTradeTestBase} from "./utils/PrivateTradeTestBase.sol";

/// @notice End-to-end behaviour of a private trade, against a real `GPv2Settlement` and the real
/// Atomic Bundle entry point.
contract PrivateTradeSettlementTest is PrivateTradeTestBase {
  // --- happy path

  /// @dev Both legs settle, both balances move, and the settlement keeps nothing.
  function test_settlesExactPairAtomically() public {
    (
      PrivateTradeTerms memory terms,
      IConditionalOrder.ConditionalOrderParams memory makerParams,
      IConditionalOrder.ConditionalOrderParams memory takerParams
    ) = _readyTrade();

    assertEq(usdc.balanceOf(address(alice)), USDC_AMOUNT);
    assertEq(wbtc.balanceOf(address(alice)), 0);
    assertEq(wbtc.balanceOf(address(bob)), WBTC_AMOUNT);
    assertEq(usdc.balanceOf(address(bob)), 0);

    bytes4 magic = _settle(terms, makerParams, takerParams);
    assertEq(magic, ICowWrapper.wrappedSettle.selector, "wrapper did not return its selector");

    assertEq(usdc.balanceOf(address(alice)), 0, "alice still holds USDC");
    assertEq(wbtc.balanceOf(aliceOwner), WBTC_AMOUNT, "alice did not receive WBTC");
    assertEq(wbtc.balanceOf(address(bob)), 0, "bob still holds WBTC");
    assertEq(usdc.balanceOf(bobOwner), USDC_AMOUNT, "bob did not receive USDC");

    assertEq(usdc.balanceOf(address(settlement)), 0, "settlement kept USDC");
    assertEq(wbtc.balanceOf(address(settlement)), 0, "settlement kept WBTC");
    assertEq(wrapper.activeOfferId(), bytes32(0), "context not cleared");
    assertEq(wrapper.activeTaker(), address(0), "context not cleared");
  }

  /// @dev An offer with no counterparty restriction can be accepted by anyone holding the link.
  function test_openOfferIsAcceptedByAnyWallet() public {
    PrivateTradeTerms memory terms = _terms(address(carol));
    _fund(alice, usdc, USDC_AMOUNT);
    _approveRelayer(alice, usdc, USDC_AMOUNT);
    _fund(carol, wbtc, WBTC_AMOUNT);
    _approveRelayer(carol, wbtc, WBTC_AMOUNT);

    IConditionalOrder.ConditionalOrderParams memory makerParams =
      _authorize(alice, PrivateTradeRole.Maker, terms, "maker");
    IConditionalOrder.ConditionalOrderParams memory takerParams =
      _authorize(carol, PrivateTradeRole.Taker, terms, "taker");

    _settle(terms, makerParams, takerParams);

    assertEq(wbtc.balanceOf(aliceOwner), WBTC_AMOUNT);
    assertEq(usdc.balanceOf(address(carol)), USDC_AMOUNT);
  }

  // --- the core invariant: an order is worthless outside its pair

  /// @dev The maker order alone cannot be settled, even by an authorised solver.
  function test_directSettleMakerAloneReverts() public {
    (PrivateTradeTerms memory terms,,) = _readyTrade();
    GPv2Trade.Data[] memory all =
      _trades(terms, _params(PrivateTradeRole.Maker, terms, "maker"), _params(PrivateTradeRole.Taker, terms, "taker"));

    GPv2Trade.Data[] memory justMaker = new GPv2Trade.Data[](1);
    justMaker[0] = all[0];

    vm.prank(solver);
    vm.expectRevert(PrivateTrade_NoActiveTrade.selector);
    settlement.settle(_tokens(), _clearingPrices(), justMaker, _emptyInteractions());
  }

  /// @dev The taker order alone cannot be settled either.
  function test_directSettleTakerAloneReverts() public {
    (PrivateTradeTerms memory terms,,) = _readyTrade();
    GPv2Trade.Data[] memory all =
      _trades(terms, _params(PrivateTradeRole.Maker, terms, "maker"), _params(PrivateTradeRole.Taker, terms, "taker"));

    GPv2Trade.Data[] memory justTaker = new GPv2Trade.Data[](1);
    justTaker[0] = all[1];

    vm.prank(solver);
    vm.expectRevert(PrivateTrade_NoActiveTrade.selector);
    settlement.settle(_tokens(), _clearingPrices(), justTaker, _emptyInteractions());
  }

  /// @dev Even the complete pair is unusable when it reaches the settlement directly, without
  /// the wrapper publishing the terms.
  function test_directSettleCompletePairReverts() public {
    (
      PrivateTradeTerms memory terms,
      IConditionalOrder.ConditionalOrderParams memory makerParams,
      IConditionalOrder.ConditionalOrderParams memory takerParams
    ) = _readyTrade();

    vm.prank(solver);
    vm.expectRevert(PrivateTrade_NoActiveTrade.selector);
    settlement.settle(_tokens(), _clearingPrices(), _trades(terms, makerParams, takerParams), _emptyInteractions());
  }

  /// @dev A leaked maker order cannot be re-paired with a different counterparty: the offer id
  /// the maker actually authorised is not the one the attacker claims.
  function test_offerCommitmentBlocksRepairingWithAnotherCounterparty() public {
    // Alice authorises her order against an offer restricted to Bob.
    PrivateTradeTerms memory aliceTerms = _terms(address(bob), address(bob));
    _fund(alice, usdc, USDC_AMOUNT);
    _approveRelayer(alice, usdc, USDC_AMOUNT);
    _authorize(alice, PrivateTradeRole.Maker, aliceTerms, "maker");

    // Attacker rewrites the offer to "anyone" and pairs the leaked order with Carol.
    PrivateTradeTerms memory tampered = _terms(address(carol), address(0));
    _fund(carol, wbtc, WBTC_AMOUNT);
    _approveRelayer(carol, wbtc, WBTC_AMOUNT);
    IConditionalOrder.ConditionalOrderParams memory carolParams =
      _authorize(carol, PrivateTradeRole.Taker, tampered, "taker");

    IConditionalOrder.ConditionalOrderParams memory makerParams = _params(PrivateTradeRole.Maker, aliceTerms, "maker");

    vm.prank(solver);
    vm.expectRevert(
      abi.encodeWithSelector(
        PrivateTrade_WrongActiveOffer.selector,
        PrivateTradeLib.offerId(aliceTerms.offer),
        PrivateTradeLib.offerId(tampered.offer)
      )
    );
    wrapper.wrappedSettle(
      _settleDataWith(_tokens(), _clearingPrices(), _trades(tampered, makerParams, carolParams), _emptyInteractions()),
      _chainedWrapperData(tampered)
    );
  }

  /// @dev A restricted offer rejects a different taker even if that taker authorised an order.
  function test_restrictedOfferRejectsDifferentTaker() public {
    PrivateTradeTerms memory aliceTerms = _terms(address(bob), address(bob));
    _fund(alice, usdc, USDC_AMOUNT);
    _approveRelayer(alice, usdc, USDC_AMOUNT);
    _authorize(alice, PrivateTradeRole.Maker, aliceTerms, "maker");

    PrivateTradeTerms memory carolTerms = _terms(address(carol), address(bob));
    _fund(carol, wbtc, WBTC_AMOUNT);
    _approveRelayer(carol, wbtc, WBTC_AMOUNT);
    IConditionalOrder.ConditionalOrderParams memory carolParams =
      _authorize(carol, PrivateTradeRole.Taker, carolTerms, "taker");

    IConditionalOrder.ConditionalOrderParams memory makerParams = _params(PrivateTradeRole.Maker, aliceTerms, "maker");

    vm.prank(solver);
    vm.expectRevert(abi.encodeWithSelector(PrivateTrade_TakerNotAllowed.selector, address(bob), address(carol)));
    wrapper.wrappedSettle(
      _settleDataWith(
        _tokens(), _clearingPrices(), _trades(carolTerms, makerParams, carolParams), _emptyInteractions()
      ),
      _chainedWrapperData(carolTerms)
    );
  }

  /// @dev A settled pair cannot be replayed.
  function test_replayReverts() public {
    (
      PrivateTradeTerms memory terms,
      IConditionalOrder.ConditionalOrderParams memory makerParams,
      IConditionalOrder.ConditionalOrderParams memory takerParams
    ) = _readyTrade();

    _settle(terms, makerParams, takerParams);

    vm.prank(solver);
    vm.expectRevert(abi.encodeWithSelector(PrivateTrade_OfferConsumed.selector, PrivateTradeLib.offerId(terms.offer)));
    wrapper.wrappedSettle(_settleData(terms, makerParams, takerParams), _chainedWrapperData(terms));
  }

  /// @dev A conditional authorization represents one bilateral trade, even when a submitter changes
  /// appData so GPv2 derives a different order UID and both parties later replenish their funds.
  function test_sameOfferCannotSettleAgainWithDifferentAppData() public {
    (
      PrivateTradeTerms memory terms,
      IConditionalOrder.ConditionalOrderParams memory makerParams,
      IConditionalOrder.ConditionalOrderParams memory takerParams
    ) = _readyTrade();

    _settle(terms, makerParams, takerParams);
    _fundAndApprove(terms);

    bytes32 otherAppData = keccak256("different-private-trade-document");
    GPv2Trade.Data[] memory trades = _tradesWithAppData(terms, makerParams, takerParams, otherAppData);

    vm.prank(solver);
    vm.expectRevert(abi.encodeWithSelector(PrivateTrade_OfferConsumed.selector, PrivateTradeLib.offerId(terms.offer)));
    wrapper.wrappedSettle(
      _settleDataWith(_tokens(), _clearingPrices(), trades, _emptyInteractions()), _chainedWrapperData(terms)
    );
  }

  function test_failedSettlementDoesNotConsumeOffer() public {
    (
      PrivateTradeTerms memory terms,
      IConditionalOrder.ConditionalOrderParams memory makerParams,
      IConditionalOrder.ConditionalOrderParams memory takerParams
    ) = _readyTrade();
    bytes32 offerId = PrivateTradeLib.offerId(terms.offer);

    _approveRelayer(alice, usdc, 0);

    vm.prank(solver);
    vm.expectRevert();
    wrapper.wrappedSettle(_settleData(terms, makerParams, takerParams), _chainedWrapperData(terms));
    assertEq(uint256(wrapper.offerState(offerId)), uint256(PrivateTradeOfferState.Available));

    _approveRelayer(alice, usdc, USDC_AMOUNT);
    _settle(terms, makerParams, takerParams);
    assertEq(uint256(wrapper.offerState(offerId)), uint256(PrivateTradeOfferState.Consumed));
  }

  // --- bundle-specific rules

  /// @dev An intermediate bundle can rewrite `settleData` after validation, so this wrapper only
  /// runs as the last bundle in the chain.
  function test_rejectsBeingAnIntermediateBundle() public {
    (
      PrivateTradeTerms memory terms,
      IConditionalOrder.ConditionalOrderParams memory makerParams,
      IConditionalOrder.ConditionalOrderParams memory takerParams
    ) = _readyTrade();

    bytes memory data = _wrapperData(terms);
    bytes memory chained = abi.encodePacked(uint16(data.length), data, address(0xBEEF));

    vm.prank(solver);
    vm.expectRevert(PrivateTrade_NotLastWrapper.selector);
    wrapper.wrappedSettle(_settleData(terms, makerParams, takerParams), chained);
  }

  /// @dev `validateWrapperData` is the check `CowWrapperHelpers` performs before an order is
  /// placed; it must reject nonsense without touching state.
  function test_validateWrapperDataRejectsSelfTaker() public {
    PrivateTradeTerms memory terms = _terms(address(bob), address(bob));
    terms.taker = address(alice);

    vm.expectRevert(PrivateTrade_BadTaker.selector);
    wrapper.validateWrapperData(_wrapperData(terms));
  }

  function test_validateWrapperDataRejectsTamperedOfferId() public {
    PrivateTradeTerms memory terms = _terms(address(bob), address(bob));
    bytes memory data = abi.encode(keccak256("not-the-offer"), terms, PrivateTradeBuilder.unsignedProposal());

    vm.expectRevert(PrivateTrade_OfferIdMismatch.selector);
    wrapper.validateWrapperData(data);
  }

  function test_validateWrapperDataAcceptsValidTerms() public {
    PrivateTradeTerms memory terms = _terms(address(bob), address(bob));
    wrapper.validateWrapperData(_wrapperData(terms));
  }

  function test_rejectsNonSettleCalldata() public {
    (PrivateTradeTerms memory terms,,) = _readyTrade();

    vm.prank(solver);
    vm.expectRevert(PrivateTrade_InvalidSettleData.selector);
    wrapper.wrappedSettle(hex"deadbeef", _chainedWrapperData(terms));
  }

  // --- wrapper-side rejections

  function test_rejectsNonReciprocalClearingPrices() public {
    (
      PrivateTradeTerms memory terms,
      IConditionalOrder.ConditionalOrderParams memory makerParams,
      IConditionalOrder.ConditionalOrderParams memory takerParams
    ) = _readyTrade();

    uint256[] memory prices = _clearingPrices();
    prices[0] = prices[0] + 1; // maker would receive more than agreed

    vm.prank(solver);
    vm.expectRevert(PrivateTrade_NotReciprocal.selector);
    wrapper.wrappedSettle(
      _settleDataWith(_tokens(), prices, _trades(terms, makerParams, takerParams), _emptyInteractions()),
      _chainedWrapperData(terms)
    );
  }

  /// @dev The driver can repeat token addresses at different indices. Both trades must be checked
  /// through their own indices so neither can draw an improved output from a settlement buffer.
  function test_rejectsIndependentTakerPrices() public {
    (
      PrivateTradeTerms memory terms,
      IConditionalOrder.ConditionalOrderParams memory makerParams,
      IConditionalOrder.ConditionalOrderParams memory takerParams
    ) = _readyTrade();

    IERC20[] memory tokens = new IERC20[](4);
    tokens[0] = IERC20(address(usdc));
    tokens[1] = IERC20(address(wbtc));
    tokens[2] = IERC20(address(wbtc));
    tokens[3] = IERC20(address(usdc));

    uint256[] memory prices = new uint256[](4);
    prices[0] = WBTC_AMOUNT;
    prices[1] = USDC_AMOUNT;
    prices[2] = 2 * USDC_AMOUNT;
    prices[3] = WBTC_AMOUNT;

    GPv2Trade.Data[] memory trades = _trades(terms, makerParams, takerParams);
    trades[1].sellTokenIndex = 2;
    trades[1].buyTokenIndex = 3;
    usdc.mint(address(settlement), USDC_AMOUNT);

    vm.prank(solver);
    vm.expectRevert(PrivateTrade_NotReciprocal.selector);
    wrapper.wrappedSettle(_settleDataWith(tokens, prices, trades, _emptyInteractions()), _chainedWrapperData(terms));
  }

  function test_rejectsDuplicateMakerOrder() public {
    (
      PrivateTradeTerms memory terms,
      IConditionalOrder.ConditionalOrderParams memory makerParams,
      IConditionalOrder.ConditionalOrderParams memory takerParams
    ) = _readyTrade();

    GPv2Trade.Data[] memory trades = _trades(terms, makerParams, takerParams);
    trades[1] = trades[0];

    vm.prank(solver);
    vm.expectRevert(abi.encodeWithSelector(PrivateTrade_OrderMismatch.selector, 1));
    wrapper.wrappedSettle(
      _settleDataWith(_tokens(), _clearingPrices(), trades, _emptyInteractions()), _chainedWrapperData(terms)
    );
  }

  function test_rejectsSingleTrade() public {
    (
      PrivateTradeTerms memory terms,
      IConditionalOrder.ConditionalOrderParams memory makerParams,
      IConditionalOrder.ConditionalOrderParams memory takerParams
    ) = _readyTrade();

    GPv2Trade.Data[] memory all = _trades(terms, makerParams, takerParams);
    GPv2Trade.Data[] memory one = new GPv2Trade.Data[](1);
    one[0] = all[0];

    vm.prank(solver);
    vm.expectRevert(PrivateTrade_BadSettlementShape.selector);
    wrapper.wrappedSettle(
      _settleDataWith(_tokens(), _clearingPrices(), one, _emptyInteractions()), _chainedWrapperData(terms)
    );
  }

  function test_rejectsAnyInteraction() public {
    (
      PrivateTradeTerms memory terms,
      IConditionalOrder.ConditionalOrderParams memory makerParams,
      IConditionalOrder.ConditionalOrderParams memory takerParams
    ) = _readyTrade();

    GPv2Interaction.Data[][3] memory interactions = _emptyInteractions();
    interactions[2] = new GPv2Interaction.Data[](1);
    interactions[2][0] = GPv2Interaction.Data({target: address(usdc), value: 0, callData: hex"00"});

    vm.prank(solver);
    vm.expectRevert(PrivateTrade_InteractionsNotAllowed.selector);
    wrapper.wrappedSettle(
      _settleDataWith(_tokens(), _clearingPrices(), _trades(terms, makerParams, takerParams), interactions),
      _chainedWrapperData(terms)
    );
  }

  function test_rejectsNonSolverCaller() public {
    (
      PrivateTradeTerms memory terms,
      IConditionalOrder.ConditionalOrderParams memory makerParams,
      IConditionalOrder.ConditionalOrderParams memory takerParams
    ) = _readyTrade();

    vm.prank(makeAddr("random"));
    vm.expectRevert(abi.encodeWithSelector(CowWrapper.NotASolver.selector, makeAddr("random")));
    wrapper.wrappedSettle(_settleData(terms, makerParams, takerParams), _chainedWrapperData(terms));
  }

  /// @dev The handler refuses to validate anything unless the settlement is the caller.
  function test_verifyRejectsNonSettlementCaller() public {
    (PrivateTradeTerms memory terms, IConditionalOrder.ConditionalOrderParams memory makerParams,) = _readyTrade();

    vm.expectRevert(
      abi.encodeWithSelector(PrivateTrade_NotSettlementCaller.selector, address(settlement), address(this))
    );
    handler.verify(
      address(alice),
      address(this),
      bytes32(0),
      bytes32(0),
      bytes32(0),
      makerParams.staticInput,
      "",
      PrivateTradeLib.makerOrder(terms, APP_DATA)
    );
  }

  // --- helper assertions

  /// @dev Guards against the local flags encoder drifting from the settlement's decoder.
  function test_tradeFlagsDecodeAsExactSellOrder() public {
    (PrivateTradeTerms memory terms,,) = _readyTrade();
    GPv2Trade.Data memory trade = _trade(
      PrivateTradeLib.makerOrder(terms, APP_DATA), _params(PrivateTradeRole.Maker, terms, "maker"), address(alice), 0, 1
    );

    (
      bytes32 kind,
      bool partiallyFillable,
      bytes32 sellTokenBalance,
      bytes32 buyTokenBalance,
      GPv2Signing.Scheme signingScheme
    ) = GPv2Trade.extractFlags(trade.flags);

    assertEq(kind, GPv2Order.KIND_SELL);
    assertFalse(partiallyFillable);
    assertEq(sellTokenBalance, GPv2Order.BALANCE_ERC20);
    assertEq(buyTokenBalance, GPv2Order.BALANCE_ERC20);
    assertEq(uint256(signingScheme), uint256(GPv2Signing.Scheme.Eip1271));
  }

  function test_nameIsSet() public {
    assertEq(wrapper.name(), "PrivateTradeWrapper");
  }
}
