// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Script, console, VmSafe} from "forge-std/Script.sol";

import {PrivateTradeWrapper} from "../src/PrivateTradeWrapper.sol";
import {PrivateTradeOrder} from "../src/PrivateTradeOrder.sol";
import {PrivateTradeSubmitter} from "../src/PrivateTradeSubmitter.sol";
import {PrivateTradeAuthoriser} from "../src/PrivateTradeAuthoriser.sol";
import {ICowSettlement} from "../src/vendor/CowWrapper.sol";
import {PrivateTradeDeployment} from "../src/libraries/PrivateTradeDeployment.sol";

/// @notice Deploys the four contracts a private trade needs at addresses that do not depend on the
/// chain or on the deployer's nonce.
///
/// @dev Every contract is deployed with `CREATE2` under one salt, so the addresses a dry run prints
/// are the addresses a broadcast produces, and the same four addresses appear on every chain the
/// same deployer deploys to. That is what lets one audited artefact and one allowlist entry cover
/// both a Sepolia rehearsal and mainnet. Three facts make it hold:
///
/// 1. `CREATE2` hashes `(deployer, salt, initCode)`, and the init code carries the constructor
///    arguments. The only constructor argument that varies is `settlement`, which CoW deploys at the
///    same address on every chain it supports (`0x9008…ab41`).
/// 2. The salt is fixed per release. A second deployment on a chain that already has one needs a new
///    `DEPLOY_SALT`, which is a new address, which is a new allowlist entry — deliberate.
///
/// The deployer key is therefore *not* an input to the addresses (`DEPLOYER_ADDRESS` is checked only
/// to catch the wrong key being loaded), which is why a dry run on one chain prints the addresses a
/// broadcast on another chain will produce.
///
/// ```bash
/// # Dry run: prints the addresses without broadcasting anything.
/// SETTLEMENT_CONTRACT_ADDRESS=0x9008D19f58AAbD9eD0D60971565AA8510560ab41 \
/// DEPLOYER_PRIVATE_KEY=0xac09…ff80 DEPLOYER_ADDRESS=0x… \
///   forge script script/DeployPrivateTrade.s.sol --rpc-url "$RPC"
///
/// # Sepolia.
/// RPC=https://sepolia.infura.io/v3/$KEY ./scripts/deploy-sepolia.sh
/// ```
contract DeployPrivateTrade is Script {
  /// @dev Where the addresses come from: one definition, shared with the test that freezes them.
  function run() external {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address settlement = vm.envAddress("SETTLEMENT_CONTRACT_ADDRESS");
    bytes32 salt = vm.envOr("DEPLOY_SALT", PrivateTradeDeployment.defaultSalt());

    address deployer = vm.addr(deployerPrivateKey);
    // Optional, and no longer an input to the addresses: foundry's `new{salt}` goes through the
    // canonical CREATE2 proxy, so the addresses are the same whoever sends the transaction. This
    // check only catches "the wrong key is loaded", which is worth catching before a broadcast.
    address expectedDeployer = vm.envOr("DEPLOYER_ADDRESS", address(0));
    require(
      expectedDeployer == address(0) || expectedDeployer == deployer, "DEPLOYER_PRIVATE_KEY is not DEPLOYER_ADDRESS"
    );

    PrivateTradeDeployment.Deployment memory expected = PrivateTradeDeployment.predict(settlement, salt);
    _report(vm.envOr("DEPLOY_MANIFEST", string("")), block.chainid, deployer, salt, settlement, expected);

    vm.startBroadcast(deployerPrivateKey);

    // Deploy only what is missing. The addresses are a function of the init code, so a contract that is
    // already at its predicted address is the exact contract this script would deploy — deploying it
    // again collides rather than replacing it. This is what makes the script re-runnable against a
    // chain that already carries a release: a change to one contract's code moves only that contract's
    // address, and the others are reused instead of blocking the run.
    PrivateTradeWrapper wrapper;
    if (expected.wrapper.code.length > 0) {
      wrapper = PrivateTradeWrapper(expected.wrapper);
    } else {
      wrapper = new PrivateTradeWrapper{salt: salt}(ICowSettlement(settlement));
    }

    PrivateTradeOrder handler;
    if (expected.handler.code.length > 0) {
      handler = PrivateTradeOrder(expected.handler);
    } else {
      handler = new PrivateTradeOrder{salt: salt}(wrapper);
    }

    PrivateTradeSubmitter submitter;
    if (expected.submitter.code.length > 0) {
      submitter = PrivateTradeSubmitter(expected.submitter);
    } else {
      submitter = new PrivateTradeSubmitter{salt: salt}();
    }

    PrivateTradeAuthoriser authoriser;
    if (expected.authoriser.code.length > 0) {
      authoriser = PrivateTradeAuthoriser(expected.authoriser);
    } else {
      authoriser = new PrivateTradeAuthoriser{salt: salt}();
    }

    vm.stopBroadcast();

    // The deployment is only deterministic if the deployed addresses are the predicted ones. If this
    // fails, the init code hash and the creation code have drifted apart and the addresses in the
    // audit report describe something other than what was deployed.
    require(address(wrapper) == expected.wrapper, "wrapper address differs from the predicted one");
    require(address(handler) == expected.handler, "handler address differs from the predicted one");
    require(address(submitter) == expected.submitter, "submitter address differs from the predicted one");
    require(address(authoriser) == expected.authoriser, "authoriser address differs from the predicted one");

    _writeCompatManifest(settlement, deployer, salt, expected);
    _writeChainManifest(vm.envOr("DEPLOY_MANIFEST", string("")), block.chainid, deployer, salt, settlement, expected);
  }

  /// @dev A manifest describes what is on chain, so it is written only when something was. A dry run
  /// prints the same addresses and writes nothing, which keeps it safe to run against a live RPC
  /// while the offline stack's deploy output is in place.
  function _broadcasting() private view returns (bool) {
    return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
  }

  // --- output

  function _report(
    string memory manifest,
    uint256 chainId,
    address deployer,
    bytes32 salt,
    address settlement,
    PrivateTradeDeployment.Deployment memory d
  ) private view {
    console.log("chainId   ", chainId);
    console.log("deployer  ", deployer);
    console.log("settlement", settlement);
    console.log("manifest  ", bytes(manifest).length == 0 ? "(not written)" : manifest);
    console.logBytes32(salt);
    console.log("wrapper   ", d.wrapper);
    console.log("handler   ", d.handler);
    console.log("submitter ", d.submitter);
    console.log("authoriser", d.authoriser);
  }

  function _writeCompatManifest(
    address settlement,
    address deployer,
    bytes32 salt,
    PrivateTradeDeployment.Deployment memory d
  ) private {
    if (!_broadcasting()) return;

    // The path four shell scripts and the link service already read. Keep it.
    vm.writeFile(
      "out-json/private-trade-deployed.json",
      string.concat(
        '{"chainId":',
        vm.toString(block.chainid),
        ',"settlement":"',
        vm.toString(settlement),
        '","deployer":"',
        vm.toString(deployer),
        '","salt":"',
        vm.toString(salt),
        '","wrapper":"',
        vm.toString(d.wrapper),
        '","handler":"',
        vm.toString(d.handler),
        '","submitter":"',
        vm.toString(d.submitter),
        '","authoriser":"',
        vm.toString(d.authoriser),
        '"}\n'
      )
    );
  }

  function _writeChainManifest(
    string memory directory,
    uint256 chainId,
    address deployer,
    bytes32 salt,
    address settlement,
    PrivateTradeDeployment.Deployment memory d
  ) private {
    if (bytes(directory).length == 0) return;
    if (!_broadcasting()) return;
    vm.writeFile(
      string.concat(directory, "/", vm.toString(chainId), ".json"),
      string.concat(
        '{"chainId":',
        vm.toString(chainId),
        ',"settlement":"',
        vm.toString(settlement),
        '","deployer":"',
        vm.toString(deployer),
        '","salt":"',
        vm.toString(salt),
        '","wrapper":"',
        vm.toString(d.wrapper),
        '","handler":"',
        vm.toString(d.handler),
        '","submitter":"',
        vm.toString(d.submitter),
        '","authoriser":"',
        vm.toString(d.authoriser),
        '"}\n'
      )
    );
  }
}
