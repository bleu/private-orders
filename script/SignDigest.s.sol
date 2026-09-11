// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Script, console} from "forge-std/Script.sol";

/// @notice Signs a digest with raw ECDSA, as a wallet would, and writes the 65-byte
/// `r || s || v` signature to a file.
///
/// The link service never signs anything; this exists so the end-to-end script has a signer whose
/// semantics are unambiguous. `cast wallet sign` applies the EIP-191 personal-message prefix unless
/// `--no-hash` is passed, and getting that wrong produces a signature that recovers to a different
/// address — which the Shed reports only as `InvalidSignature()`.
///
/// ```bash
/// DIGEST=0x… SIGNER_PRIVATE_KEY=0x… SIGNATURE_OUT=out-json/sig.json \
///   forge script script/SignDigest.s.sol
/// ```
contract SignDigest is Script {
  function run() external {
    bytes32 digest = vm.envBytes32("DIGEST");
    uint256 privateKey = vm.envUint("SIGNER_PRIVATE_KEY");
    string memory out = vm.envOr("SIGNATURE_OUT", string("out-json/link-signature.json"));

    (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
    bytes memory signature = abi.encodePacked(r, s, v);

    vm.writeFile(out, string.concat('{"signature":"', vm.toString(signature), '","signer":"'));
    console.logBytes(signature);
    console.log(vm.addr(privateKey));
  }
}
