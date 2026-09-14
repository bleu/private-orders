// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IERC20} from "cowprotocol/contracts/interfaces/IERC20.sol";
import {ComposableCoW} from "composable-cow/ComposableCoW.sol";
import {IConditionalOrder} from "composable-cow/interfaces/IConditionalOrder.sol";
import {Call} from "cow-shed/ICOWAuthHook.sol";
import {COWShedFactory} from "cow-shed/COWShedFactory.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {PrivateTradeAuthoriser} from "../PrivateTradeAuthoriser.sol";
import {IPrivateTradeWrapper, PrivateOffer} from "../interfaces/IPrivateTrade.sol";

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

  /// @notice The call that authorises an order, through the check that the terms pay this party.
  ///
  /// @dev A delegatecall, and it has to be: only inside a delegatecall can the Shed read its own
  /// admin, which is what the check compares the beneficiary against. One definition, because every
  /// bundle that authorises an order has to go through it — a bundle that called `ComposableCoW`
  /// directly would create an order that pays whoever composed the terms.
  function createCall(address authoriser, address composableCoW, IConditionalOrder.ConditionalOrderParams memory params)
    internal
    pure
    returns (Call memory)
  {
    return Call({
      target: authoriser,
      value: 0,
      callData: abi.encodeCall(PrivateTradeAuthoriser.createChecked, (ComposableCoW(composableCoW), params)),
      allowFailure: false,
      isDelegateCall: true
    });
  }

  /// @notice The two calls a private trade party signs: approve the vault relayer, authorise the
  /// conditional order.
  function calls(
    address sellToken,
    uint256 sellAmount,
    address vaultRelayer,
    address authoriser,
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
    result[1] = createCall(authoriser, composableCoW, params);
  }

  /// @notice Atomically revoke the maker order and mark its offer cancelled in the wrapper.
  /// @dev Both calls execute from the maker Shed. If either fails, neither state change persists.
  function cancellationCalls(
    address composableCoW,
    IConditionalOrder.ConditionalOrderParams memory makerParams,
    address wrapper,
    PrivateOffer memory offer
  ) internal pure returns (Call[] memory result) {
    result = new Call[](2);
    result[0] = Call({
      target: composableCoW,
      value: 0,
      callData: abi.encodeCall(ComposableCoW.remove, (ComposableCoW(composableCoW).hash(makerParams))),
      allowFailure: false,
      isDelegateCall: false
    });
    result[1] = Call({
      target: wrapper,
      value: 0,
      callData: abi.encodeCall(IPrivateTradeWrapper.cancelOffer, (offer)),
      allowFailure: false,
      isDelegateCall: false
    });
  }

  function domainSeparator(address shedFactory, address shed) internal view returns (bytes32) {
    bytes32 version = keccak256(bytes(IShedVersion(COWShedFactory(shedFactory).implementation()).VERSION()));
    return keccak256(abi.encode(EIP712_DOMAIN_TYPE_HASH, keccak256("COWShed"), version, block.chainid, shed));
  }

  /// @notice The domain fields as typed data would carry them, for a client that needs to display
  /// them. `shedVersion` is read from the deployed implementation, never hardcoded.
  function domain(address shedFactory, address shed)
    internal
    view
    returns (string memory name, string memory version, uint256 chainId, address verifyingContract)
  {
    name = "COWShed";
    version = IShedVersion(COWShedFactory(shedFactory).implementation()).VERSION();
    chainId = block.chainid;
    verifyingContract = shed;
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

  /// @notice The bundle as EIP-712 typed data, so a wallet shows what it is signing instead of
  /// asking its owner to blind-sign a 32-byte digest.
  ///
  /// @dev This is a presentation of the same message, not a second definition of it: every type
  /// string here is the one `structHash` hashes. `script/LinkServiceE2E`-style checks compare a
  /// signature over this JSON against a signature over `digest` and require them to be equal, which
  /// is what catches the two drifting apart.
  ///
  /// `EIP712Domain` is deliberately absent from `types`: the spec puts the domain in its own field,
  /// and wallets derive the domain type from it.
  function typedData(address shedFactory, address shed, Call[] memory bundleCalls, bytes32 nonce, uint256 deadline)
    internal
    view
    returns (string memory json)
  {
    json = string.concat(
      '{"primaryType":"ExecuteHooks","domain":{"name":"COWShed","version":"',
      IShedVersion(COWShedFactory(shedFactory).implementation()).VERSION()
    );
    json = string.concat(json, '","chainId":', Strings.toString(block.chainid));
    json = string.concat(json, ',"verifyingContract":"', Strings.toHexString(shed), '"}');
    json = string.concat(
      json,
      ',"types":{',
      '"ExecuteHooks":[{"name":"calls","type":"Call[]"},{"name":"nonce","type":"bytes32"},',
      '{"name":"deadline","type":"uint256"}],',
      '"Call":[{"name":"target","type":"address"},{"name":"value","type":"uint256"},',
      '{"name":"callData","type":"bytes"},{"name":"allowFailure","type":"bool"},',
      '{"name":"isDelegateCall","type":"bool"}]},',
      '"message":{"calls":['
    );

    for (uint256 i = 0; i < bundleCalls.length; ++i) {
      if (i > 0) json = string.concat(json, ",");
      json = string.concat(
        json,
        '{"target":"',
        Strings.toHexString(bundleCalls[i].target),
        '","value":"',
        Strings.toString(bundleCalls[i].value),
        '","callData":"',
        _hex(bundleCalls[i].callData),
        '","allowFailure":',
        bundleCalls[i].allowFailure ? "true" : "false",
        ',"isDelegateCall":',
        bundleCalls[i].isDelegateCall ? "true" : "false",
        "}"
      );
    }

    json = string.concat(
      json, '],"nonce":"', Strings.toHexString(uint256(nonce), 32), '","deadline":"', Strings.toString(deadline), '"}}'
    );
  }

  function digest(Bundle memory bundle_, address shedFactory) internal view returns (bytes32) {
    return digest(shedFactory, bundle_.shed, bundle_.calls, bundle_.nonce, bundle_.deadline);
  }

  /// @notice Recover the signer of a 65-byte `r || s || v` signature over the bundle digest.
  /// @dev Returns `address(0)` for a malformed signature. Used to fail with a reason the caller can
  /// act on, instead of the Shed's opaque `InvalidSignature()`.
  /// @dev `Strings` has no bytes overload in this vendored version, and calldata is what a wallet
  /// needs to display most of all.
  function _hex(bytes memory data) private pure returns (string memory) {
    bytes memory alphabet = "0123456789abcdef";
    bytes memory out = new bytes(2 + data.length * 2);
    out[0] = "0";
    out[1] = "x";
    for (uint256 i = 0; i < data.length; ++i) {
      out[2 + i * 2] = alphabet[uint8(data[i] >> 4)];
      out[3 + i * 2] = alphabet[uint8(data[i] & 0x0f)];
    }
    return string(out);
  }

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
