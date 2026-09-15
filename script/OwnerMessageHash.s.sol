// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Script, console} from "forge-std/Script.sol";

/// @dev The one thing read from the account: the separator it computes for itself.
interface IDomainSeparator {
  function domainSeparator() external view returns (bytes32);
}

/// @notice The hash a contract account must approve for a message, computed from the account's own
/// domain separator.
///
/// A client cannot construct the EIP-712 typed data itself. The domain depends on the account's
/// version — Safe 1.3 carries a name and a version in `EIP712Domain`, Safe 1.4 and later do not — so a
/// request built against one shape produces a signature the other refuses, and the refusal names a
/// signer rather than the message. Reading the separator the account computes for itself is
/// version-agnostic; EIP-712's framing is then a prefix and the `SafeMessage` struct hash.
///
/// ```
/// OWNER_MESSAGE_OWNER=0x… OWNER_MESSAGE_DIGEST=0x… \
///   forge script script/OwnerMessageHash.s.sol --rpc-url http://localhost:8545
/// ```
contract OwnerMessageHash is Script {
  /// @dev `keccak256("SafeMessage(bytes message)")` — the same in every Safe version.
  bytes32 internal constant SAFE_MESSAGE_TYPE_HASH = 0x60b3cbf8b4a223d68d641b3b6ddf9a298e7f33710cf3d3a9d1146b5a6150fbca;

  /// @dev EIP-712's `\x19\x01` prefix, which the account's own handler also writes.
  bytes2 internal constant EIP712_PREFIX = 0x1901;

  function run() external view {
    address owner = vm.envAddress("OWNER_MESSAGE_OWNER");
    bytes32 digest = vm.envBytes32("OWNER_MESSAGE_DIGEST");

    (bytes32 messageHash, bytes32 separator) = hashFor(owner, digest);
    console.log("messageHash", vm.toString(messageHash));
    console.log("separator", vm.toString(separator));
  }

  /// @dev `keccak256(0x1901 ‖ domainSeparator ‖ keccak256(typeHash ‖ keccak256(digest)))`.
  ///
  /// The inner `keccak256(digest)` is what both Safe handlers do with the message before framing it:
  /// `CompatibilityFallbackHandler` hashes the ABI encoding of the digest, and `SignatureVerifierMuxer`
  /// hashes it and then packs it. Both reach the same struct hash, and a test pins that.
  function hashFor(address owner, bytes32 digest) public view returns (bytes32 messageHash, bytes32 separator) {
    separator = IDomainSeparator(owner).domainSeparator();
    bytes32 structHash = keccak256(abi.encodePacked(SAFE_MESSAGE_TYPE_HASH, keccak256(abi.encodePacked(digest))));
    messageHash = keccak256(abi.encodePacked(EIP712_PREFIX, separator, structHash));
  }
}
