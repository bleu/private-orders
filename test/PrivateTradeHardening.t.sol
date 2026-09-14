// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IERC20} from "cowprotocol/contracts/interfaces/IERC20.sol";
import {IConditionalOrder} from "composable-cow/interfaces/IConditionalOrder.sol";
import {GPv2Interaction} from "cowprotocol/contracts/libraries/GPv2Interaction.sol";
import {GPv2Trade} from "cowprotocol/contracts/libraries/GPv2Trade.sol";

import {PrivateTradeTerms, PrivateTradeRole, PrivateTrade_Reentered} from "../src/interfaces/IPrivateTrade.sol";
import {PrivateTradeWrapper} from "../src/PrivateTradeWrapper.sol";
import {PrivateTradeTestBase} from "./utils/PrivateTradeTestBase.sol";
import {TestERC20} from "./utils/TestERC20.sol";

/// @notice A sell token that calls back into the wrapper while the settlement that is transferring it
/// is still running.
///
/// @dev This is the re-entrancy the wrapper's window has to survive. `wrappedSettle` is vendored from
/// upstream and gated only by `isSolver`, so the guard lives in `_wrap`, where the window that makes
/// the orders valid is set. The token is allowlisted as a solver first, because the upstream gate
/// would otherwise reject the callback before it reaches the guard — and the point of the test is to
/// exercise the guard, not the gate.
contract ReentrantSolverToken is TestERC20 {
  PrivateTradeWrapper internal target;
  bytes internal payload;
  bytes internal chained;
  bool internal armed;

  constructor() TestERC20("Reentrant", "REENT", 6) {}

  function arm(address wrapper_, bytes memory payload_, bytes memory chained_) external {
    target = PrivateTradeWrapper(payable(wrapper_));
    payload = payload_;
    chained = chained_;
    armed = true;
  }

  function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
    if (armed) {
      armed = false; // one shot: a successful callback must not loop
      target.wrappedSettle(payload, chained);
    }
    return super.transferFrom(from, to, amount);
  }
}

/// @notice What happens when a settlement that is already validating its pair is entered again.
contract PrivateTradeHardeningTest is PrivateTradeTestBase {
  ReentrantSolverToken internal hostile;

  function setUp() public override {
    super.setUp();
    hostile = new ReentrantSolverToken();
    // A solver can own or control a token, so the callback passes the wrapper's upstream gate.
    allowList.addSolver(address(hostile));
  }

  /// @dev Control: the same fixture settles when nothing calls back. Without this, a failure in the
  /// test below could be the fixture rather than the guard.
  function test_samePairSettlesWhenTheTokenDoesNotReenter() public {
    (PrivateTradeTerms memory terms,,) = _buildPair();

    assertEq(usdc.balanceOf(aliceOwner), terms.offer.buyAmount, "maker was not paid");
    assertEq(hostile.balanceOf(bobOwner), terms.offer.sellAmount, "taker was not paid");
  }

  /// @dev With the guard removed, this reverts with `PrivateTrade_OfferConsumed` instead: the
  /// re-entrant call re-validates the same pair and dies on the consumed flag, and only by accident
  /// on anything that protects the window. The selector is what makes the guard the reason.
  function test_reentrantTokenCannotOpenASecondWindow() public {
    (
      PrivateTradeTerms memory terms,
      IConditionalOrder.ConditionalOrderParams memory makerParams,
      IConditionalOrder.ConditionalOrderParams memory takerParams
    ) = _readyPair();

    bytes memory settleData = _pairSettleData(terms, makerParams, takerParams);
    bytes memory chained = _chainedWrapperData(terms);
    hostile.arm(address(wrapper), settleData, chained);

    vm.prank(solver);
    vm.expectRevert(PrivateTrade_Reentered.selector);
    wrapper.wrappedSettle(settleData, chained);
  }

  // --- fixtures

  function _buildPair()
    internal
    returns (
      PrivateTradeTerms memory terms,
      IConditionalOrder.ConditionalOrderParams memory makerParams,
      IConditionalOrder.ConditionalOrderParams memory takerParams
    )
  {
    (terms, makerParams, takerParams) = _readyPair();

    vm.prank(solver);
    wrapper.wrappedSettle(_pairSettleData(terms, makerParams, takerParams), _chainedWrapperData(terms));
  }

  /// @dev The pair, authorised and funded, but not yet settled. The maker sells the re-entrant token,
  /// so the callback fires from inside `transferFromAccounts`.
  function _readyPair()
    internal
    returns (
      PrivateTradeTerms memory terms,
      IConditionalOrder.ConditionalOrderParams memory makerParams,
      IConditionalOrder.ConditionalOrderParams memory takerParams
    )
  {
    terms = _termsFor(address(alice), address(bob), address(bob));
    terms.offer.sellToken = address(hostile);
    terms.offer.buyToken = address(usdc);
    terms.offer.sellAmount = USDC_AMOUNT;
    terms.offer.buyAmount = USDC_AMOUNT;

    makerParams = _authorize(alice, PrivateTradeRole.Maker, terms, "maker");
    takerParams = _authorize(bob, PrivateTradeRole.Taker, terms, "taker");

    _fund(alice, hostile, terms.offer.sellAmount);
    _approveRelayer(alice, hostile, terms.offer.sellAmount);
    _fund(bob, usdc, terms.offer.buyAmount);
    _approveRelayer(bob, usdc, terms.offer.buyAmount);
  }

  function _pairSettleData(
    PrivateTradeTerms memory terms,
    IConditionalOrder.ConditionalOrderParams memory makerParams,
    IConditionalOrder.ConditionalOrderParams memory takerParams
  ) internal view returns (bytes memory) {
    return _settleDataWith(
      _pairTokens(terms), _pairPrices(terms), _trades(terms, makerParams, takerParams), _emptyInteractions()
    );
  }

  function _pairTokens(PrivateTradeTerms memory terms) internal pure returns (IERC20[] memory tokens) {
    tokens = new IERC20[](2);
    tokens[0] = IERC20(terms.offer.sellToken);
    tokens[1] = IERC20(terms.offer.buyToken);
  }

  /// @dev Clearing prices that make the legs exact mirrors for this pair.
  function _pairPrices(PrivateTradeTerms memory terms) internal pure returns (uint256[] memory prices) {
    prices = new uint256[](2);
    prices[0] = terms.offer.buyAmount;
    prices[1] = terms.offer.sellAmount;
  }
}
