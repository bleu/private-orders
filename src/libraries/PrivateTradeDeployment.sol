// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {PrivateTradeWrapper} from "../PrivateTradeWrapper.sol";
import {PrivateTradeOrder} from "../PrivateTradeOrder.sol";
import {PrivateTradeSubmitter} from "../PrivateTradeSubmitter.sol";
import {PrivateTradeAuthoriser} from "../PrivateTradeAuthoriser.sol";

/// @title PrivateTradeDeployment
/// @notice One definition of where the four contracts land, shared by the deploy script and the test
/// that freezes their addresses.
///
/// @dev An audit covers one bytecode at one address, and the allowlist holds one entry, so the
/// addresses cannot be allowed to depend on the chain, on a nonce, or on who deploys.
///
/// `forge script` does not create `new{salt}` with the broadcasting account. It calls the canonical
/// deterministic deployment proxy, so the `CREATE2` deployer is a fixed address that exists on every
/// chain, and the address is a function of `(proxy, salt, init code)` alone:
///
/// - the init code carries the constructor arguments, and the only variable one is `settlement`,
///   which CoW deploys at the same address on every chain it supports;
/// - the salt is fixed per release, so a second deployment on one chain is a deliberate new address.
///
/// Nothing here reads `block.chainid` or the sender, which is what makes a dry run print the address
/// a broadcast will produce. `test/PrivateTradeDeploy.t.sol` proves the derivation agrees with
/// `vm.computeCreate2Address`'s own default deployer, so it cannot drift from foundry's behaviour.
library PrivateTradeDeployment {
  /// @dev The canonical deterministic deployment proxy (Arachnid's), the same address on every chain
  /// foundry supports and the deployer foundry itself uses for `new{salt}` in a script.
  address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

  /// @dev Where the four addresses live. `handler` takes the wrapper, so the wrapper is derived
  /// first, exactly as the broadcast constructs it.
  struct Deployment {
    address wrapper;
    address handler;
    address submitter;
    address authoriser;
  }

  /// @dev Fixed per release. Changing it changes every address and needs a new allowlist entry.
  function defaultSalt() internal pure returns (bytes32) {
    return keccak256("private-trade.v1");
  }

  /// @notice The addresses a deployment will produce, without deploying anything.
  function predict(address settlement, bytes32 salt) internal pure returns (Deployment memory d) {
    d.wrapper =
      create2(salt, keccak256(abi.encodePacked(type(PrivateTradeWrapper).creationCode, abi.encode(settlement))));
    d.handler = create2(salt, keccak256(abi.encodePacked(type(PrivateTradeOrder).creationCode, abi.encode(d.wrapper))));
    d.submitter = create2(salt, keccak256(type(PrivateTradeSubmitter).creationCode));
    d.authoriser = create2(salt, keccak256(type(PrivateTradeAuthoriser).creationCode));
  }

  /// @dev The address `new Contract{salt: salt}(args)` produces inside a forge script.
  function create2(bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
    return create2(salt, initCodeHash, CREATE2_DEPLOYER);
  }

  function create2(bytes32 salt, bytes32 initCodeHash, address deployer) internal pure returns (address) {
    return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", deployer, salt, initCodeHash)))));
  }
}
