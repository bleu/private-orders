// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IERC20} from "cowprotocol/contracts/interfaces/IERC20.sol";
import {ComposableCoW} from "composable-cow/ComposableCoW.sol";
import {IConditionalOrder} from "composable-cow/interfaces/IConditionalOrder.sol";
import {Call} from "cow-shed/ICOWAuthHook.sol";
import {COWShedFactory} from "cow-shed/COWShedFactory.sol";

interface IShedVersion {
  function VERSION() external view returns (string memory);
}

/// @title ShedBundle
/// @notice The single definition of a CoW Shed hook bundle and the EIP-712 digest its owner signs.
///
/// @dev This construction appeared in three places (the offline preparation script, the link
/// service's compute step, and the test harness). Getting it subtly wrong produces a signature that
/// recovers to a different address, which the Shed reports only as `InvalidSignature()` — an
/// expensive thing to debug. One implementation, with a round-trip check, avoids that.
///
/// The domain version lives in the deployed Shed implementation and has changed between releases, so
/// it is read from the chain rather than hardcoded.
library ShedBundle {
  bytes32 internal constant EIP712_DOMAIN_TYPE_HASH =
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

  bytes32 internal constant EXECUTE_HOOKS_TYPE_HASH = keccak256(
    "ExecuteHooks(Call[] calls,bytes32 nonce,uint256 deadline)Call(address target,uint256 value,bytes callData,bool allowFailure,bool isDelegateCall)"
  );

  bytes32 internal constant CALL_TYPE_HASH =
    keccak256("Call(address target,uint256 value,bytes callData,bool allowFailure,bool isDelegateCall)");

  struct Bundle {
    address owner;
    address shed;
    Call[] calls;
    bytes32 nonce;
    uint256 deadline;
  }

  /// @notice The two calls a private trade party signs: approve the vault relayer, authorise the
  /// conditional order.
  function calls(
    address sellToken,
    uint256 sellAmount,
    address vaultRelayer,
    address composableCoW,
    IConditionalOrder.ConditionalOrderParams memory params
  ) internal pure returns (Call[] memory result) {
    result = new Call[](2);
    result[0] = Call({
      target: sellToken,
      value: 0,
      callData: abi.encodeCall(IERC20.approve, (vaultRelayer, sellAmount)),
      allowFailure: false,
      isDelegateCall: false
    });
    result[1] = Call({
      target: composableCoW,
      value: 0,
      callData: abi.encodeCall(ComposableCoW.create, (params, false)),
      allowFailure: false,
      isDelegateCall: false
    });
  }

  function domainSeparator(address shedFactory, address shed) internal view returns (bytes32) {
    bytes32 version = keccak256(bytes(IShedVersion(COWShedFactory(shedFactory).implementation()).VERSION()));
    return keccak256(abi.encode(EIP712_DOMAIN_TYPE_HASH, keccak256("COWShed"), version, block.chainid, shed));
  }

  function structHash(Call[] memory bundleCalls, bytes32 nonce, uint256 deadline) internal pure returns (bytes32) {
    bytes32[] memory hashes = new bytes32[](bundleCalls.length);
    for (uint256 i = 0; i < bundleCalls.length; ++i) {
      hashes[i] = keccak256(
        abi.encode(
          CALL_TYPE_HASH,
          bundleCalls[i].target,
          bundleCalls[i].value,
          keccak256(bundleCalls[i].callData),
          bundleCalls[i].allowFailure,
          bundleCalls[i].isDelegateCall
        )
      );
    }
    return keccak256(abi.encode(EXECUTE_HOOKS_TYPE_HASH, keccak256(abi.encodePacked(hashes)), nonce, deadline));
  }

  /// @notice The digest an owner signs.
  function digest(address shedFactory, address shed, Call[] memory bundleCalls, bytes32 nonce, uint256 deadline)
    internal
    view
    returns (bytes32)
  {
    return keccak256(
      abi.encodePacked(hex"1901", domainSeparator(shedFactory, shed), structHash(bundleCalls, nonce, deadline))
    );
  }

  function digest(Bundle memory bundle_, address shedFactory) internal view returns (bytes32) {
    return digest(shedFactory, bundle_.shed, bundle_.calls, bundle_.nonce, bundle_.deadline);
  }

  /// @notice Recover the signer of a 65-byte `r || s || v` signature over the bundle digest.
  /// @dev Returns `address(0)` for a malformed signature. Used to fail with a reason the caller can
  /// act on, instead of the Shed's opaque `InvalidSignature()`.
  function recover(Bundle memory bundle_, address shedFactory, bytes memory signature) internal view returns (address) {
    if (signature.length != 65) return address(0);
    bytes32 r;
    bytes32 s;
    uint8 v;
    assembly {
      r := mload(add(signature, 0x20))
      s := mload(add(signature, 0x40))
      v := byte(0, mload(add(signature, 0x60)))
    }
    if (v < 27) v += 27;
    return ecrecover(digest(bundle_, shedFactory), v, r, s);
  }
}
