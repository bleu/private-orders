// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "cowprotocol/contracts/interfaces/IERC20.sol";
import {Call} from "cow-shed/ICOWAuthHook.sol";
import {COWShed} from "cow-shed/COWShed.sol";
import {COWShedFactory} from "cow-shed/COWShedFactory.sol";

import {ShedBundle} from "../src/libraries/ShedBundle.sol";

/// @notice Moves everything a party's Shed holds into the party's own wallet.
///
/// A settled trade pays the order owner, and the owner is the Shed — so the tokens arrive in a
/// contract that only its owner can move them out of. Without this, "settled" leaves the reader with
/// money in a place they have no way to reach.
///
/// Compute mode (no signature file): builds a bundle of `transfer(owner, balance)` calls for every
/// token with a balance, and writes the digest and typed data to sign.
/// Relay mode (signature file set): verifies the signature and executes the bundle. Permissionless —
/// the bundle is the owner's authorisation, so whoever pays the gas is irrelevant.
///
/// In:  `out-json/withdraw-request.json`  `{shedFactory, shed, owner, tokens[]}`
/// Out: `out-json/withdraw-computed.json`
contract Withdraw is Script {
  /// @dev Long enough that computing and signing are one step for the reader, short enough that a
  /// stale authorisation expires on its own.
  uint256 internal constant VALID_FOR = 30 minutes;

  function run() external {
    string memory request = vm.readFile(vm.envOr("WITHDRAW_REQUEST_FILE", string("out-json/withdraw-request.json")));

    // Relay mode replays the computed file and nothing else. Recomputing here would take a fresh
    // deadline from the relay's own clock, build a different message, and reject a signature that is
    // perfectly valid for what was actually signed.
    if (vm.envExists("WITHDRAW_SIGNATURE_FILE")) {
      _relay(vm.parseJsonAddress(request, ".shedFactory"));
      return;
    }

    address shedFactory = vm.parseJsonAddress(request, ".shedFactory");
    address shed = vm.parseJsonAddress(request, ".shed");
    address owner = vm.parseJsonAddress(request, ".owner");
    address[] memory tokens = abi.decode(vm.parseJson(request, ".tokens"), (address[]));

    address[] memory held = _held(shed, tokens);
    uint256[] memory amounts = _amounts(shed, held);
    if (held.length == 0) {
      console.log("nothing to withdraw");
      vm.writeFile(vm.envOr("WITHDRAW_COMPUTED_FILE", string("out-json/withdraw-computed.json")), '{"empty":true}');
      return;
    }

    // Unique per attempt: the Shed rejects a nonce it has already seen, and a withdrawal can
    // legitimately be attempted more than once.
    uint256 deadline = block.timestamp + VALID_FOR;
    bytes32 nonce = keccak256(abi.encode("withdraw", shed, deadline, held.length));
    Call[] memory calls = _calls(owner, held, amounts);

    _write(shedFactory, shed, owner, calls, amounts, nonce, deadline);
    console.log("computed: sign the digest, then relay");
  }

  /// @dev Everything the Shed holds, so the reader does not have to choose.
  function _held(address shed, address[] memory tokens) private view returns (address[] memory held) {
    held = new address[](tokens.length);
    uint256 count;
    for (uint256 i = 0; i < tokens.length; ++i) {
      if (IERC20(tokens[i]).balanceOf(shed) > 0) held[count++] = tokens[i];
    }
    assembly {
      mstore(held, count)
    }
  }

  function _amounts(address shed, address[] memory held) private view returns (uint256[] memory amounts) {
    amounts = new uint256[](held.length);
    for (uint256 i = 0; i < held.length; ++i) {
      amounts[i] = IERC20(held[i]).balanceOf(shed);
    }
  }

  function _calls(address owner, address[] memory held, uint256[] memory amounts)
    private
    pure
    returns (Call[] memory calls)
  {
    calls = new Call[](held.length);
    for (uint256 i = 0; i < held.length; ++i) {
      calls[i] = Call({
        target: held[i],
        value: 0,
        callData: abi.encodeCall(IERC20.transfer, (owner, amounts[i])),
        allowFailure: false,
        isDelegateCall: false
      });
    }
  }

  function _write(
    address shedFactory,
    address shed,
    address owner,
    Call[] memory calls,
    uint256[] memory amounts,
    bytes32 nonce,
    uint256 deadline
  ) private {
    string memory computed = string.concat(
      '{"shed":"',
      vm.toString(shed),
      '","owner":"',
      vm.toString(owner),
      '","nonce":"',
      vm.toString(nonce),
      '","deadline":',
      vm.toString(deadline),
      ',"digest":"',
      vm.toString(ShedBundle.digest(shedFactory, shed, calls, nonce, deadline)),
      '","typedData":',
      ShedBundle.typedData(shedFactory, shed, calls, nonce, deadline),
      ',"targets":',
      _jsonTargets(calls),
      ',"amounts":',
      _jsonAmounts(amounts),
      "}"
    );
    vm.writeFile(vm.envOr("WITHDRAW_COMPUTED_FILE", string("out-json/withdraw-computed.json")), computed);
  }

  /// @dev Relays exactly what was signed: the nonce, deadline and amounts all come from the computed
  /// file, not from this run's clock or balances.
  function _relay(address shedFactory) private {
    string memory computed = vm.readFile(vm.envOr("WITHDRAW_COMPUTED_FILE", string("out-json/withdraw-computed.json")));
    address shed = vm.parseJsonAddress(computed, ".shed");
    address owner = vm.parseJsonAddress(computed, ".owner");
    address[] memory targets = abi.decode(vm.parseJson(computed, ".targets"), (address[]));
    uint256[] memory amounts = abi.decode(vm.parseJson(computed, ".amounts"), (uint256[]));
    bytes32 nonce = vm.parseJsonBytes32(computed, ".nonce");
    uint256 deadline = vm.parseJsonUint(computed, ".deadline");

    Call[] memory calls = _calls(owner, targets, amounts);
    bytes memory signature = vm.parseJsonBytes(vm.readFile(vm.envString("WITHDRAW_SIGNATURE_FILE")), ".signature");
    ShedBundle.Bundle memory bundle_ =
      ShedBundle.Bundle({owner: owner, shed: shed, calls: calls, nonce: nonce, deadline: deadline});

    address signer = ShedBundle.recover(bundle_, shedFactory, signature);
    require(
      signer == owner,
      string.concat("withdraw signature recovers to ", vm.toString(signer), ", not ", vm.toString(owner))
    );

    if (shed.code.length > 0 && COWShed(payable(shed)).nonces(nonce)) {
      console.log("already withdrawn");
      return;
    }

    vm.startBroadcast(vm.envUint("RELAYER_PRIVATE_KEY"));
    COWShedFactory(shedFactory).executeHooks(calls, nonce, deadline, owner, signature);
    vm.stopBroadcast();
    console.log("withdrawn");
  }

  function _jsonTargets(Call[] memory calls) private pure returns (string memory json) {
    json = "[";
    for (uint256 i = 0; i < calls.length; ++i) {
      if (i > 0) json = string.concat(json, ",");
      json = string.concat(json, '"', _hex(abi.encodePacked(calls[i].target)), '"');
    }
    return string.concat(json, "]");
  }

  function _jsonAmounts(uint256[] memory amounts) private pure returns (string memory json) {
    json = "[";
    for (uint256 i = 0; i < amounts.length; ++i) {
      if (i > 0) json = string.concat(json, ",");
      json = string.concat(json, vm.toString(amounts[i]));
    }
    return string.concat(json, "]");
  }

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
}
