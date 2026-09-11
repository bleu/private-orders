// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {GPv2Trade} from "cowprotocol/contracts/libraries/GPv2Trade.sol";
import {IConditionalOrder} from "composable-cow/interfaces/IConditionalOrder.sol";

import {
  PrivateTradeTerms,
  PrivateTradeRole,
  PrivateTrade_AppDataMismatch,
  PrivateTrade_WrongActiveOffer
} from "../src/interfaces/IPrivateTrade.sol";
import {PrivateTradeLib} from "../src/libraries/PrivateTradeLib.sol";
import {PrivateTradeAppData} from "../src/libraries/PrivateTradeAppData.sol";
import {CowWrapperHelpers} from "../src/vendor/CowWrapperHelpers.sol";
import {PrivateTradeTestBase} from "./utils/PrivateTradeTestBase.sol";

/// @notice The order-side path: a private trade declared in order appData, parsed the way a solver
/// and the driver would parse it, encoded by the official `CowWrapperHelpers`, then settled.
contract PrivateTradeAppDataTest is PrivateTradeTestBase {
  /// @dev Build the document, hash it, put the hash in both orders, then have the "driver" read
  /// the document back and encode the chain.
  function test_settlesThroughAppDataDeclaredBundle() public {
    PrivateTradeTerms memory terms = _terms(address(bob), address(bob));

    bytes memory bundleData = PrivateTradeAppData.wrapperData(PrivateTradeLib.offerId(terms.offer), terms);
    bytes memory document = PrivateTradeAppData.document(address(wrapper), bundleData);
    bytes32 appData = keccak256(document);

    assertEq(appData, PrivateTradeAppData.documentHash(address(wrapper), bundleData));

    _fund(alice, usdc, USDC_AMOUNT);
    _approveRelayer(alice, usdc, USDC_AMOUNT);
    _fund(bob, wbtc, WBTC_AMOUNT);
    _approveRelayer(bob, wbtc, WBTC_AMOUNT);

    IConditionalOrder.ConditionalOrderParams memory makerParams =
      _authorize(alice, PrivateTradeRole.Maker, terms, "maker");
    IConditionalOrder.ConditionalOrderParams memory takerParams =
      _authorize(bob, PrivateTradeRole.Taker, terms, "taker");

    GPv2Trade.Data[] memory trades = _tradesWithAppData(terms, makerParams, takerParams, appData);

    // The solver does not know the chain in advance; it reads the document.
    bytes memory chained = _chainFromDocument(document);

    vm.prank(solver);
    wrapper.wrappedSettle(_settleDataWith(_tokens(), _clearingPrices(), trades, _emptyInteractions()), chained);

    assertEq(wbtc.balanceOf(address(alice)), WBTC_AMOUNT, "alice did not receive WBTC");
    assertEq(usdc.balanceOf(address(bob)), USDC_AMOUNT, "bob did not receive USDC");
    assertEq(usdc.balanceOf(address(settlement)), 0, "settlement kept USDC");
  }

  /// @dev A document that is valid JSON but declares different terms produces a different
  /// offerId, and the maker's own order refuses the settlement.
  function test_tamperedBundleDataInDocumentReverts() public {
    PrivateTradeTerms memory terms = _terms(address(bob), address(bob));
    bytes memory honestData = PrivateTradeAppData.wrapperData(PrivateTradeLib.offerId(terms.offer), terms);
    bytes32 appData = PrivateTradeAppData.documentHash(address(wrapper), honestData);

    _fund(alice, usdc, USDC_AMOUNT);
    _approveRelayer(alice, usdc, USDC_AMOUNT);
    _fund(bob, wbtc, WBTC_AMOUNT);
    _approveRelayer(bob, wbtc, WBTC_AMOUNT);

    IConditionalOrder.ConditionalOrderParams memory makerParams =
      _authorize(alice, PrivateTradeRole.Maker, terms, "maker");
    IConditionalOrder.ConditionalOrderParams memory takerParams =
      _authorize(bob, PrivateTradeRole.Taker, terms, "taker");

    // The solver swaps in a document whose bundle data points at a different offer.
    PrivateTradeTerms memory tampered = _terms(address(bob), address(0));
    bytes memory tamperedData = PrivateTradeAppData.wrapperData(PrivateTradeLib.offerId(tampered.offer), tampered);
    bytes memory tamperedDocument = PrivateTradeAppData.document(address(wrapper), tamperedData);

    // Compute every argument before arming `expectRevert`: encoding the chain is itself an
    // external call, and it would consume the expectation.
    bytes memory chained = _chainFromDocument(tamperedDocument);
    bytes memory settleData = _settleDataWith(
      _tokens(), _clearingPrices(), _tradesWithAppData(terms, makerParams, takerParams, appData), _emptyInteractions()
    );

    vm.prank(solver);
    vm.expectRevert(
      abi.encodeWithSelector(
        PrivateTrade_WrongActiveOffer.selector,
        PrivateTradeLib.offerId(terms.offer),
        PrivateTradeLib.offerId(tampered.offer)
      )
    );
    wrapper.wrappedSettle(settleData, chained);
  }

  /// @dev The two orders must commit to the same appData document.
  function test_mismatchedAppDataReverts() public {
    PrivateTradeTerms memory terms = _terms(address(bob), address(bob));
    bytes memory bundleData = PrivateTradeAppData.wrapperData(PrivateTradeLib.offerId(terms.offer), terms);
    bytes32 appData = PrivateTradeAppData.documentHash(address(wrapper), bundleData);

    _fundAndApprove(terms);
    IConditionalOrder.ConditionalOrderParams memory makerParams =
      _authorize(alice, PrivateTradeRole.Maker, terms, "maker");
    IConditionalOrder.ConditionalOrderParams memory takerParams =
      _authorize(bob, PrivateTradeRole.Taker, terms, "taker");

    GPv2Trade.Data[] memory trades = _tradesWithAppData(terms, makerParams, takerParams, appData);
    bytes32 other = keccak256("a different document");
    trades[1].appData = other;

    // Every argument is computed before arming `expectRevert`, because encoding the chain is
    // itself an external call and would consume the expectation.
    bytes memory chained = _chainFromDocument(PrivateTradeAppData.document(address(wrapper), bundleData));
    bytes memory settleData = _settleDataWith(_tokens(), _clearingPrices(), trades, _emptyInteractions());

    vm.prank(solver);
    vm.expectRevert(abi.encodeWithSelector(PrivateTrade_AppDataMismatch.selector, appData, other));
    wrapper.wrappedSettle(settleData, chained);
  }

  // --- CowWrapperHelpers, exactly as a frontend or SDK would call it

  /// @dev The helper refuses bundles whose data does not pass the wrapper's own validation.
  function test_helpersRejectMalformedBundleData() public {
    PrivateTradeTerms memory terms = _terms(address(bob), address(bob));
    terms.taker = address(alice); // self-taker: structurally invalid

    bytes memory bad = PrivateTradeAppData.wrapperData(PrivateTradeLib.offerId(terms.offer), terms);

    CowWrapperHelpers.WrapperCall[] memory calls = new CowWrapperHelpers.WrapperCall[](1);
    calls[0] = CowWrapperHelpers.WrapperCall({target: address(wrapper), data: bad});

    vm.expectPartialRevert(CowWrapperHelpers.WrapperDataMalformed.selector);
    helpers.verifyAndBuildWrapperData(calls);
  }

  /// @dev Only authenticated bundles can be declared in an order.
  function test_helpersRejectUnauthenticatedBundle() public {
    CowWrapperHelpers.WrapperCall[] memory calls = new CowWrapperHelpers.WrapperCall[](1);
    calls[0] = CowWrapperHelpers.WrapperCall({target: makeAddr("not-a-bundle"), data: hex"00"});

    vm.expectRevert(
      abi.encodeWithSelector(
        CowWrapperHelpers.WrapperNotAuthorized.selector, 0, makeAddr("not-a-bundle"), address(allowList)
      )
    );
    helpers.verifyAndBuildWrapperData(calls);
  }

  /// @dev The helper's encoding is what the wrapper expects: round-trip without hand-encoding.
  function test_helpersEncodingRoundTrips() public {
    PrivateTradeTerms memory terms = _terms(address(bob), address(bob));
    bytes memory data = PrivateTradeAppData.wrapperData(PrivateTradeLib.offerId(terms.offer), terms);

    CowWrapperHelpers.WrapperCall[] memory calls = new CowWrapperHelpers.WrapperCall[](1);
    calls[0] = CowWrapperHelpers.WrapperCall({target: address(wrapper), data: data});

    bytes memory chained = helpers.verifyAndBuildWrapperData(calls);
    assertEq(chained, _chainedWrapperData(terms), "helper encoding differs from the expected chain");
  }

  /// @dev The document is real JSON that a driver can read.
  function test_documentIsParseableAsJson() public {
    PrivateTradeTerms memory terms = _terms(address(bob), address(bob));
    bytes memory data = PrivateTradeAppData.wrapperData(PrivateTradeLib.offerId(terms.offer), terms);
    string memory document = string(PrivateTradeAppData.document(address(wrapper), data));

    assertEq(vm.parseJsonString(document, ".version"), "private-trades/1");
    assertEq(vm.parseJsonAddress(document, ".wrappers[0].target"), address(wrapper));
    assertEq(vm.parseJsonBool(document, ".wrappers[0].isOmittable"), false);
    assertEq(vm.parseJsonBytes(document, ".wrappers[0].data"), data);
  }

  // --- internals

  /// @dev Stands in for the driver: read the declared bundle out of the order's appData document
  /// and encode the chain with the official helper.
  function _chainFromDocument(bytes memory document) internal view returns (bytes memory) {
    string memory json = string(document);
    address target = vm.parseJsonAddress(json, ".wrappers[0].target");
    bytes memory data = vm.parseJsonBytes(json, ".wrappers[0].data");

    CowWrapperHelpers.WrapperCall[] memory calls = new CowWrapperHelpers.WrapperCall[](1);
    calls[0] = CowWrapperHelpers.WrapperCall({target: target, data: data});
    return helpers.verifyAndBuildWrapperData(calls);
  }
}
