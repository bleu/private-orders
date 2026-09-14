// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Script, console} from "forge-std/Script.sol";

import {COWShedFactory} from "cow-shed/COWShedFactory.sol";
import {COWShed} from "cow-shed/COWShed.sol";
import {Call} from "cow-shed/ICOWAuthHook.sol";

import {IERC20} from "cowprotocol/contracts/interfaces/IERC20.sol";

import {ShedBundle} from "../src/libraries/ShedBundle.sol";
import {TokenPermit} from "../src/libraries/TokenPermit.sol";

/// @notice Relays both parties' signed hook bundles for a computed private trade.
///
/// In: `out-json/link-computed.json` (from `LinkCompute`) and `out-json/link-signatures.json`
///     `{"maker":"0x…","taker":"0x…","makerPermit":"0x…","takerPermit":"0x…"}`, 65-byte
///     `r || s || v` signatures. The permit entries are the party's `permit` signatures, absent when
///     the token has no permit support.
///
/// Relaying is permissionless: a valid bundle is an owner signature, so the relayer is whoever pays
/// the gas. Two checks run first, because the Shed's own failure mode is a bare `InvalidSignature()`
/// that does not say whether the digest or the key was wrong: the relayed bundle must hash to the
/// digest the party signed, and that signature must recover to the Shed's owner.
///
/// Where the token supports `permit`, this is also where the party's allowance gets granted. The
/// permit signature is not a secret — it can only move the party's sell tokens into the party's own
/// Shed, for this amount — so the relayer submits it, and the party never needs a transaction.
contract LinkRelay is Script {
  function run() external {
    uint256 relayerPrivateKey = vm.envUint("RELAYER_PRIVATE_KEY");
    address shedFactory = vm.envAddress("COWSHED_COMPOSABLE_COW_FACTORY_ADDRESS");
    string memory computed = vm.readFile(vm.envOr("LINK_COMPUTED_FILE", string("out-json/link-computed.json")));
    string memory signatures = vm.readFile(vm.envOr("LINK_SIGNATURES_FILE", string("out-json/link-signatures.json")));

    vm.startBroadcast(relayerPrivateKey);
    _ensureSide(shedFactory, computed, signatures, ".makerBundle", ".maker", ".makerPermit");
    _ensureSide(shedFactory, computed, signatures, ".takerBundle", ".taker", ".takerPermit");
    vm.stopBroadcast();

    console.log("bundles relayed");
  }

  function _ensureSide(
    address shedFactory,
    string memory computed,
    string memory signatures,
    string memory bundleKey,
    string memory signatureKey,
    string memory permitSignatureKey
  ) private {
    ShedBundle.Bundle memory bundle_ = _bundle(computed, bundleKey);
    if (bundle_.shed.code.length > 0 && COWShed(payable(bundle_.shed)).nonces(bundle_.nonce)) return;
    _permit(computed, signatures, bundleKey, permitSignatureKey);
    _relay(shedFactory, computed, signatures, bundleKey, signatureKey);
  }

  /// @dev Grants the party's allowance to their own Shed, from the party's signature.
  ///
  /// A failure here is not fatal: a permit can be front-run, and the front-runner's submission grants
  /// exactly the same allowance. So the result is checked afterwards by reading the allowance, which
  /// is the fact that matters, and which produces an actionable error when it is missing.
  function _permit(
    string memory computed,
    string memory signatures,
    string memory bundleKey,
    string memory signatureKey
  ) private {
    string memory permitKind = vm.parseJsonString(computed, string.concat(bundleKey, ".permitKind"));
    if (keccak256(bytes(permitKind)) == keccak256("none")) return;

    TokenPermit.Permit memory permit = _permitFrom(computed, bundleKey);

    // Already granted by an earlier `approve`, or already submitted: nothing to do.
    if (IERC20(permit.token).allowance(permit.owner, permit.spender) >= permit.amount) return;

    bytes memory signature = vm.parseJsonBytes(signatures, signatureKey);
    require(
      signature.length == 65,
      string.concat(bundleKey, ": the token supports permit but no permit signature was supplied")
    );

    address signer = TokenPermit.recover(permit, signature);
    require(
      signer == permit.owner,
      string.concat(
        bundleKey,
        ": permit signature recovers to ",
        vm.toString(signer),
        ", not ",
        vm.toString(permit.owner),
        ". This usually means the wallet signed with a different account than the one the trade is with."
      )
    );

    (bool ok,) = permit.token.call(TokenPermit.callData(permit, signature));
    if (!ok) console.log(bundleKey, "permit call did not apply; the allowance check will decide");

    require(
      IERC20(permit.token).allowance(permit.owner, permit.spender) >= permit.amount,
      string.concat(
        bundleKey,
        ": no allowance for the Shed after the permit. The party can approve ",
        vm.toString(permit.token),
        " to ",
        vm.toString(permit.spender),
        " directly instead."
      )
    );
    console.log(bundleKey, "permit applied:", permitKind);
  }

  /// @dev The permit as the party signed it. The nonce comes from the file rather than the chain: it
  /// is what the signature commits to, and the two can differ if another permit landed in between.
  function _permitFrom(string memory computed, string memory key)
    private
    view
    returns (TokenPermit.Permit memory permit)
  {
    permit.token = vm.parseJsonAddress(computed, string.concat(key, ".sellToken"));
    permit.owner = vm.parseJsonAddress(computed, string.concat(key, ".owner"));
    permit.spender = vm.parseJsonAddress(computed, string.concat(key, ".shed"));
    permit.amount = vm.parseJsonUint(computed, string.concat(key, ".sellAmount"));
    permit.deadline = vm.parseJsonUint(computed, string.concat(key, ".deadline"));
    permit.nonce = vm.parseJsonUint(computed, string.concat(key, ".permitNonce"));
    permit.allowed = true;
    permit.kind = TokenPermit.kind(permit.token);
    permit.domainSeparator = TokenPermit.domainSeparator(permit.token);
  }

  function _relay(
    address shedFactory,
    string memory computed,
    string memory signatures,
    string memory bundleKey,
    string memory signatureKey
  ) private {
    ShedBundle.Bundle memory bundle_ = _bundle(computed, bundleKey);
    bytes memory signature = vm.parseJsonBytes(signatures, signatureKey);

    // Already executed: nothing to do, and re-relaying would revert `NonceAlreadyUsed`.
    if (bundle_.shed.code.length > 0 && COWShed(payable(bundle_.shed)).nonces(bundle_.nonce)) return;

    bytes32 declared = vm.parseJsonBytes32(computed, string.concat(bundleKey, ".digest"));
    bytes32 recomputed = ShedBundle.digest(bundle_, shedFactory);
    require(
      recomputed == declared,
      string.concat("bundle digest mismatch: relayed ", vm.toString(recomputed), " signed ", vm.toString(declared))
    );

    address signer = ShedBundle.recover(bundle_, shedFactory, signature);
    require(
      signer == bundle_.owner,
      string.concat("signature recovers to ", vm.toString(signer), ", not ", vm.toString(bundle_.owner))
    );

    console.log(bundleKey, "digest matches, signer", signer);
    COWShedFactory(shedFactory).executeHooks(bundle_.calls, bundle_.nonce, bundle_.deadline, bundle_.owner, signature);
  }

  /// @dev Built from the file, flags included. Nothing here decides what a call is: an assumption
  /// about `isDelegateCall` is enough to rebuild a different bundle than the party signed.
  function _bundle(string memory computed, string memory key) private view returns (ShedBundle.Bundle memory) {
    address[] memory targets = abi.decode(vm.parseJson(computed, string.concat(key, ".callTargets")), (address[]));
    bytes[] memory data = abi.decode(vm.parseJson(computed, string.concat(key, ".callDataHex")), (bytes[]));
    bool[] memory allowFailure = abi.decode(vm.parseJson(computed, string.concat(key, ".callAllowFailure")), (bool[]));
    bool[] memory delegateCall = abi.decode(vm.parseJson(computed, string.concat(key, ".callDelegateCall")), (bool[]));

    Call[] memory calls = new Call[](targets.length);
    for (uint256 i = 0; i < targets.length; ++i) {
      calls[i] = Call({
        target: targets[i], value: 0, callData: data[i], allowFailure: allowFailure[i], isDelegateCall: delegateCall[i]
      });
    }

    return ShedBundle.Bundle({
      owner: vm.parseJsonAddress(computed, string.concat(key, ".owner")),
      shed: vm.parseJsonAddress(computed, string.concat(key, ".shed")),
      calls: calls,
      nonce: vm.parseJsonBytes32(computed, string.concat(key, ".nonce")),
      deadline: vm.parseJsonUint(computed, string.concat(key, ".deadline"))
    });
  }
}
