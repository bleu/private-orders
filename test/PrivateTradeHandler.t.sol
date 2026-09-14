// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IConditionalOrder} from "composable-cow/interfaces/IConditionalOrder.sol";
import {GPv2Order} from "cowprotocol/contracts/libraries/GPv2Order.sol";

import {
  PrivateTradeTerms,
  PrivateTradeRole,
  PrivateTrade_OwnerRoleMismatch,
  PrivateTrade_UnexpectedOffchainInput
} from "../src/interfaces/IPrivateTrade.sol";
import {PrivateTradeLib} from "../src/libraries/PrivateTradeLib.sol";
import {PrivateTradeTestBase} from "./utils/PrivateTradeTestBase.sol";

/// @notice The handler's side of the ComposableCoW contract: what it refuses, and what it tells a
/// watch tower.
///
/// @dev Two requirements come from the ComposableCoW documentation and are not about settlement:
///
/// 1. An `IConditionalOrder` **MUST** validate `offchainInput`. This order has none — every term is
///    in `staticInput` — so anything non-empty is refused rather than silently ignored.
/// 2. A watch tower classifies an order from the errors its handler raises (`PollNever`,
///    `PollTryAtEpoch`, `OrderNotValid`). A dead offer answers `PollNever`, so it is pruned instead
///    of polled forever.
contract PrivateTradeHandlerTest is PrivateTradeTestBase {
  function test_verifyRejectsOffchainInput() public {
    PrivateTradeTerms memory terms = _terms(address(bob), address(bob));
    IConditionalOrder.ConditionalOrderParams memory params = _params(PrivateTradeRole.Maker, terms, "maker");

    // Read the domain separator first: it is an external call, and `vm.expectRevert` binds to the
    // next call, so computing it inline would spend the expectation on the read.
    bytes32 domainSeparator = settlement.domainSeparator();

    vm.expectRevert(PrivateTrade_UnexpectedOffchainInput.selector);
    handler.verify(
      terms.offer.maker,
      address(settlement),
      bytes32(0),
      domainSeparator,
      bytes32(0),
      params.staticInput,
      hex"01",
      PrivateTradeLib.makerOrder(terms, APP_DATA)
    );
  }

  function test_getTradeableOrderRejectsOffchainInput() public {
    PrivateTradeTerms memory terms = _terms(address(bob), address(bob));
    IConditionalOrder.ConditionalOrderParams memory params = _params(PrivateTradeRole.Maker, terms, "maker");

    vm.expectRevert(PrivateTrade_UnexpectedOffchainInput.selector);
    handler.getTradeableOrder(terms.offer.maker, address(0), bytes32(0), params.staticInput, hex"01");
  }

  /// @dev While the offer is available, the helper answers the order the party must authorise.
  function test_getTradeableOrderReturnsTheOrderWhileAvailable() public {
    PrivateTradeTerms memory terms = _terms(address(bob), address(bob));
    IConditionalOrder.ConditionalOrderParams memory params = _params(PrivateTradeRole.Maker, terms, "maker");

    GPv2Order.Data memory order =
      handler.getTradeableOrder(terms.offer.maker, address(0), bytes32(0), params.staticInput, "");
    assertTrue(PrivateTradeLib.equal(order, PrivateTradeLib.makerOrder(terms, bytes32(0))), "wrong order");
  }

  /// @dev A cancelled offer is dead, not "try again later".
  function test_getTradeableOrderReportsNeverForACancelledOffer() public {
    PrivateTradeTerms memory terms = _terms(address(bob), address(bob));
    IConditionalOrder.ConditionalOrderParams memory params = _params(PrivateTradeRole.Maker, terms, "maker");

    vm.prank(terms.offer.maker);
    wrapper.cancelOffer(terms.offer);

    vm.expectRevert(
      abi.encodeWithSelector(IConditionalOrder.PollNever.selector, "private trade is no longer available")
    );
    handler.getTradeableOrder(terms.offer.maker, address(0), bytes32(0), params.staticInput, "");
  }

  /// @dev And so is an expired one: nothing about it will become tradeable again.
  function test_getTradeableOrderReportsNeverForAnExpiredOffer() public {
    PrivateTradeTerms memory terms = _terms(address(bob), address(bob));
    IConditionalOrder.ConditionalOrderParams memory params = _params(PrivateTradeRole.Maker, terms, "maker");

    vm.warp(uint256(terms.offer.validTo) + 1);

    vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.PollNever.selector, "private trade has expired"));
    handler.getTradeableOrder(terms.offer.maker, address(0), bytes32(0), params.staticInput, "");
  }

  /// @dev The role check still comes first, so a wrong owner is reported as a wrong owner.
  function test_getTradeableOrderRejectsAnOwnerThatIsNotTheSide() public {
    PrivateTradeTerms memory terms = _terms(address(bob), address(bob));
    IConditionalOrder.ConditionalOrderParams memory params = _params(PrivateTradeRole.Maker, terms, "maker");

    vm.expectRevert(
      abi.encodeWithSelector(
        PrivateTrade_OwnerRoleMismatch.selector, PrivateTradeRole.Maker, terms.offer.maker, address(0xBEEF)
      )
    );
    handler.getTradeableOrder(address(0xBEEF), address(0), bytes32(0), params.staticInput, "");
  }
}

/// @dev Re-declared so the selector is available without importing the interface file wholesale.
interface PrivateTrade_OwnerRoleMismatchExpected {
  error PrivateTrade_OwnerRoleMismatch(PrivateTradeRole role, address expected, address actual);
}
