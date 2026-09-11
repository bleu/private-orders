// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {COWShedFactory} from "cow-shed/COWShedFactory.sol";

import {PrivateTradeE2EBase} from "../e2e/PrivateTradeE2EBase.sol";

interface IERC20Balance {
  function balanceOf(address who) external view returns (uint256);
}

/// @notice The private trade against a live mainnet fork: the real `GPv2Settlement`, the real
/// `COWShedFactoryForComposableCoW` and its `COWShedForComposableCoW` implementation, the real
/// `ComposableCoW`, and real USDC/DAI.
///
/// @dev Skipped unless `FORK_RPC` is set:
///
/// ```bash
/// FORK_RPC=https://ethereum-rpc.publicnode.com forge test --match-path 'test/fork/*' -vv
/// ```
contract PrivateTradeMainnetForkTest is PrivateTradeE2EBase {
  /// @dev Deployed on every chain, see `cowdao-grants/cow-shed` networks.json. Verified on
  /// mainnet: `implementation()` returns the ComposableCoW Shed, whose `composableCoW()` is
  /// ComposableCoW.
  address internal constant COWSHED_FACTORY_FOR_COMPOSABLE_COW = 0x5E284e80F3bd6A7D80A8500D9c49878028110848;

  function setUp() public {
    string memory rpc = vm.envOr("FORK_RPC", string(""));
    if (bytes(rpc).length == 0) {
      vm.skip(true);
      return;
    }
    vm.createSelectFork(rpc);
    _setUpProtocol();
  }

  function _setUpShedFactory() internal override {
    shedFactory = COWShedFactory(COWSHED_FACTORY_FOR_COMPOSABLE_COW);
  }

  /// @dev Real balances: `deal` writes the token's balance mapping on the fork.
  function _fundSheds() internal override {
    deal(USDC, aliceShed, USDC_AMOUNT);
    deal(DAI, bobShed, DAI_AMOUNT);
    assertEq(usdcBalance(aliceShed), USDC_AMOUNT, "seed USDC failed");
    assertEq(daiBalance(bobShed), DAI_AMOUNT, "seed DAI failed");
  }

  function test_privateTradeSettlesOnMainnetFork() public {
    if (!active) return;
    _runPrivateTrade();
  }

  /// @dev Both orders, no wrapper: the settlement itself must refuse them.
  function test_directSettlementIsRejectedOnMainnetFork() public {
    if (!active) return;
    _runDirectSettlementReverts();
  }

  function usdcBalance(address who) internal view returns (uint256) {
    return IERC20Balance(USDC).balanceOf(who);
  }

  function daiBalance(address who) internal view returns (uint256) {
    return IERC20Balance(DAI).balanceOf(who);
  }
}
