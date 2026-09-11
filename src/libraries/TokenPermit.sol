// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title TokenPermit
/// @notice `permit` support, so a party funds their Shed with a signature instead of a transaction.
///
/// @dev The funding bundle can only move a party's tokens with `transferFrom`, which needs an
/// allowance. Granting that allowance normally costs the party a transaction. Where the token
/// supports `permit`, the allowance can instead be granted by a signature that anyone may submit —
/// so the party pays nothing and signs no transaction, and the relay carries the permit call.
///
/// Two shapes exist in the wild and they are not interchangeable:
///
/// - **EIP-2612**: `permit(owner, spender, value, deadline, v, r, s)`
/// - **DAI-style**: `permit(holder, spender, nonce, expiry, allowed, v, r, s)` — an explicit nonce
///   instead of a value, a `bool` instead of an amount, and `expiry` where EIP-2612 has a `deadline`.
///
/// They have different selectors, so the shape is detected by probing rather than guessed from the
/// token's name. A token supporting neither is reported as `None` and the caller falls back to an
/// ordinary `approve` transaction.
///
/// @dev The digest is built from the token's own `DOMAIN_SEPARATOR()` rather than by re-deriving the
/// EIP-712 domain from name, version and chain id. That is one fewer thing to get wrong, and it
/// works for tokens whose domain fields do not follow the convention.
library TokenPermit {
  bytes4 internal constant EIP2612_PERMIT_SELECTOR =
    bytes4(keccak256("permit(address,address,uint256,uint256,uint8,bytes32,bytes32)"));
  bytes4 internal constant DAI_PERMIT_SELECTOR =
    bytes4(keccak256("permit(address,address,uint256,uint256,bool,uint8,bytes32,bytes32)"));
  bytes4 internal constant DOMAIN_SEPARATOR_SELECTOR = bytes4(keccak256("DOMAIN_SEPARATOR()"));
  bytes4 internal constant NONCES_SELECTOR = bytes4(keccak256("nonces(address)"));

  bytes32 internal constant EIP2612_TYPEHASH =
    keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
  bytes32 internal constant DAI_TYPEHASH =
    keccak256("Permit(address holder,address spender,uint256 nonce,uint256 expiry,bool allowed)");

  enum Kind {
    None,
    Eip2612,
    DaiLike
  }

  struct Permit {
    Kind kind;
    address token;
    address owner;
    address spender;
    uint256 amount;
    uint256 nonce;
    uint256 deadline;
    bool allowed;
    bytes32 domainSeparator;
  }

  /// @notice Which `permit` shape, if any, a token implements.
  /// @dev Probed by `staticcall` on the selector. A token without the function and without a
  /// fallback reverts with no data; one that has it reverts with a reason (an invalid signer, an
  /// expired deadline) or succeeds. Two shapes of false negative are accepted, because both degrade
  /// to the `approve` path: a token that writes storage before validating reverts with no data under
  /// a static call, and a token with a data-returning fallback can look like it has the function.
  /// In the second case the permit call does nothing and funding fails at `transferFrom`, which the
  /// relay reports with the token's own error.
  function kind(address token) internal view returns (Kind) {
    if (domainSeparator(token) == bytes32(0)) return Kind.None;
    if (_existsEip2612(token)) return Kind.Eip2612;
    if (_existsDaiLike(token)) return Kind.DaiLike;
    return Kind.None;
  }

  /// @notice Everything needed to sign and to submit a permit.
  /// @param deadline For EIP-2612 this is the signed `deadline`; for a DAI-style token it is `expiry`,
  /// and zero means no expiry.
  function build(address token, address owner, address spender, uint256 amount, uint256 deadline)
    internal
    view
    returns (Permit memory permit)
  {
    permit.kind = kind(token);
    permit.token = token;
    permit.owner = owner;
    permit.spender = spender;
    permit.amount = amount;
    permit.nonce = nonces(token, owner);
    permit.deadline = deadline;
    permit.allowed = true;
    permit.domainSeparator = domainSeparator(token);
  }

  /// @notice The digest a party signs. Zero if the token has no permit support.
  function digest(Permit memory permit) internal pure returns (bytes32) {
    if (permit.kind == Kind.None) return bytes32(0);

    bytes32 structHash = permit.kind == Kind.Eip2612
      ? keccak256(
        abi.encode(EIP2612_TYPEHASH, permit.owner, permit.spender, permit.amount, permit.nonce, permit.deadline)
      )
      : keccak256(abi.encode(DAI_TYPEHASH, permit.owner, permit.spender, permit.nonce, permit.deadline, permit.allowed));

    return keccak256(abi.encodePacked(hex"1901", permit.domainSeparator, structHash));
  }

  /// @notice The `permit` call the relay submits, carrying the party's signature.
  function callData(Permit memory permit, bytes memory signature) internal pure returns (bytes memory) {
    (uint8 v, bytes32 r, bytes32 s) = split(signature);
    if (permit.kind == Kind.Eip2612) {
      return abi.encodeWithSelector(
        EIP2612_PERMIT_SELECTOR, permit.owner, permit.spender, permit.amount, permit.deadline, v, r, s
      );
    }
    return abi.encodeWithSelector(
      DAI_PERMIT_SELECTOR, permit.owner, permit.spender, permit.nonce, permit.deadline, permit.allowed, v, r, s
    );
  }

  /// @notice Recover the signer of a 65-byte `r || s || v` signature over `digest`. `address(0)` for
  /// a malformed signature, so a caller can report which party's permit was wrong.
  function recover(Permit memory permit, bytes memory signature) internal pure returns (address) {
    if (signature.length != 65) return address(0);
    (uint8 v, bytes32 r, bytes32 s) = split(signature);
    if (v < 27) v += 27;
    return ecrecover(digest(permit), v, r, s);
  }

  function split(bytes memory signature) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
    assembly {
      r := mload(add(signature, 0x20))
      s := mload(add(signature, 0x40))
      v := byte(0, mload(add(signature, 0x60)))
    }
  }

  /// @notice The token's own EIP-712 domain separator, or zero if it does not expose one.
  /// @dev Required for a permit: without it the digest cannot be reconstructed correctly. A token
  /// that implements `permit` but hides its domain separator is treated as unsupported, which is the
  /// safe direction.
  function domainSeparator(address token) internal view returns (bytes32 separator) {
    (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSelector(DOMAIN_SEPARATOR_SELECTOR));
    if (!ok || data.length < 32) return bytes32(0);
    separator = abi.decode(data, (bytes32));
  }

  /// @notice The owner's current permit nonce, for a DAI-style token.
  function nonces(address token, address owner) internal view returns (uint256 nonce) {
    (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSelector(NONCES_SELECTOR, owner));
    if (!ok || data.length < 32) return 0;
    nonce = abi.decode(data, (uint256));
  }

  /// @dev The two shapes have different arities, and a probe must match the callee's exactly: too
  /// few arguments makes Solidity revert with no data while decoding, which is indistinguishable from
  /// the function not existing. Seven arguments here.
  function _existsEip2612(address token) private view returns (bool) {
    (bool ok, bytes memory data) = token.staticcall(
      abi.encodeWithSelector(
        EIP2612_PERMIT_SELECTOR, address(0), address(0), uint256(0), uint256(0), uint8(0), bytes32(0), bytes32(0)
      )
    );
    return ok || data.length > 0;
  }

  /// @dev Eight arguments here, with the `bool` and the `uint8` each occupying one word.
  function _existsDaiLike(address token) private view returns (bool) {
    (bool ok, bytes memory data) = token.staticcall(
      abi.encodeWithSelector(
        DAI_PERMIT_SELECTOR, address(0), address(0), uint256(0), uint256(0), true, uint8(0), bytes32(0), bytes32(0)
      )
    );
    return ok || data.length > 0;
  }
}
