// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;
import {PrivateTradeTestBase} from "./utils/PrivateTradeTestBase.sol";
import {PrivateTradeTerms} from "../src/interfaces/IPrivateTrade.sol";
import {IConditionalOrder} from "composable-cow/interfaces/IConditionalOrder.sol";
import {IERC20} from "cowprotocol/contracts/interfaces/IERC20.sol";
import {GPv2Trade} from "cowprotocol/contracts/libraries/GPv2Trade.sol";

contract ReviewCounterexamples is PrivateTradeTestBase {
  function test_sameAuthorizationSettlesAgainWithDifferentAppData() public {
    (
      PrivateTradeTerms memory terms,
      IConditionalOrder.ConditionalOrderParams memory maker,
      IConditionalOrder.ConditionalOrderParams memory taker
    ) = _readyTrade();
    _settle(terms, maker, taker);
    _fundAndApprove(terms);
    GPv2Trade.Data[] memory trades = _tradesWithAppData(terms, maker, taker, keccak256("different-document"));
    vm.prank(solver);
    wrapper.wrappedSettle(
      _settleDataWith(_tokens(), _clearingPrices(), trades, _emptyInteractions()), _chainedWrapperData(terms)
    );
    assertEq(usdc.balanceOf(bobOwner), 2 * USDC_AMOUNT);
    assertEq(wbtc.balanceOf(aliceOwner), 2 * WBTC_AMOUNT);
  }

  function test_takerIndependentPricesSpendSettlementBuffer() public {
    (
      PrivateTradeTerms memory terms,
      IConditionalOrder.ConditionalOrderParams memory maker,
      IConditionalOrder.ConditionalOrderParams memory taker
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
    GPv2Trade.Data[] memory trades = _trades(terms, maker, taker);
    trades[1].sellTokenIndex = 2;
    trades[1].buyTokenIndex = 3;
    usdc.mint(address(settlement), USDC_AMOUNT);
    vm.prank(solver);
    wrapper.wrappedSettle(_settleDataWith(tokens, prices, trades, _emptyInteractions()), _chainedWrapperData(terms));
    assertEq(usdc.balanceOf(bobOwner), 2 * USDC_AMOUNT);
    assertEq(usdc.balanceOf(address(settlement)), 0);
  }
}
