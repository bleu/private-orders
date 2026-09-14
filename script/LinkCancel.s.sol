// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Script, console} from "forge-std/Script.sol";
import {COWShedFactory} from "cow-shed/COWShedFactory.sol";
import {COWShed} from "cow-shed/COWShed.sol";
import {Call} from "cow-shed/ICOWAuthHook.sol";

import {ShedBundle} from "../src/libraries/ShedBundle.sol";

/// @notice Relays the exact maker cancellation bundle emitted by LinkCompute.
contract LinkCancel is Script {
  function run() external {
    uint256 relayerPrivateKey = vm.envUint("RELAYER_PRIVATE_KEY");
    address shedFactory = vm.envAddress("COWSHED_COMPOSABLE_COW_FACTORY_ADDRESS");
    string memory computed = vm.readFile(vm.envString("LINK_COMPUTED_FILE"));
    bytes memory signature = vm.parseJsonBytes(vm.readFile(vm.envString("LINK_SIGNATURE_FILE")), ".signature");
    ShedBundle.Bundle memory bundle_ = _bundle(computed);

    if (bundle_.shed.code.length > 0 && COWShed(payable(bundle_.shed)).nonces(bundle_.nonce)) {
      console.log("cancellation already relayed");
      return;
    }

    bytes32 declared = vm.parseJsonBytes32(computed, ".makerCancellation.digest");
    require(ShedBundle.digest(bundle_, shedFactory) == declared, "cancellation digest mismatch");
    require(ShedBundle.recover(bundle_, shedFactory, signature) == bundle_.owner, "cancellation signer mismatch");

    vm.startBroadcast(relayerPrivateKey);
    COWShedFactory(shedFactory).executeHooks(bundle_.calls, bundle_.nonce, bundle_.deadline, bundle_.owner, signature);
    vm.stopBroadcast();
    console.log("cancellation relayed");
  }

  function _bundle(string memory computed) private view returns (ShedBundle.Bundle memory) {
    string memory key = ".makerCancellation";
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
