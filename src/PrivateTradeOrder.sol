// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {GPv2Order} from "cowprotocol/contracts/libraries/GPv2Order.sol";
import {CowWrapper} from "./vendor/CowWrapper.sol";
import {IERC165} from "safe/interfaces/IERC165.sol";
import {IConditionalOrder, IConditionalOrderGenerator} from "composable-cow/interfaces/IConditionalOrder.sol";

import {
  IPrivateTradeWrapper,
  PrivateTradeRole,
  PrivateTradeTerms,
  PrivateTradeOfferState,
  PrivateTrade_NoActiveTrade,
  PrivateTrade_WrongActiveOffer,
  PrivateTrade_WrongActiveTaker,
  PrivateTrade_NotSettlementCaller,
  PrivateTrade_BadOrderHash,
  PrivateTrade_OwnerRoleMismatch,
  PrivateTrade_OrderMismatch,
  PrivateTrade_TakerNotAllowed,
  PrivateTrade_BadTaker,
  PrivateTrade_UnexpectedOffchainInput
} from "./interfaces/IPrivateTrade.sol";
import {PrivateTradeLib} from "./libraries/PrivateTradeLib.sol";

/// @title PrivateTradeOrder
/// @notice A ComposableCoW conditional order handler that makes an order valid only inside the
/// private trade settlement that pairs it with its counterparty.
///
/// @dev Used for **both** halves of a pair. `staticInput` carries the role and the full terms, so
/// one deployed handler serves every private trade. `verify` reads the terms published by
/// `PrivateTradeWrapper`, which exist only while the wrapper is inside `GPv2Settlement.settle`.
///
/// This is what makes the counterparty restriction on-chain rather than a service promise: a
/// stolen order replayed outside its pair finds no active trade and reverts inside GPv2's
/// signature validation.
contract PrivateTradeOrder is IConditionalOrderGenerator {
  /// @notice Wrapper that must be the one settling this order.
  IPrivateTradeWrapper public immutable WRAPPER;

  /// @notice Settlement contract orders are validated against.
  address public immutable SETTLEMENT;

  constructor(IPrivateTradeWrapper wrapper) {
    WRAPPER = wrapper;
    SETTLEMENT = address(CowWrapper(address(wrapper)).SETTLEMENT());
  }

  /// @inheritdoc IConditionalOrder
  /// @param staticInput `abi.encode(PrivateTradeRole role, PrivateTradeTerms terms)`
  function verify(
    address owner,
    address sender,
    bytes32 _hash,
    bytes32 domainSeparator,
    bytes32,
    bytes calldata staticInput,
    bytes calldata offchainInput,
    GPv2Order.Data calldata order
  ) external view {
    // ComposableCoW requires `offchainInput` to be validated. This order has none: the terms are
    // fully known at creation, so anything non-empty is refused rather than ignored.
    if (offchainInput.length != 0) revert PrivateTrade_UnexpectedOffchainInput();

    (PrivateTradeRole role, PrivateTradeTerms memory terms) =
      abi.decode(staticInput, (PrivateTradeRole, PrivateTradeTerms));

    _requireSettlementCaller(sender);
    _requireOrderHash(_hash, domainSeparator, order);
    _requireRoleOwner(role, owner, terms, _requireActiveTrade(terms));
    _requireOrderMatches(role, order, terms);
  }

  /// @inheritdoc IConditionalOrderGenerator
  /// @dev Off-chain helper: the order a party must authorise for these terms. Mirrors `verify`, and
  /// answers with the error codes a watch tower understands, so a dead offer is pruned instead of
  /// retried forever (`IConditionalOrder.PollNever`).
  function getTradeableOrder(address owner, address, bytes32, bytes calldata staticInput, bytes calldata offchainInput)
    external
    view
    returns (GPv2Order.Data memory)
  {
    if (offchainInput.length != 0) revert PrivateTrade_UnexpectedOffchainInput();

    (PrivateTradeRole role, PrivateTradeTerms memory terms) =
      abi.decode(staticInput, (PrivateTradeRole, PrivateTradeTerms));

    address expectedOwner = role == PrivateTradeRole.Maker ? terms.offer.maker : terms.taker;
    if (owner != expectedOwner) revert PrivateTrade_OwnerRoleMismatch(role, expectedOwner, owner);
    if (terms.taker == address(0) || terms.taker == terms.offer.maker) revert PrivateTrade_BadTaker();

    if (WRAPPER.offerState(PrivateTradeLib.offerId(terms.offer)) != PrivateTradeOfferState.Available) {
      revert IConditionalOrder.PollNever("private trade is no longer available");
    }
    if (block.timestamp > terms.offer.validTo) revert IConditionalOrder.PollNever("private trade has expired");

    return _orderFor(role, terms, bytes32(0));
  }

  /// @inheritdoc IERC165
  function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
    return interfaceId == type(IConditionalOrderGenerator).interfaceId
      || interfaceId == type(IConditionalOrder).interfaceId || interfaceId == type(IERC165).interfaceId;
  }

  // --- checks

  function _requireSettlementCaller(address sender) private view {
    if (sender != SETTLEMENT) revert PrivateTrade_NotSettlementCaller(SETTLEMENT, sender);
  }

  function _requireOrderHash(bytes32 _hash, bytes32 domainSeparator, GPv2Order.Data calldata order) private pure {
    if (_hash != GPv2Order.hash(order, domainSeparator)) revert PrivateTrade_BadOrderHash();
  }

  /// @dev The heart of the protocol: `activeOfferId` is non-zero only during a settlement that
  /// the wrapper has already proven to be this exact pair.
  function _requireActiveTrade(PrivateTradeTerms memory terms) private view returns (address activeTaker) {
    bytes32 activeOfferId = WRAPPER.activeOfferId();
    if (activeOfferId == bytes32(0)) revert PrivateTrade_NoActiveTrade();

    bytes32 expectedOfferId = PrivateTradeLib.offerId(terms.offer);
    if (activeOfferId != expectedOfferId) {
      revert PrivateTrade_WrongActiveOffer(expectedOfferId, activeOfferId);
    }

    activeTaker = WRAPPER.activeTaker();
    if (activeTaker != terms.taker) revert PrivateTrade_WrongActiveTaker(terms.taker, activeTaker);
  }

  function _requireRoleOwner(PrivateTradeRole role, address owner, PrivateTradeTerms memory terms, address activeTaker)
    private
    pure
  {
    if (role == PrivateTradeRole.Maker) {
      if (owner != terms.offer.maker) {
        revert PrivateTrade_OwnerRoleMismatch(role, terms.offer.maker, owner);
      }
      if (terms.offer.allowedTaker != address(0) && terms.offer.allowedTaker != activeTaker) {
        revert PrivateTrade_TakerNotAllowed(terms.offer.allowedTaker, activeTaker);
      }
    } else if (owner != terms.taker) {
      revert PrivateTrade_OwnerRoleMismatch(role, terms.taker, owner);
    }
  }

  function _requireOrderMatches(PrivateTradeRole role, GPv2Order.Data calldata order, PrivateTradeTerms memory terms)
    private
    pure
  {
    if (!PrivateTradeLib.equal(order, _orderFor(role, terms, order.appData))) {
      revert PrivateTrade_OrderMismatch(0);
    }
  }

  /// @dev `appData` comes from the order being validated, so this compares every field except
  /// appData. AppData agreement between the two orders is enforced by the wrapper.
  function _orderFor(PrivateTradeRole role, PrivateTradeTerms memory terms, bytes32 appData)
    private
    pure
    returns (GPv2Order.Data memory)
  {
    return role == PrivateTradeRole.Maker
      ? PrivateTradeLib.makerOrder(terms, appData)
      : PrivateTradeLib.takerOrder(terms, appData);
  }
}
