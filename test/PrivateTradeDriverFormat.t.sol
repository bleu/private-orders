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
/// @dev `crates/driver/.../solution/encoding.rs` builds `settleData` as the normal `settle` calldata and
/// then appends bytes. The wrapper must not choke on what follows the calldata, and it must emit the
/// appData document shape the app-data crate reads.
///
/// What this can and cannot establish is worth being precise about. It exercises both appendix widths,
/// because the wrapper decodes by offsets and what it relies on is that nothing after the settle
/// calldata is read — not that the appendix is four bytes or thirty-two. And it checks the document's
/// field names in Solidity; the Rust parser that consumes them is exercised by the service checks, not
/// here.
contract PrivateTradeDriverFormatTest is PrivateTradeTestBase {
  /// @dev An appendix the width of an ABI word must not break the wrapper's decoding of `settleData`.
  function test_settlesWithAnAbiWordAfterTheSettleData() public {
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

  /// @dev Four trailing bytes, which is what the comment on this suite originally described.
  function test_settlesWithFourTrailingAuctionIdBytes() public {
    (
      PrivateTradeTerms memory terms,
      IConditionalOrder.ConditionalOrderParams memory makerParams,
      IConditionalOrder.ConditionalOrderParams memory takerParams
    ) = _readyTrade();

    bytes memory settleData = _settleData(terms, makerParams, takerParams);
    vm.prank(solver);
    wrapper.wrappedSettle(bytes.concat(settleData, abi.encodePacked(uint32(123456))), _chainedWrapperData(terms));

    assertEq(wbtc.balanceOf(aliceOwner), WBTC_AMOUNT, "alice did not receive WBTC");
    assertEq(usdc.balanceOf(bobOwner), USDC_AMOUNT, "bob did not receive USDC");
  }

  /// @dev The appData document carries the field names the services read: `metadata.wrappers[]` with an
  /// `address` key and a `data` value. The docs say `target`; the Rust deserializer says `address`.
  function test_documentCarriesTheFieldNamesTheServiceReads() public {
    PrivateTradeTerms memory terms = _terms(address(bob), address(bob));
    bytes memory data = PrivateTradeAppData.wrapperData(PrivateTradeLib.offerId(terms.offer), terms);
    string memory document = string(PrivateTradeAppData.document(address(wrapper), data));

    assertEq(vm.parseJsonString(document, ".version"), "0.9.0");
    assertEq(vm.parseJsonAddress(document, ".metadata.wrappers[0].address"), address(wrapper));
    assertEq(vm.parseJsonBool(document, ".metadata.wrappers[0].isOmittable"), false);
    // Always supplied, even though the services treat it as optional: the wrapper's own data is what
    // the driver hands it, so omitting it would rely on a default that carries nothing.
    assertGt(bytes(vm.parseJsonString(document, ".metadata.wrappers[0].data")).length, 2, "wrapper data is empty");
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
