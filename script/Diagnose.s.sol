// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Script, console} from "forge-std/Script.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {Call} from "cow-shed/ICOWAuthHook.sol";
import {ShedBundle} from "../src/libraries/ShedBundle.sol";

/// @notice Recovers the signer of a signature against a list of candidate digests.
///
/// A signature that verifies against nothing we produce is the hardest kind to debug: it says the
/// wallet hashed something else, without saying what. This tries the plausible "something else"
/// candidates and prints which one the wallet actually signed.
///
/// In: `DIAG_OFFER` (an offer id under `out-json/link/`) and `DIAG_FILE` (JSON with the submitted
/// `signature`/`permitSignature`).
contract Diagnose is Script {
  bytes32 internal constant EIP712_DOMAIN_TYPE_HASH =
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
  bytes32 internal constant EIP2612_TYPEHASH =
    keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
  bytes32 internal constant DAI_TYPEHASH =
    keccak256("Permit(address holder,address spender,uint256 nonce,uint256 expiry,bool allowed)");
  bytes32 internal constant EXECUTE_HOOKS_TYPEHASH = keccak256(
    "ExecuteHooks(Call[] calls,bytes32 nonce,uint256 deadline)Call(address target,uint256 value,bytes callData,bool allowFailure,bool isDelegateCall)"
  );
  bytes32 internal constant CALL_TYPEHASH =
    keccak256("Call(address target,uint256 value,bytes callData,bool allowFailure,bool isDelegateCall)");

  /// @dev Chains a wallet could plausibly be on, for the case where the wallet rewrites `chainId`.
  uint256[15] internal chains =
    [uint256(1), 5, 10, 56, 100, 137, 324, 8453, 42161, 43114, 59144, 534352, 11155111, 17000, 31337];

  function run() external view {
    // Mode 2: recover the signer of a plain `personal_sign` message, which answers the one question
    // the typed-data candidates cannot: is the wallet signing with the key it claims?
    if (vm.envExists("DIAG_MESSAGE")) {
      string memory message = vm.envString("DIAG_MESSAGE");
      bytes memory sig = vm.parseJsonBytes(vm.readFile(vm.envString("DIAG_SIG_FILE")), ".signature");
      address claimed = vm.parseJsonAddress(vm.readFile(vm.envString("DIAG_SIG_FILE")), ".address");
      bytes32 digest = keccak256(
        abi.encodePacked("\x19Ethereum Signed Message:\n", Strings.toString(bytes(message).length), message)
      );
      console.log("claimed  ", claimed);
      console.log("recovered", _recover(digest, sig));
      return;
    }

    string memory offer = vm.readFile(string.concat("out-json/link/", vm.envString("DIAG_OFFER"), ".json"));
    string memory submitted = vm.readFile(vm.envString("DIAG_FILE"));

    address owner = vm.parseJsonAddress(offer, ".computed.takerBundle.owner");
    bytes memory bundleSig = vm.parseJsonBytes(submitted, ".signature");
    bytes memory permitSig = vm.parseJsonBytes(submitted, ".permitSignature");

    console.log("expected owner", owner);

    _permitCandidates(offer, owner, permitSig);
    _bundleCandidates(offer, owner, bundleSig);
  }

  function _permitCandidates(string memory offer, address owner, bytes memory sig) private view {
    address token = vm.parseJsonAddress(offer, ".computed.takerBundle.sellToken");
    address spender = vm.parseJsonAddress(offer, ".computed.takerBundle.shed");
    uint256 amount = vm.parseJsonUint(offer, ".computed.takerBundle.sellAmount");
    uint256 nonce = vm.parseJsonUint(offer, ".computed.takerBundle.permitNonce");
    uint256 deadline = vm.parseJsonUint(offer, ".computed.takerBundle.deadline");

    bytes32 structHash = keccak256(abi.encode(EIP2612_TYPEHASH, owner, spender, amount, nonce, deadline));
    bytes32 daiStructHash = keccak256(abi.encode(DAI_TYPEHASH, owner, spender, nonce, deadline, true));

    bytes memory otherSig = vm.parseJsonBytes(vm.readFile(vm.envString("DIAG_FILE")), ".signature");
    string memory permitJson = vm.parseJsonString(offer, ".computed.takerBundle.permitTypedDataJson");

    console.log("");
    console.log("== permit ==");
    console.log("-- if the two signatures recover to the same address, both prompts were the same message --");
    _try("eip2612, our domain", _wrap(_domain(token, "Dai Stablecoin", "1", block.chainid), structHash), sig, owner);
    _try("  the *bundle* signature under this", _wrap(_domain(token, "Dai Stablecoin", "1", block.chainid), structHash), otherSig, owner);
    _try("json string as a message", _eip191String(permitJson), sig, owner);
    _try("  the *bundle* signature under this", _eip191String(permitJson), otherSig, owner);
    _try("keccak of the json", keccak256(bytes(permitJson)), sig, owner);
    _try("dai-shaped struct", _wrap(_domain(token, "Dai Stablecoin", "1", block.chainid), daiStructHash), sig, owner);
    _try("eip191 over ours", _eip191(_wrap(_domain(token, "Dai Stablecoin", "1", block.chainid), structHash)), sig, owner);
    _try("struct hash alone", structHash, sig, owner);

    for (uint256 i = 0; i < chains.length; ++i) {
      _try(
        string.concat("domain chainId ", Strings.toString(chains[i])),
        _wrap(_domain(token, "Dai Stablecoin", "1", chains[i]), structHash),
        sig,
        owner
      );
    }
    _try("version ''", _wrap(_domain(token, "Dai Stablecoin", "", block.chainid), structHash), sig, owner);
    _try("version '2'", _wrap(_domain(token, "Dai Stablecoin", "2", block.chainid), structHash), sig, owner);
  }

  function _bundleCandidates(string memory offer, address owner, bytes memory sig) private view {
    Call[] memory calls = new Call[](3);
    calls[0] = Call({
      target: vm.parseJsonAddress(offer, ".computed.takerBundle.sellToken"),
      value: 0,
      callData: vm.parseJsonBytes(offer, ".computed.takerBundle.fundCall"),
      allowFailure: false,
      isDelegateCall: false
    });
    calls[1] = Call({
      target: vm.parseJsonAddress(offer, ".computed.takerBundle.sellToken"),
      value: 0,
      callData: vm.parseJsonBytes(offer, ".computed.takerBundle.approveCall"),
      allowFailure: false,
      isDelegateCall: false
    });
    calls[2] = Call({
      target: vm.envAddress("COMPOSABLE_COW_ADDRESS"),
      value: 0,
      callData: vm.parseJsonBytes(offer, ".computed.takerBundle.createCall"),
      allowFailure: false,
      isDelegateCall: false
    });

    bytes32 nonce = vm.parseJsonBytes32(offer, ".computed.takerBundle.nonce");
    uint256 deadline = vm.parseJsonUint(offer, ".computed.takerBundle.deadline");
    address shed = vm.parseJsonAddress(offer, ".computed.takerBundle.shed");

    bytes32 structHash = _executeHooksHash(calls, nonce, deadline);

    console.log("");
    console.log("== bundle ==");
    _try("cowshed domain, 2.0.0", _wrap(_domain(shed, "COWShed", "2.0.0", block.chainid), structHash), sig, owner);
    _try("eip191 over ours", _eip191(_wrap(_domain(shed, "COWShed", "2.0.0", block.chainid), structHash)), sig, owner);
    _try("struct hash alone", structHash, sig, owner);

    for (uint256 i = 0; i < chains.length; ++i) {
      _try(
        string.concat("domain chainId ", Strings.toString(chains[i])),
        _wrap(_domain(shed, "COWShed", "2.0.0", chains[i]), structHash),
        sig,
        owner
      );
    }
  }

  function _executeHooksHash(Call[] memory calls, bytes32 nonce, uint256 deadline)
    private
    pure
    returns (bytes32)
  {
    bytes32[] memory hashes = new bytes32[](calls.length);
    for (uint256 i = 0; i < calls.length; ++i) {
      hashes[i] = keccak256(
        abi.encode(CALL_TYPEHASH, calls[i].target, calls[i].value, keccak256(calls[i].callData), false, false)
      );
    }
    return keccak256(abi.encode(EXECUTE_HOOKS_TYPEHASH, keccak256(abi.encodePacked(hashes)), nonce, deadline));
  }

  function _domain(address verifying, string memory name, string memory version, uint256 chainId)
    private
    pure
    returns (bytes32)
  {
    return keccak256(
      abi.encode(EIP712_DOMAIN_TYPE_HASH, keccak256(bytes(name)), keccak256(bytes(version)), chainId, verifying)
    );
  }

  function _wrap(bytes32 separator, bytes32 structHash) private pure returns (bytes32) {
    return keccak256(abi.encodePacked(hex"1901", separator, structHash));
  }

  /// @dev `personal_sign` over a string payload.
  function _eip191String(string memory message) private pure returns (bytes32) {
    return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n", Strings.toString(bytes(message).length), message));
  }

  /// @dev What `personal_sign` produces for a 32-byte payload.
  function _eip191(bytes32 digest) private pure returns (bytes32) {
    return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
  }

  function _recover(bytes32 digest, bytes memory signature) private pure returns (address) {
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
    return ecrecover(digest, v, r, s);
  }

  function _try(string memory label, bytes32 digest, bytes memory signature, address expected) private pure {
    if (signature.length != 65) return;
    bytes32 r;
    bytes32 s;
    uint8 v;
    assembly {
      r := mload(add(signature, 0x20))
      s := mload(add(signature, 0x40))
      v := byte(0, mload(add(signature, 0x60)))
    }
    if (v < 27) v += 27;
    address got = ecrecover(digest, v, r, s);
    console.log(label, got, got == expected ? "<== MATCH" : "");
  }
}
