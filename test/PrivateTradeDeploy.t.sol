// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {PrivateTradeDeployment} from "../src/libraries/PrivateTradeDeployment.sol";
import {PrivateTradeWrapper} from "../src/PrivateTradeWrapper.sol";

/// @notice Freezes the deployment addresses, so a change to the contracts cannot silently move them.
///
/// @dev An audit covers one bytecode at one address and the allowlist holds one entry. `CREATE2`
/// makes an address a function of `(deployer, salt, init code)`, so this test recomputes the four
/// addresses and compares them with the values pinned here. Any change to a contract, to a
/// constructor argument, to the deployer or to the salt fails this test — which is the point: the
/// addresses in the audit report have to keep describing what is deployed.
///
/// Re-pin (`forge test --match-contract PrivateTradeDeployTest -vv` prints the current values) when a
/// change is intended, and treat that as the moment to re-read the audit scope.
contract PrivateTradeDeployTest is Test {
  /// @dev CoW deploys the settlement contract at the same address on every chain it supports.
  address internal constant SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;

  /// @dev Sepolia and mainnet, to make the cross-chain claim explicit rather than assumed.
  uint256 internal constant MAINNET = 1;
  uint256 internal constant SEPOLIA = 11155111;

  function test_addressesArePinned() public {
    PrivateTradeDeployment.Deployment memory d = PrivateTradeDeployment.predict(SETTLEMENT, salt());
    emit log_named_address("wrapper", d.wrapper);
    emit log_named_address("handler", d.handler);
    emit log_named_address("submitter", d.submitter);
    emit log_named_address("authoriser", d.authoriser);

    assertEq(d.wrapper, _pinnedWrapper(), "wrapper address moved: re-pin if that was intended");
    assertEq(d.handler, _pinnedHandler(), "handler address moved: re-pin if that was intended");
    assertEq(d.submitter, _pinnedSubmitter(), "submitter address moved: re-pin if that was intended");
    assertEq(d.authoriser, _pinnedAuthoriser(), "authoriser address moved: re-pin if that was intended");
  }

  /// @dev The same deployer, salt and settlement derive the same four addresses under a different chain
  /// id, because `CREATE2` hashes none of the chain. This is the property the Sepolia rehearsal relies
  /// on: one allowlist entry, one audit, one set of addresses to wire into the service.
  ///
  /// It compares the derivation, not two live deployments — the rehearsal is what proves deployment.
  /// Named for what it does rather than for the conclusion, because the difference matters when the
  /// rehearsal is what someone is relying on.
  function test_theDerivationDoesNotDependOnTheChain() public {
    vm.chainId(MAINNET);
    PrivateTradeDeployment.Deployment memory onMainnet = PrivateTradeDeployment.predict(SETTLEMENT, salt());

    vm.chainId(SEPOLIA);
    PrivateTradeDeployment.Deployment memory onSepolia = PrivateTradeDeployment.predict(SETTLEMENT, salt());

    assertEq(onMainnet.wrapper, onSepolia.wrapper, "wrapper differs by chain");
    assertEq(onMainnet.handler, onSepolia.handler, "handler differs by chain");
    assertEq(onMainnet.submitter, onSepolia.submitter, "submitter differs by chain");
    assertEq(onMainnet.authoriser, onSepolia.authoriser, "authoriser differs by chain");
  }

  /// @dev A different salt is a different deployment, which is how a second one is added to a chain
  /// that already has one. It costs a second allowlist entry, so it is never accidental.
  function test_aDifferentSaltMovesEveryAddress() public pure {
    PrivateTradeDeployment.Deployment memory current = PrivateTradeDeployment.predict(SETTLEMENT, salt());
    PrivateTradeDeployment.Deployment memory next =
      PrivateTradeDeployment.predict(SETTLEMENT, keccak256("private-trade.v2"));

    assertTrue(current.wrapper != next.wrapper, "salt did not move the wrapper");
    assertTrue(current.handler != next.handler, "salt did not move the handler");
    assertTrue(current.submitter != next.submitter, "salt did not move the submitter");
    assertTrue(current.authoriser != next.authoriser, "salt did not move the authoriser");
  }

  /// @dev The derivation must agree with foundry's own, or a dry run would print addresses a
  /// broadcast does not produce. `vm.computeCreate2Address(salt, initCodeHash)` uses foundry's
  /// default CREATE2 deployer, which is the proxy `new{salt}` goes through.
  function test_derivationMatchesFoundrysOwn() public pure {
    bytes32 initCodeHash = keccak256(type(PrivateTradeWrapper).creationCode);
    assertEq(
      PrivateTradeDeployment.create2(salt(), initCodeHash),
      vm.computeCreate2Address(salt(), initCodeHash),
      "our CREATE2 deployer is not foundry's"
    );
  }

  /// @dev The handler is constructed from the wrapper, so the wrapper's address is part of its init
  /// code. Pinned by the values above; asserted here so the dependency is documented.
  function test_handlerAddressFollowsTheWrapper() public {
    PrivateTradeDeployment.Deployment memory d = PrivateTradeDeployment.predict(SETTLEMENT, salt());
    PrivateTradeDeployment.Deployment memory shifted = PrivateTradeDeployment.predict(address(0xc0ffee), salt());

    assertTrue(d.handler != shifted.handler, "handler ignored the wrapper address");
  }

  // --- the pinned values

  function salt() internal pure returns (bytes32) {
    return PrivateTradeDeployment.defaultSalt();
  }

  function _pinnedWrapper() internal pure returns (address) {
    return 0x518ee95490fbd36D221BBaC8E3839AF3c1365B93;
  }

  function _pinnedHandler() internal pure returns (address) {
    return 0x6bE0461981Fa53828547cFD7A1ca998C24f3a8C9;
  }

  function _pinnedSubmitter() internal pure returns (address) {
    return 0x897bA1d0020517Cb7a08FFAE1504DA880828699C;
  }

  function _pinnedAuthoriser() internal pure returns (address) {
    return 0xd449F8F37802959d6369Fd701A9A88f5931588a5;
  }
}
