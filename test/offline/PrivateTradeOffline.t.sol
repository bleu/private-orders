// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {COWShedFactory} from "cow-shed/COWShedFactory.sol";
import {COWShedForComposableCoW} from "cow-shed/COWShedForComposableCoW.sol";
import {IComposableCow} from "cow-shed/IComposableCow.sol";

import {PrivateTradeE2EBase} from "../e2e/PrivateTradeE2EBase.sol";

interface IMintableERC20 {
  function mint(address to, uint256 amount) external;
}

/// @notice The private trade against a live `bleu/cow-offline-mode` chain.
///
/// @dev Skipped unless `OFFLINE_RPC` is set; see docs/OFFLINE.md.
///
/// ```bash
/// OFFLINE_RPC=http://localhost:8545 forge test --match-path 'test/offline/*' -vv
/// ```
contract PrivateTradeOfflineTest is PrivateTradeE2EBase {
  function setUp() public {
    string memory rpc = vm.envOr("OFFLINE_RPC", string(""));
    if (bytes(rpc).length == 0) {
      vm.skip(true);
      return;
    }
    vm.createSelectFork(rpc);
    _setUpProtocol();
  }

  /// @dev The offline stack deploys the *plain* `COWShed`, whose implementation has no
  /// `isValidSignature`, so a Shed there cannot own a ComposableCoW order. Deploy the
  /// ComposableCoW variant ourselves; the factory is permissionless.
  function _setUpShedFactory() internal override {
    COWShedForComposableCoW impl = new COWShedForComposableCoW(IComposableCow(COMPOSABLE_COW));
    shedFactory = new COWShedFactory(address(impl));
  }

  /// @dev The offline stack serves mintable test tokens at the mainnet token addresses.
  function _fundSheds() internal override {
    IMintableERC20(USDC).mint(aliceShed, USDC_AMOUNT);
    IMintableERC20(DAI).mint(bobShed, DAI_AMOUNT);
  }

  function test_privateTradeSettlesOnOfflineChain() public {
    if (!active) return;
    _runPrivateTrade();
  }

  /// @dev Both orders, no wrapper: the settlement itself must refuse them.
  function test_directSettlementIsRejectedOnOfflineChain() public {
    if (!active) return;
    _runDirectSettlementReverts();
  }
}
