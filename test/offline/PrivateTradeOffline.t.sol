// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {COWShedFactory} from "cow-shed/COWShedFactory.sol";

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
  /// @dev Read from the offline repo's `.env` after the deploy. See docs/OFFLINE.md.
  address internal constant COWSHED_FACTORY_FOR_COMPOSABLE_COW = 0x3dbB9bb851a9cFB575D1D3691745F82A42c3A505;

  function setUp() public {
    string memory rpc = vm.envOr("OFFLINE_RPC", string(""));
    if (bytes(rpc).length == 0) {
      vm.skip(true);
      return;
    }
    vm.createSelectFork(rpc);
    _setUpProtocol();
  }

  /// @dev The stack's own Shed factory, whose implementation is `COWShedForComposableCoW`. The
  /// deploy script used to install the plain `COWShed`, which has no `isValidSignature` and cannot
  /// own a conditional order; `contracts/script/DeployCoWShed.s.sol` now deploys this variant.
  function _setUpShedFactory() internal override {
    shedFactory = COWShedFactory(COWSHED_FACTORY_FOR_COMPOSABLE_COW);
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

  /// @dev A submitter will be retried; relaying an executed bundle must not revert.
  function test_resubmittingOnOfflineChainIsSafe() public {
    if (!active) return;
    _runResubmitIsSafe();
  }

  /// @dev A BYOS sub-solver with no allowlist entry signs; the allowlisted submitter executes;
  /// the wrapper verifies the proposal on-chain.
  function test_byosProposalSubmissionOnOfflineChain() public {
    if (!active) return;
    _runByosProposal(false);
  }

  /// @dev A signature over a different pair must not execute this one.
  function test_byosProposalTamperingRejectedOnOfflineChain() public {
    if (!active) return;
    _runByosProposal(true);
  }
}
