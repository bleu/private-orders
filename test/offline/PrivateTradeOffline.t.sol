// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

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
  /// @dev The offline stack deploys its own Shed factory, at a deterministic address that is not
  /// the mainnet one.
  address internal constant COWSHED_FACTORY = 0xDb086A44b9db2650e9e3c1F21Fc7ba6B7d4B6681;

  function setUp() public {
    string memory rpc = vm.envOr("OFFLINE_RPC", string(""));
    if (bytes(rpc).length == 0) {
      vm.skip(true);
      return;
    }
    vm.createSelectFork(rpc);
    _setUpProtocol();
  }

  function _shedFactoryAddress() internal pure override returns (address) {
    return COWSHED_FACTORY;
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
