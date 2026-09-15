// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Safe} from "safe/Safe.sol";
import {ShedBundle} from "../src/libraries/ShedBundle.sol";
import {Call} from "cow-shed/ICOWAuthHook.sol";
import {OwnerMessageHash} from "../script/OwnerMessageHash.s.sol";
import {PrivateTradeOwnersTest} from "./PrivateTradeOwners.t.sol";

/// @notice The hash a client hands a contract account must be the hash that account approves.
///
/// This exists because a page once built the Safe's EIP-712 domain itself and got it wrong: the
/// vendored Safe's domain is `EIP712Domain(uint256 chainId,address verifyingContract)`, with no name
/// and no version, so the signature the page asked for was over a different digest than the one the
/// Safe checks. The failure names a signer, not the message, which is why it survived a review that
/// only inspected the request's shape.
contract PrivateTradeOwnerHashTest is PrivateTradeOwnersTest {
  /// @dev Constructed per test: the owner fixture's `setUp` is not virtual, so this cannot add one.
  function _hasher() internal returns (OwnerMessageHash) {
    return new OwnerMessageHash();
  }

  /// @dev The hash computed from the account's own separator is the one the Shed accepts.
  function test_hashFromTheAccountsOwnSeparatorIsAccepted() public {
    Party memory party = _safeParty("hash-subject");
    ShedBundle.Bundle memory bundle =
      ShedBundle.Bundle(party.owner, party.shed, new Call[](0), bytes32(uint256(1)), block.timestamp + 100);
    bytes32 digest = ShedBundle.digest(bundle, address(factory));

    (bytes32 messageHash,) = _hasher().hashFor(party.owner, digest);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(party.pk, messageHash);

    assertTrue(
      ShedBundle.validSignature(bundle, address(factory), abi.encodePacked(r, s, v)),
      "a signature over the hash the client hands out was refused by the Shed"
    );
  }

  /// @dev And the domain a client would build without asking is not it. This is the shape that broke.
  function test_domainBuiltFromNameAndVersionIsNotTheAccounts() public {
    Party memory party = _safeParty("hash-subject");
    ShedBundle.Bundle memory bundle =
      ShedBundle.Bundle(party.owner, party.shed, new Call[](0), bytes32(uint256(1)), block.timestamp + 100);
    bytes32 digest = ShedBundle.digest(bundle, address(factory));

    bytes32 invented = keccak256(
      abi.encode(
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
        keccak256("Safe"),
        keccak256(bytes(Safe(payable(party.owner)).VERSION())),
        block.chainid,
        party.owner
      )
    );
    assertNotEq(invented, Safe(payable(party.owner)).domainSeparator(), "the invented domain happened to match");

    bytes32 structHash = keccak256(abi.encodePacked(SAFE_MESSAGE_TYPE_HASH(), keccak256(abi.encodePacked(digest))));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(party.pk, keccak256(abi.encodePacked(hex"1901", invented, structHash)));

    assertFalse(
      ShedBundle.validSignature(bundle, address(factory), abi.encodePacked(r, s, v)),
      "a signature over a guessed domain was accepted, so this test proves nothing"
    );
  }

  /// @dev The struct hash this computes is the one both Safe handlers compute.
  function test_structHashMatchesTheHandlers() public pure {
    bytes32 digest = keccak256("a digest");
    bytes32 mine = keccak256(abi.encodePacked(SAFE_MESSAGE_TYPE_HASH(), keccak256(abi.encodePacked(digest))));
    // CompatibilityFallbackHandler: keccak256(abi.encode(typeHash, keccak256(abi.encode(digest))))
    bytes32 viaFallback = keccak256(abi.encode(SAFE_MESSAGE_TYPE_HASH(), keccak256(abi.encode(digest))));
    // SignatureVerifierMuxer: keccak256(abi.encodePacked(typeHash, abi.encode(keccak256(abi.encode(digest)))))
    bytes32 muxer = keccak256(abi.encodePacked(SAFE_MESSAGE_TYPE_HASH(), abi.encode(keccak256(abi.encode(digest)))));
    assertEq(mine, viaFallback, "the CompatibilityFallbackHandler struct hash differs");
    assertEq(mine, muxer, "the SignatureVerifierMuxer struct hash differs");
  }

  function SAFE_MESSAGE_TYPE_HASH() internal pure returns (bytes32) {
    return 0x60b3cbf8b4a223d68d641b3b6ddf9a298e7f33710cf3d3a9d1146b5a6150fbca;
  }
}
