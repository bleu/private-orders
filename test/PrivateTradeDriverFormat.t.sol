// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IERC20} from "cowprotocol/contracts/interfaces/IERC20.sol";
import {IConditionalOrder} from "composable-cow/interfaces/IConditionalOrder.sol";

import {PrivateTradeTerms, PrivateTradeRole} from "../src/interfaces/IPrivateTrade.sol";
import {PrivateTradeLib} from "../src/libraries/PrivateTradeLib.sol";
import {PrivateTradeAppData} from "../src/libraries/PrivateTradeAppData.sol";
import {PrivateTradeTestBase} from "./utils/PrivateTradeTestBase.sol";

/// @notice Compatibility with the exact bytes the CoW driver produces.
///
/// @dev `crates/driver/.../solution/encoding.rs` builds `settleData` as the normal `settle` calldata
/// and then appends the auction id as four trailing bytes. The wrapper must not choke on that, and
/// it must accept the appData document shape the app-data crate actually parses.
contract PrivateTradeDriverFormatTest is PrivateTradeTestBase {
  /// @dev The trailing auction id must not break the wrapper's decoding of `settleData`.
  function test_settlesWithAppendedAuctionId() public {
    (
      PrivateTradeTerms memory terms,
      IConditionalOrder.ConditionalOrderParams memory makerParams,
      IConditionalOrder.ConditionalOrderParams memory takerParams
    ) = _readyTrade();

    bytes memory settleData = _settleData(terms, makerParams, takerParams);
    bytes memory withAuctionId = bytes.concat(settleData, abi.encode(uint32(123456)));

    vm.prank(solver);
    wrapper.wrappedSettle(withAuctionId, _chainedWrapperData(terms));

    assertEq(wbtc.balanceOf(aliceOwner), WBTC_AMOUNT, "alice did not receive WBTC");
    assertEq(usdc.balanceOf(bobOwner), USDC_AMOUNT, "bob did not receive USDC");
  }

  /// @dev The appData document matches the shape `crates/app-data` parses: `metadata.wrappers[]`
  /// with an `address` key.
  function test_documentMatchesBackendSchema() public {
    PrivateTradeTerms memory terms = _terms(address(bob), address(bob));
    bytes memory data = PrivateTradeAppData.wrapperData(PrivateTradeLib.offerId(terms.offer), terms);
    string memory document = string(PrivateTradeAppData.document(address(wrapper), data));

    assertEq(vm.parseJsonString(document, ".version"), "0.9.0");
    assertEq(vm.parseJsonAddress(document, ".metadata.wrappers[0].address"), address(wrapper));
    assertEq(vm.parseJsonBool(document, ".metadata.wrappers[0].isOmittable"), false);
  }

  /// @dev A chain that places another bundle after this one is refused, because that bundle could
  /// rewrite the calldata after validation.
  function test_rejectsChainWithBundleAfterUs() public {
    (
      PrivateTradeTerms memory terms,
      IConditionalOrder.ConditionalOrderParams memory makerParams,
      IConditionalOrder.ConditionalOrderParams memory takerParams
    ) = _readyTrade();

    bytes memory bundleData = _wrapperData(terms);
    bytes memory chained = abi.encodePacked(uint16(bundleData.length), bundleData, address(wrapper), uint16(0));

    bytes memory settleData = _settleData(terms, makerParams, takerParams);

    vm.prank(solver);
    vm.expectRevert(bytes4(keccak256("PrivateTrade_NotLastWrapper()")));
    wrapper.wrappedSettle(settleData, chained);
  }
}
