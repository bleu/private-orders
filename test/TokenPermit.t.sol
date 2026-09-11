// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {TokenPermit} from "../src/libraries/TokenPermit.sol";
import {TestERC20} from "./utils/TestERC20.sol";

/// @dev A real EIP-2612 implementation, not a stand-in of our own making.
contract Eip2612Token is ERC20Permit {
  constructor() ERC20("Eip2612", "E2612") ERC20Permit("Eip2612") {}

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }
}

/// @dev DAI's shape: an explicit nonce, `expiry`, and a `bool allowed`, with DAI's own typehash.
contract DaiLikeToken is ERC20 {
  bytes32 public constant PERMIT_TYPEHASH =
    keccak256("Permit(address holder,address spender,uint256 nonce,uint256 expiry,bool allowed)");

  bytes32 public immutable DOMAIN_SEPARATOR;
  mapping(address => uint256) public nonces;

  constructor() ERC20("Dai Stablecoin", "DAI") {
    DOMAIN_SEPARATOR = keccak256(
      abi.encode(
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
        keccak256("Dai Stablecoin"),
        keccak256("1"),
        block.chainid,
        address(this)
      )
    );
  }

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }

  function permit(
    address holder,
    address spender,
    uint256 nonce,
    uint256 expiry,
    bool allowed,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) external {
    bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, holder, spender, nonce, expiry, allowed));
    bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    // DAI's own ordering: validate before touching storage.
    require(holder != address(0), "Dai/invalid-holder");
    require(holder == ecrecover(digest, v, r, s), "Dai/invalid-permit");
    require(expiry == 0 || block.timestamp <= expiry, "Dai/permit-expired");
    require(nonce == nonces[holder]++, "Dai/invalid-nonce");
    _approve(holder, spender, allowed ? type(uint256).max : 0);
  }
}

/// @dev Writes storage before it validates, which real DAI and USDC do not. Under a `staticcall` the
/// write reverts with no data, indistinguishable from the function not existing.
contract EagerWriteToken is ERC20 {
  mapping(address => uint256) public nonces;

  constructor() ERC20("Eager", "EAGER") {}

  function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
    external
  {
    nonces[owner]++;
    require(deadline >= block.timestamp, "Eager/expired");
    _approve(owner, spender, value);
  }
}

/// @dev Implements EIP-2612, but computes its DOMAIN_SEPARATOR from a name it does not report.
contract LyingDomainToken is ERC20Permit {
  constructor() ERC20("Honest", "HON") ERC20Permit("Dishonest") {}
}

