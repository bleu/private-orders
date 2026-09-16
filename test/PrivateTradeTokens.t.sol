// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IERC20} from "cowprotocol/contracts/interfaces/IERC20.sol";
import {IConditionalOrder} from "composable-cow/interfaces/IConditionalOrder.sol";

import {PrivateTradeTerms, PrivateTradeRole} from "../src/interfaces/IPrivateTrade.sol";
import {PrivateTradeTestBase} from "./utils/PrivateTradeTestBase.sol";
import {TestERC20} from "./utils/TestERC20.sol";
import {FeeOnTransferToken, FalseReturnToken, NoReturnToken, ResetApprovalToken} from "./utils/BehaviourTokens.sol";

/// @notice What a pair does when the tokens are not well-behaved.
///
/// @dev Every claim here is about a token that behaves the way real ones do, so each fixture's
/// behaviour is asserted before anything is built on it. A fixture that quietly behaves like a normal
/// token would make every test below pass for the wrong reason.
contract PrivateTradeTokensTest is PrivateTradeTestBase {
  FeeOnTransferToken internal feeToken;
  FalseReturnToken internal falseToken;
  NoReturnToken internal noReturnToken;
  ResetApprovalToken internal resetToken;

  function setUp() public override {
    super.setUp();
    feeToken = new FeeOnTransferToken(makeAddr("fee-sink"));
    falseToken = new FalseReturnToken();
    noReturnToken = new NoReturnToken();
    resetToken = new ResetApprovalToken();
  }

  // --- the fixtures behave as claimed -------------------------------------------------------------

  function test_aFeeTokenKeepsACutOfEveryTransfer() public {
    address holder = makeAddr("fee-holder");
    address recipient = makeAddr("fee-recipient");
    feeToken.mint(holder, 1_000e18);

    vm.prank(holder);
    feeToken.transfer(recipient, 1_000e18);

    assertEq(feeToken.balanceOf(recipient), 950e18, "the recipient was not charged a fee");
    assertEq(feeToken.balanceOf(feeToken.sink()), 50e18, "the fee did not reach the sink");
    assertEq(feeToken.balanceOf(holder), 0, "the sender did not pay the full amount");
  }

  function test_aNoReturnTokenReturnsNothing() public {
    address holder = makeAddr("noret-holder");
    noReturnToken.mint(holder, 1_000e6);

    // The call succeeds and the return data is empty, which is what a caller reading a `bool` cannot
    // tell apart from a revert unless it checks. This is the shape `GPv2SafeERC20` accepts.
    vm.prank(holder);
    (bool ok, bytes memory data) =
      address(noReturnToken).call(abi.encodeWithSignature("transfer(address,uint256)", holder, 1e6));
    assertTrue(ok, "the transfer failed");
    assertEq(data.length, 0, "the token returned something after all");
  }

  function test_aFalseReturningTokenReportsFailureWithoutReverting() public {
    falseToken.mint(address(this), 1_000e18);
    falseToken.setRefuse(true);

    bool moved = falseToken.transfer(address(0xBEEF), 1e18);

    assertFalse(moved, "the token reported success");
    assertEq(falseToken.balanceOf(address(0xBEEF)), 0, "the token moved anyway");
  }

  function test_aResetApprovalTokenRefusesANonzeroToNonzeroApproval() public {
    resetToken.approve(address(0xBEEF), 10);

    vm.expectRevert(ResetApprovalToken.ResetApprovalToken_ResetRequired.selector);
    resetToken.approve(address(0xBEEF), 50);

    assertEq(resetToken.allowance(address(this), address(0xBEEF)), 10, "the refusal changed the allowance");
  }

  // --- what the pair does with them ---------------------------------------------------------------

  /// @dev The control. Without it, a failure below could be the fixture rather than the token.
  function test_aWellBehavedPairPaysBothSidesExactly() public {
    (
      PrivateTradeTerms memory terms,
      IConditionalOrder.ConditionalOrderParams memory makerParams,
      IConditionalOrder.ConditionalOrderParams memory takerParams
    ) = _readyTrade();

    _settle(terms, makerParams, takerParams);

    assertEq(wbtc.balanceOf(aliceOwner), terms.offer.buyAmount, "the maker was not paid exactly");
    assertEq(usdc.balanceOf(bobOwner), terms.offer.sellAmount, "the taker was not paid exactly");
    assertEq(usdc.balanceOf(address(alice)), 0, "the maker's wallet kept some");
    assertEq(wbtc.balanceOf(address(bob)), 0, "the taker's wallet kept some");
  }

  /// @notice A token that keeps a cut of every transfer does not produce a short payment; it makes the
  /// settlement revert and moves nothing.
  ///
  /// @dev The failure is the settlement's own arithmetic, and it is the reason the wrapper's post-check
  /// is not what protects delivery: `filledAmount` is written by `computeTradeExecutions` from the
  /// order's amounts and the clearing prices, before any transfer, and is never derived from a balance
  /// (`GPv2Settlement.settle` calls `computeTradeExecutions` and only then `transferFromAccounts`). What
  /// stops a short payment here is that the settlement cannot send out more of a token than it received.
  /// The wrapper's check catches the other failure — a settlement that returns without recording a fill
  /// at all — which is the one it was written for.
  function test_aFeeOnTransferTokenCannotProduceAShortPayment() public {
    // Control first, through the same plumbing: the identical pair with a well-behaved buy token
    // settles and pays exactly. Without this, a revert below could be the token list or the prices
    // rather than the fee.
    (
      PrivateTradeTerms memory controlTerms,
      IConditionalOrder.ConditionalOrderParams memory controlMaker,
      IConditionalOrder.ConditionalOrderParams memory controlTaker
    ) = _readyPairWithBuyToken(address(wbtc), WBTC_AMOUNT);
    _settlePair(controlTerms, controlMaker, controlTaker, address(usdc), address(wbtc));
    assertEq(wbtc.balanceOf(aliceOwner), WBTC_AMOUNT, "the control did not settle exactly");

    (
      PrivateTradeTerms memory terms,
      IConditionalOrder.ConditionalOrderParams memory makerParams,
      IConditionalOrder.ConditionalOrderParams memory takerParams
    ) = _readyPairWithBuyToken(address(feeToken), WBTC_AMOUNT);

    // Measured against the state the control left behind, not against zero: the control paid the taker
    // in USDC, and that payment is not what this test is about.
    uint256 makerBefore = feeToken.balanceOf(aliceOwner);
    uint256 takerBefore = usdc.balanceOf(bobOwner);

    vm.expectRevert();
    _settlePair(terms, makerParams, takerParams, address(usdc), address(feeToken));

    assertEq(
      feeToken.balanceOf(aliceOwner), makerBefore, "the maker was paid from a settlement that should not have completed"
    );
    assertEq(
      usdc.balanceOf(bobOwner), takerBefore, "the taker was paid from a settlement that should not have completed"
    );
    // Atomicity: the cut the token would have kept was rolled back with everything else.
    assertEq(feeToken.balanceOf(address(bob)), terms.offer.buyAmount, "the taker's wallet paid despite the revert");
    assertEq(feeToken.balanceOf(feeToken.sink()), 0, "a fee survived a reverted settlement");
  }

  /// @notice A token that refuses a non-zero to non-zero approval is safe here because the settlement
  /// consumes the allowance to zero — the invariant is load-bearing, so it is asserted rather than
  /// assumed.
  ///
  /// @dev The bundle approves the vault relayer for the sell amount, and a fill takes exactly that
  /// amount, so the next approval starts from zero. `feeAmount` is zero and the orders are fill-or-kill,
  /// which is what makes "exactly that amount" true; change either and this test should fail.
  function test_theSellSideAllowanceIsConsumedToZeroByASettlement() public {
    (
      PrivateTradeTerms memory terms,
      IConditionalOrder.ConditionalOrderParams memory makerParams,
      IConditionalOrder.ConditionalOrderParams memory takerParams
    ) = _readyPairWithSellToken(address(resetToken), USDC_AMOUNT);

    // The settlement's token list has to describe this pair, not the default one: the base's helpers
    // fix the list and the prices to usdc and wbtc.
    _settlePair(terms, makerParams, takerParams, address(resetToken), address(wbtc));

    assertEq(
      resetToken.allowance(address(alice), relayer),
      0,
      "the allowance was not consumed, so the next approve would revert"
    );

    // Which is the point: a second approval from zero is accepted by a token that refuses a reset.
    vm.prank(alice.OWNER());
    alice.approve(address(resetToken), relayer, terms.offer.sellAmount);
    assertEq(resetToken.allowance(address(alice), relayer), terms.offer.sellAmount, "the second approval was refused");
  }

  // --- fixtures

  /// @dev Settle a pair whose tokens the base's helpers do not know about. `_settleDataWith` is the
  /// seam for that: the token list and the clearing prices have to match the terms, and the base's own
  /// helpers fix both to usdc and wbtc.
  function _settlePair(
    PrivateTradeTerms memory terms,
    IConditionalOrder.ConditionalOrderParams memory makerParams,
    IConditionalOrder.ConditionalOrderParams memory takerParams,
    address sellToken,
    address buyToken
  ) internal returns (bytes4 magic) {
    IERC20[] memory tokens = new IERC20[](2);
    tokens[0] = IERC20(sellToken);
    tokens[1] = IERC20(buyToken);

    uint256[] memory prices = new uint256[](2);
    prices[0] = terms.offer.buyAmount;
    prices[1] = terms.offer.sellAmount;

    vm.prank(solver);
    magic = wrapper.wrappedSettle(
      _settleDataWith(tokens, prices, _trades(terms, makerParams, takerParams), _emptyInteractions()),
      _chainedWrapperData(terms)
    );
  }

  /// @dev A ready pair whose buy token is the given one: the taker sells it, the maker receives it.
  function _readyPairWithBuyToken(address buyToken, uint256 buyAmount)
    internal
    returns (
      PrivateTradeTerms memory terms,
      IConditionalOrder.ConditionalOrderParams memory makerParams,
      IConditionalOrder.ConditionalOrderParams memory takerParams
    )
  {
    terms = _terms(address(bob), address(bob));
    terms.offer.buyToken = buyToken;
    terms.offer.buyAmount = buyAmount;
    _fund(alice, usdc, terms.offer.sellAmount);
    _approveRelayer(alice, usdc, terms.offer.sellAmount);
    TestERC20(buyToken).mint(address(bob), buyAmount);
    _approveRelayer(bob, TestERC20(buyToken), buyAmount);
    makerParams = _authorize(alice, PrivateTradeRole.Maker, terms, "maker");
    takerParams = _authorize(bob, PrivateTradeRole.Taker, terms, "taker");
  }

  /// @dev A ready pair whose sell token is the given one: the maker sells it, the taker receives it.
  function _readyPairWithSellToken(address sellToken, uint256 sellAmount)
    internal
    returns (
      PrivateTradeTerms memory terms,
      IConditionalOrder.ConditionalOrderParams memory makerParams,
      IConditionalOrder.ConditionalOrderParams memory takerParams
    )
  {
    terms = _terms(address(bob), address(bob));
    terms.offer.sellToken = sellToken;
    terms.offer.sellAmount = sellAmount;
    TestERC20(sellToken).mint(address(alice), sellAmount);
    _approveRelayer(alice, TestERC20(sellToken), sellAmount);
    _fund(bob, wbtc, terms.offer.buyAmount);
    _approveRelayer(bob, wbtc, terms.offer.buyAmount);
    makerParams = _authorize(alice, PrivateTradeRole.Maker, terms, "maker");
    takerParams = _authorize(bob, PrivateTradeRole.Taker, terms, "taker");
  }
}
