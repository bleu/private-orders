// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Script, console} from "forge-std/Script.sol";

import {PrivateTradeWrapper} from "../src/PrivateTradeWrapper.sol";
import {PrivateTradeOrder} from "../src/PrivateTradeOrder.sol";
import {PrivateTradeSubmitter} from "../src/PrivateTradeSubmitter.sol";
import {PrivateTradeAuthoriser} from "../src/PrivateTradeAuthoriser.sol";
import {ICowSettlement} from "../src/vendor/CowWrapper.sol";

/// @notice Deploys the three contracts a private trade needs on a running chain, and writes their
/// addresses to `out-json/private-trade-deployed.json` for the next script to read.
///
/// @dev The wrapper and the submitter both act from a position CoW's authenticator gates, so both
/// must be allowlisted before anything settles. `scripts/private-trade-e2e.sh` does that with
/// `anvil_impersonateAccount`, because allowlisting is a manager action and cannot be broadcast.
///
/// ```bash
/// SETTLEMENT_CONTRACT_ADDRESS=0x9008…ab41 DEPLOYER_PRIVATE_KEY=0xac09…ff80 \
///   forge script script/DeployPrivateTrade.s.sol --rpc-url http://localhost:8545 --broadcast
/// ```
contract DeployPrivateTrade is Script {
  function run() external {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address settlement = vm.envAddress("SETTLEMENT_CONTRACT_ADDRESS");

    vm.startBroadcast(deployerPrivateKey);

    PrivateTradeWrapper wrapper = new PrivateTradeWrapper(ICowSettlement(settlement));
    PrivateTradeOrder handler = new PrivateTradeOrder(wrapper);
    PrivateTradeSubmitter submitter = new PrivateTradeSubmitter();
    PrivateTradeAuthoriser authoriser = new PrivateTradeAuthoriser();

    vm.stopBroadcast();

    string memory json = string.concat(
      '{"settlement":"',
      vm.toString(settlement),
      '","wrapper":"',
      vm.toString(address(wrapper)),
      '","handler":"',
      vm.toString(address(handler)),
      '","submitter":"',
      vm.toString(address(submitter)),
      '","authoriser":"',
      vm.toString(address(authoriser)),
      '"}\n'
    );
    vm.writeFile("out-json/private-trade-deployed.json", json);

    console.log("wrapper  ", address(wrapper));
    console.log("handler  ", address(handler));
    console.log("submitter", address(submitter));
    console.log("authoriser", address(authoriser));
  }
}