/// @notice `TokenPermit` is only useful if its encoding actually works against real tokens, so every
/// case here signs a permit with `TokenPermit` and then has a *third party* submit it, the way the
/// relay does. Nothing is asserted about our own digest in isolation.
contract TokenPermitTest is Test {
  uint256 internal constant AMOUNT = 1_000e18;
  uint256 internal constant DEADLINE = 2_000_000_000;
  address internal constant RELAYER = address(0x11e1a);

  uint256 internal ownerKey = 0xA11CE;
  address internal owner;
  address internal shed = address(0x5ED);

  Eip2612Token internal eip2612;
  DaiLikeToken internal daiLike;
  TestERC20 internal noPermit;

  function setUp() public {
    owner = vm.addr(ownerKey);
    eip2612 = new Eip2612Token();
    daiLike = new DaiLikeToken();
    noPermit = new TestERC20("Plain", "PLAIN", 18);
    vm.warp(1_700_000_000);
  }

  function test_detectsTheShapeEachTokenImplements() public view {
    assertEq(uint256(TokenPermit.kind(address(eip2612))), uint256(TokenPermit.Kind.Eip2612));
    assertEq(uint256(TokenPermit.kind(address(daiLike))), uint256(TokenPermit.Kind.DaiLike));
    assertEq(uint256(TokenPermit.kind(address(noPermit))), uint256(TokenPermit.Kind.None));
  }

  function test_eip2612PermitGrantsTheShedAnAllowanceSubmittedByTheRelay() public {
    TokenPermit.Permit memory permit = TokenPermit.build(address(eip2612), owner, shed, AMOUNT, DEADLINE);
    assertEq(uint256(permit.kind), uint256(TokenPermit.Kind.Eip2612));

    _submitAsRelayer(address(eip2612), permit);

    assertEq(eip2612.allowance(owner, shed), AMOUNT);
  }

  function test_daiStylePermitGrantsTheShedAnAllowanceSubmittedByTheRelay() public {
    TokenPermit.Permit memory permit = TokenPermit.build(address(daiLike), owner, shed, AMOUNT, DEADLINE);
    assertEq(uint256(permit.kind), uint256(TokenPermit.Kind.DaiLike));

    _submitAsRelayer(address(daiLike), permit);

    // DAI-style permits grant the maximum rather than the signed amount, which is the token's
    // choice, not ours.
    assertEq(daiLike.allowance(owner, shed), type(uint256).max);
  }

  function test_recoveryIdentifiesTheOwnerAndRejectsATamperedPermit() public {
    TokenPermit.Permit memory permit = TokenPermit.build(address(eip2612), owner, shed, AMOUNT, DEADLINE);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, TokenPermit.digest(permit));
    bytes memory signature = abi.encodePacked(r, s, v);

    assertEq(TokenPermit.recover(permit, signature), owner);

    // A permit for a different spender is a different digest, so the same signature no longer
    // authorises it. This is the check that stops a relay from redirecting an allowance.
    TokenPermit.Permit memory elsewhere = TokenPermit.build(address(eip2612), owner, address(0xBEEF), AMOUNT, DEADLINE);
    assertTrue(TokenPermit.recover(elsewhere, signature) != owner);

    vm.prank(RELAYER);
    (bool ok,) = address(eip2612).call(TokenPermit.callData(elsewhere, signature));
    assertFalse(ok, "a permit for another spender must not be submittable");
    assertEq(eip2612.allowance(owner, address(0xBEEF)), 0);
  }

  function test_expiredPermitDoesNotGrantAnAllowance() public {
    uint256 deadline = block.timestamp + 1 hours;
    TokenPermit.Permit memory permit = TokenPermit.build(address(eip2612), owner, shed, AMOUNT, deadline);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, TokenPermit.digest(permit));
    bytes memory signature = abi.encodePacked(r, s, v);

    vm.warp(deadline + 1);

    vm.prank(RELAYER);
    (bool ok,) = address(eip2612).call(TokenPermit.callData(permit, signature));
    assertFalse(ok, "an expired permit must not be submittable");
    assertEq(eip2612.allowance(owner, shed), 0);
  }

  /// @dev A token without permit is reported as such, so the caller can ask for an `approve`
  /// transaction instead of handing the party a digest that no contract will accept.
  function test_tokenWithoutPermitIsReportedUnsupported() public view {
    TokenPermit.Permit memory permit = TokenPermit.build(address(noPermit), owner, shed, AMOUNT, DEADLINE);
    assertEq(uint256(permit.kind), uint256(TokenPermit.Kind.None));
    assertEq(TokenPermit.digest(permit), bytes32(0));
  }

  /// @dev The detection heuristic is a `staticcall`, which cannot see past a storage write. A token
  /// shaped like `EagerWriteToken` is therefore reported as unsupported and the party falls back to
  /// an `approve` transaction. That is the safe direction: a needless transaction, never a broken
  /// flow. This test exists so the trade-off is visible rather than discovered in production.
  function test_tokenThatWritesBeforeValidatingFallsBackToApprove() public {
    EagerWriteToken eager = new EagerWriteToken();
    TokenPermit.Permit memory permit = TokenPermit.build(address(eager), owner, shed, AMOUNT, DEADLINE);
    assertEq(uint256(permit.kind), uint256(TokenPermit.Kind.None));
    assertEq(TokenPermit.digest(permit), bytes32(0));
  }

  /// @dev Typed data is a presentation of the message, so it has to describe the *same* message. The
  /// type strings a wallet reads are written out here and compared against the constants the digest
  /// hashes, which is what catches the two drifting apart.
  function test_typedDataTypeStringsAreTheOnesTheDigestHashes() public view {
    TokenPermit.Permit memory permit = TokenPermit.build(address(eip2612), owner, shed, AMOUNT, DEADLINE);
    assertTrue(TokenPermit.typedDataAvailable(permit), "the domain fields must reproduce the token's");

    string memory json = TokenPermit.typedData(permit);

    // The EIP-2612 struct, spelled exactly as the wallet will hash it.
    string memory permitType = "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)";
    assertEq(keccak256(bytes(permitType)), TokenPermit.EIP2612_TYPEHASH);
    assertTrue(_contains(json, "\"primaryType\":\"Permit\""));
    // The JSON-RPC form lists the fields; the type string is their concatenation, so checking the
    // ordered pairs is the same statement in the shape a wallet actually reads.
    assertTrue(
      _contains(
        json,
        '{"name":"owner","type":"address"},{"name":"spender","type":"address"},'
        '{"name":"value","type":"uint256"},{"name":"nonce","type":"uint256"},' '{"name":"deadline","type":"uint256"}'
      )
    );

    // The domain fields, and the values the wallet shows its owner.
    assertTrue(_contains(json, eip2612.name()));
    // OpenZeppelin's ERC20Permit exposes no `version()`, so this is the candidate that reproduces
    // its DOMAIN_SEPARATOR rather than a value read from the token.
    assertTrue(_contains(json, "\"version\":\"1\""));
    // Lowercase hex, as the JSON-RPC form uses and as the library emits.
    assertTrue(_contains(json, Strings.toHexString(address(eip2612))));
    assertTrue(_contains(json, Strings.toHexString(owner)));
    assertTrue(_contains(json, Strings.toHexString(shed)));
    assertTrue(_contains(json, Strings.toString(AMOUNT)));
    assertTrue(_contains(json, Strings.toString(DEADLINE)));
  }

  /// @dev DAI's struct has different field names, and a wallet shows them as written.
  function test_daiStyleTypedDataUsesDaisFieldNames() public view {
    TokenPermit.Permit memory permit = TokenPermit.build(address(daiLike), owner, shed, AMOUNT, DEADLINE);
    assertTrue(TokenPermit.typedDataAvailable(permit));
    assertEq(permit.version, "1", "DAI's own version string");

    string memory json = TokenPermit.typedData(permit);

    string memory permitType = "Permit(address holder,address spender,uint256 nonce,uint256 expiry,bool allowed)";
    assertEq(keccak256(bytes(permitType)), TokenPermit.DAI_TYPEHASH);
    assertTrue(
      _contains(
        json,
        '{"name":"holder","type":"address"},{"name":"spender","type":"address"},'
        '{"name":"nonce","type":"uint256"},{"name":"expiry","type":"uint256"},' '{"name":"allowed","type":"bool"}'
      )
    );
    assertTrue(_contains(json, "\"holder\""));
    assertTrue(_contains(json, "\"expiry\""));
    assertTrue(_contains(json, "\"allowed\":true"));
  }

  /// @dev A token whose domain fields do not reproduce its own DOMAIN_SEPARATOR cannot be offered
  /// typed data: the wallet would sign a digest the token never checks.
  function test_tokenWhoseDomainFieldsDontMatchIsNotOfferedTypedData() public {
    LyingDomainToken liar = new LyingDomainToken();
    TokenPermit.Permit memory permit = TokenPermit.build(address(liar), owner, shed, AMOUNT, DEADLINE);

    assertEq(uint256(permit.kind), uint256(TokenPermit.Kind.Eip2612), "it does implement permit");
    assertFalse(TokenPermit.typedDataAvailable(permit), "but its domain fields do not match");
  }

  function _contains(string memory haystack, string memory needle) private pure returns (bool) {
    bytes memory h = bytes(haystack);
    bytes memory n = bytes(needle);
    if (n.length > h.length) return false;
    for (uint256 i = 0; i <= h.length - n.length; ++i) {
      bool matched = true;
      for (uint256 j = 0; j < n.length; ++j) {
        if (h[i + j] != n[j]) {
          matched = false;
          break;
        }
      }
      if (matched) return true;
    }
    return false;
  }

  function _submitAsRelayer(address token, TokenPermit.Permit memory permit) private {
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, TokenPermit.digest(permit));
    bytes memory signature = abi.encodePacked(r, s, v);
    assertEq(TokenPermit.recover(permit, signature), owner);

    vm.prank(RELAYER);
    (bool ok,) = token.call(TokenPermit.callData(permit, signature));
    assertTrue(ok, "the relay must be able to submit a valid permit");
  }
}
