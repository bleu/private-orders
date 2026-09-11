// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

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
  bytes4 internal constant NAME_SELECTOR = bytes4(keccak256("name()"));
  bytes4 internal constant VERSION_SELECTOR = bytes4(keccak256("version()"));

  bytes32 internal constant EIP712_DOMAIN_TYPE_HASH =
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

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
    /// @dev The domain fields, read from the token. Used to present the permit as typed data.
    string name;
    string version;
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
    permit.name = name(token);
    permit.version = _resolveVersion(token, permit.name, permit.domainSeparator, version(token));
  }

  /// @dev EIP-712 domains carry a version string, and many tokens do not expose it — the `version()`
  /// getter is a convention, not part of the standard, so a token built on OpenZeppelin's
  /// `ERC20Permit` has none. Rather than give up on typed data for those, candidate versions are
  /// tried against the token's own `DOMAIN_SEPARATOR()`. Only a version that actually reproduces it
  /// is used, so this is a lookup rather than a guess, and a token that matches none gets no typed
  /// data at all.
  function _resolveVersion(address token, string memory tokenName, bytes32 separator, string memory declared)
    private
    view
    returns (string memory)
  {
    if (bytes(declared).length > 0 && _separatorFor(token, tokenName, declared) == separator) return declared;

    string[5] memory candidates = ["1", "2", "3", "4", ""];
    for (uint256 i = 0; i < candidates.length; ++i) {
      if (_separatorFor(token, tokenName, candidates[i]) == separator) return candidates[i];
    }
    return "";
  }

  function _separatorFor(address token, string memory tokenName, string memory version_)
    private
    view
    returns (bytes32)
  {
    return keccak256(
      abi.encode(EIP712_DOMAIN_TYPE_HASH, keccak256(bytes(tokenName)), keccak256(bytes(version_)), block.chainid, token)
    );
  }

  /// @notice Whether this permit can be shown to a wallet as typed data.
  ///
  /// @dev Typed data is built from the domain fields, and the wallet hashes what it is shown. If
  /// those fields do not reproduce the token's own `DOMAIN_SEPARATOR()`, the signature would be over
  /// a different digest than the token checks, and the permit would simply fail. A token that hides
  /// its name or version, or computes its domain some other way, is therefore not offered typed data
  /// at all; the caller signs the raw digest instead.
  function typedDataAvailable(Permit memory permit) internal view returns (bool) {
    if (permit.kind == Kind.None) return false;
    if (bytes(permit.name).length == 0 || bytes(permit.version).length == 0) return false;
    return domainSeparatorFromFields(permit) == permit.domainSeparator;
  }

  /// @notice The permit as EIP-712 typed data, so a wallet displays the amount and spender instead
  /// of a bare digest. Only valid when `typedDataAvailable` holds.
  function typedData(Permit memory permit) internal view returns (string memory json) {
    json = string.concat(
      '{"primaryType":"Permit","domain":{"name":"',
      permit.name,
      '","version":"',
      permit.version,
      '","chainId":',
      Strings.toString(block.chainid),
      ',"verifyingContract":"',
      Strings.toHexString(permit.token),
      '"},"types":{"Permit":['
    );

    if (permit.kind == Kind.Eip2612) {
      json = string.concat(
        json,
        '{"name":"owner","type":"address"},{"name":"spender","type":"address"},',
        '{"name":"value","type":"uint256"},{"name":"nonce","type":"uint256"},',
        '{"name":"deadline","type":"uint256"}]},"message":{',
        '"owner":"',
        Strings.toHexString(permit.owner),
        '","spender":"',
        Strings.toHexString(permit.spender),
        '","value":"',
        Strings.toString(permit.amount),
        '","nonce":"',
        Strings.toString(permit.nonce),
        '","deadline":"',
        Strings.toString(permit.deadline),
        '"}}'
      );
      return json;
    }

    json = string.concat(
      json,
      '{"name":"holder","type":"address"},{"name":"spender","type":"address"},',
      '{"name":"nonce","type":"uint256"},{"name":"expiry","type":"uint256"},',
      '{"name":"allowed","type":"bool"}]},"message":{',
      '"holder":"',
      Strings.toHexString(permit.owner),
      '","spender":"',
      Strings.toHexString(permit.spender),
      '","nonce":"',
      Strings.toString(permit.nonce),
      '","expiry":"',
      Strings.toString(permit.deadline),
      '","allowed":',
      permit.allowed ? "true" : "false",
      "}}"
    );
  }

  /// @dev The domain separator the given fields imply. Compared against the token's own.
  function domainSeparatorFromFields(Permit memory permit) internal view returns (bytes32) {
    return keccak256(
      abi.encode(
        EIP712_DOMAIN_TYPE_HASH,
        keccak256(bytes(permit.name)),
        keccak256(bytes(permit.version)),
        block.chainid,
        permit.token
      )
    );
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

  /// @notice The token's `name()`, empty when it does not expose one as a string.
  function name(address token) internal view returns (string memory value) {
    value = _string(token, NAME_SELECTOR);
  }

  /// @notice The token's `version()`, the field EIP-712 domains use for the permit revision.
  function version(address token) internal view returns (string memory value) {
    value = _string(token, VERSION_SELECTOR);
  }

  function _string(address token, bytes4 selector) private view returns (string memory value) {
    (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSelector(selector));
    if (!ok || data.length < 64) return "";
    value = abi.decode(data, (string));
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
