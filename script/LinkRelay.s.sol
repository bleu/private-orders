// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Script, console} from "forge-std/Script.sol";

import {COWShedFactory} from "cow-shed/COWShedFactory.sol";
import {COWShed} from "cow-shed/COWShed.sol";
import {Call} from "cow-shed/ICOWAuthHook.sol";

import {ShedBundle} from "../src/libraries/ShedBundle.sol";

/// @notice Relays both parties' signed hook bundles for a computed private trade.
///
/// In: `out-json/link-computed.json` (from `LinkCompute`) and `out-json/link-signatures.json`
///     `{"maker":"0x…","taker":"0x…"}`, 65-byte `r || s || v` signatures over each digest.
///
/// Relaying is permissionless: a valid bundle is an owner signature, so the relayer is whoever pays
/// the gas. Two checks run first, because the Shed's own failure mode is a bare `InvalidSignature()`
/// that does not say whether the digest or the key was wrong: the relayed bundle must hash to the
/// digest the party signed, and that signature must recover to the Shed's owner.
contract LinkRelay is Script {
  function run() external {
    uint256 relayerPrivateKey = vm.envUint("RELAYER_PRIVATE_KEY");
    address shedFactory = vm.envAddress("COWSHED_COMPOSABLE_COW_FACTORY_ADDRESS");
    string memory computed = vm.readFile("out-json/link-computed.json");
    string memory signatures = vm.readFile("out-json/link-signatures.json");

    vm.startBroadcast(relayerPrivateKey);
    _relay(shedFactory, computed, signatures, ".makerBundle", ".maker");
    _relay(shedFactory, computed, signatures, ".takerBundle", ".taker");
    vm.stopBroadcast();

    console.log("bundles relayed");
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

  function _bundle(string memory computed, string memory key) private view returns (ShedBundle.Bundle memory) {
    Call[] memory calls = new Call[](2);
    calls[0] = Call({
      target: vm.parseJsonAddress(computed, string.concat(key, ".sellToken")),
      value: 0,
      callData: vm.parseJsonBytes(computed, string.concat(key, ".approveCall")),
      allowFailure: false,
      isDelegateCall: false
    });
    calls[1] = Call({
      target: vm.envAddress("COMPOSABLE_COW_ADDRESS"),
      value: 0,
      callData: vm.parseJsonBytes(computed, string.concat(key, ".createCall")),
      allowFailure: false,
      isDelegateCall: false
    });

    return ShedBundle.Bundle({
      owner: vm.parseJsonAddress(computed, string.concat(key, ".owner")),
      shed: vm.parseJsonAddress(computed, string.concat(key, ".shed")),
      calls: calls,
      nonce: vm.parseJsonBytes32(computed, string.concat(key, ".nonce")),
      deadline: vm.parseJsonUint(computed, string.concat(key, ".deadline"))
    });
  }
}
