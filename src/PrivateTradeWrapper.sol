// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {CowWrapper, ICowWrapper, ICowSettlement} from "./vendor/CowWrapper.sol";
import {GPv2Trade} from "cowprotocol/contracts/libraries/GPv2Trade.sol";
import {GPv2Order} from "cowprotocol/contracts/libraries/GPv2Order.sol";
import {GPv2Interaction} from "cowprotocol/contracts/libraries/GPv2Interaction.sol";
import {GPv2Signing} from "cowprotocol/contracts/mixins/GPv2Signing.sol";
import {IERC20} from "cowprotocol/contracts/interfaces/IERC20.sol";

import {
  IPrivateTradeWrapper,
  PrivateOffer,
  PrivateTradeTerms,
  PrivateTrade_OfferIdMismatch,
  PrivateTrade_BadSettlementShape,
  PrivateTrade_InteractionsNotAllowed,
  PrivateTrade_OrderMismatch,
  PrivateTrade_NotReciprocal,
  PrivateTrade_NotFullyFilled,
  PrivateTrade_UnexpectedOwner,
  PrivateTrade_BadTaker,
  PrivateTrade_TakerNotAllowed,
  PrivateTrade_NotLastWrapper,
  PrivateTrade_BadOffer,
  PrivateTrade_Expired,
  PrivateTrade_InvalidSettleData
} from "./interfaces/IPrivateTrade.sol";
import {PrivateTradeLib} from "./libraries/PrivateTradeLib.sol";

/// @title PrivateTradeWrapper
/// @notice A CoW Atomic Bundle. It is the only way a pair of private trade orders can be settled.
///
/// @dev Both orders in a pair are contract orders (EIP-1271) whose validity depends on this
/// contract. The wrapper validates that the settlement it is asked to forward is *exactly* the pair
/// the terms describe, publishes the terms for the duration of the settlement, and only then calls
/// the settlement. The orders' own `verify` implementations read the published terms. Outside that
/// window the orders are unusable, so a leaked order cannot be detached from its counterparty.
///
/// Two Atomic Bundle rules shape this contract:
///
/// 1. `settleData` is not guaranteed to survive the chain: an intermediate bundle can rewrite it
///    after it has been validated. This wrapper therefore refuses to run unless it is the last
///    bundle in the chain, so the calldata it validates is the calldata the settlement executes.
/// 2. `wrapperData` is untrusted input, normally supplied through the order's appData. Every claim
///    it makes is re-checked against the orders and against the published terms.
///
/// The wrapper holds no funds and executes no arbitrary calls.
contract PrivateTradeWrapper is CowWrapper, IPrivateTradeWrapper {
  /// @dev Offer being settled, readable by order handlers during the settlement.
  bytes32 private _activeOfferId;

  /// @dev Counterparty being settled, readable by order handlers during the settlement.
  address private _activeTaker;

  constructor(ICowSettlement settlement_) CowWrapper(settlement_) {}

  /// @inheritdoc IPrivateTradeWrapper
  function activeOfferId() external view returns (bytes32) {
    return _activeOfferId;
  }

  /// @inheritdoc IPrivateTradeWrapper
  function activeTaker() external view returns (address) {
    return _activeTaker;
  }

  /// @inheritdoc ICowWrapper
  function name() external pure override returns (string memory) {
    return "PrivateTradeWrapper";
  }

  /// @inheritdoc ICowWrapper
  /// @param wrapperData `abi.encode(bytes32 declaredOfferId, PrivateTradeTerms terms)`
  function validateWrapperData(bytes calldata wrapperData) external pure override {
    (bytes32 declaredOfferId, PrivateTradeTerms memory terms) = abi.decode(wrapperData, (bytes32, PrivateTradeTerms));
    _validateTerms(declaredOfferId, terms);
  }

  /// @inheritdoc CowWrapper
  function _wrap(bytes calldata settleData, bytes calldata wrapperData, bytes calldata remainingWrapperData)
    internal
    override
  {
    if (remainingWrapperData.length != 0) revert PrivateTrade_NotLastWrapper();

    (bytes32 declaredOfferId, PrivateTradeTerms memory terms) = abi.decode(wrapperData, (bytes32, PrivateTradeTerms));
    bytes32 offerId_ = _validateTerms(declaredOfferId, terms);

    (
      IERC20[] memory tokens,
      uint256[] memory clearingPrices,
      GPv2Trade.Data[] memory trades,
      GPv2Interaction.Data[][3] memory interactions
    ) = _decodeSettleData(settleData);

    _validateSettlement(tokens, clearingPrices, trades, interactions, terms);

    _activeOfferId = offerId_;
    _activeTaker = terms.taker;

    _next(settleData, remainingWrapperData);

    _activeOfferId = bytes32(0);
    _activeTaker = address(0);
  }

  // --- validation

  /// @dev Structural checks on the terms, plus the commitment check. Deterministic by design:
  /// `validateWrapperData` must give the same answer for the same input, so expiry is not
  /// checked here.
  function _validateTerms(bytes32 declaredOfferId, PrivateTradeTerms memory terms)
    private
    pure
    returns (bytes32 offerId_)
  {
    PrivateOffer memory offer = terms.offer;

    if (
      offer.maker == address(0) || offer.sellToken == address(0) || offer.buyToken == address(0)
        || offer.sellToken == offer.buyToken || offer.sellAmount == 0 || offer.buyAmount == 0 || offer.validTo == 0
    ) {
      revert PrivateTrade_BadOffer();
    }
    if (terms.taker == address(0) || terms.taker == offer.maker) revert PrivateTrade_BadTaker();
    if (offer.allowedTaker != address(0) && offer.allowedTaker != terms.taker) {
      revert PrivateTrade_TakerNotAllowed(offer.allowedTaker, terms.taker);
    }

    offerId_ = PrivateTradeLib.offerId(offer);
    if (offerId_ != declaredOfferId) revert PrivateTrade_OfferIdMismatch();
  }

  function _decodeSettleData(bytes calldata settleData)
    private
    pure
    returns (
      IERC20[] memory tokens,
      uint256[] memory clearingPrices,
      GPv2Trade.Data[] memory trades,
      GPv2Interaction.Data[][3] memory interactions
    )
  {
    if (settleData.length < 4 || bytes4(settleData[:4]) != ICowSettlement.settle.selector) {
      revert PrivateTrade_InvalidSettleData();
    }

    (tokens, clearingPrices, trades, interactions) =
      abi.decode(settleData[4:], (IERC20[], uint256[], GPv2Trade.Data[], GPv2Interaction.Data[][3]));
  }

  /// @dev Mirrors `GPv2Trade.extractOrder`, which requires `calldata` tokens that decoded
  /// settlement data cannot provide.
  function _extractOrder(GPv2Trade.Data memory trade, IERC20[] memory tokens, GPv2Order.Data memory order)
    private
    pure
    returns (GPv2Signing.Scheme signingScheme)
  {
    order.sellToken = tokens[trade.sellTokenIndex];
    order.buyToken = tokens[trade.buyTokenIndex];
    order.receiver = trade.receiver;
    order.sellAmount = trade.sellAmount;
    order.buyAmount = trade.buyAmount;
    order.validTo = trade.validTo;
    order.appData = trade.appData;
    order.feeAmount = trade.feeAmount;
    (order.kind, order.partiallyFillable, order.sellTokenBalance, order.buyTokenBalance, signingScheme) =
      GPv2Trade.extractFlags(trade.flags);
  }

  /// @dev Rejects anything that is not an exact, fully-filled, interaction-free mirror pair.
  function _validateSettlement(
    IERC20[] memory tokens,
    uint256[] memory clearingPrices,
    GPv2Trade.Data[] memory trades,
    GPv2Interaction.Data[][3] memory interactions,
    PrivateTradeTerms memory terms
  ) private view {
    if (block.timestamp > terms.offer.validTo) revert PrivateTrade_Expired();

    if (tokens.length != 2 || clearingPrices.length != 2 || trades.length != 2) {
      revert PrivateTrade_BadSettlementShape();
    }
    if (interactions[0].length != 0 || interactions[1].length != 0 || interactions[2].length != 0) {
      revert PrivateTrade_InteractionsNotAllowed();
    }

    // Canonical token order: index 0 is the maker's sell token.
    if (address(tokens[0]) != terms.offer.sellToken || address(tokens[1]) != terms.offer.buyToken) {
      revert PrivateTrade_OrderMismatch(0);
    }
    if (!PrivateTradeLib.isReciprocal(terms, clearingPrices[0], clearingPrices[1])) {
      revert PrivateTrade_NotReciprocal();
    }

    address[2] memory expectedOwners = [terms.offer.maker, terms.taker];
    GPv2Order.Data[] memory expected = new GPv2Order.Data[](2);
    expected[0] = PrivateTradeLib.makerOrder(terms, trades[0].appData);
    expected[1] = PrivateTradeLib.takerOrder(terms, trades[1].appData);

    for (uint256 i = 0; i < 2; ++i) {
      GPv2Order.Data memory order;
      GPv2Signing.Scheme signingScheme = _extractOrder(trades[i], tokens, order);

      if (signingScheme != PrivateTradeLib.scheme() || !PrivateTradeLib.equal(order, expected[i])) {
        revert PrivateTrade_OrderMismatch(i);
      }
      if (trades[i].executedAmount != expected[i].sellAmount) revert PrivateTrade_NotFullyFilled(i);

      // EIP-1271 order owners are carried in the first 20 bytes of the signature, exactly as
      // `GPv2Signing.recoverEip1271Signer` reads them.
      if (trades[i].signature.length <= 20) {
        revert PrivateTrade_UnexpectedOwner(i, expectedOwners[i], address(0));
      }
      address owner = address(bytes20(trades[i].signature));
      if (owner != expectedOwners[i]) revert PrivateTrade_UnexpectedOwner(i, expectedOwners[i], owner);
    }
  }
}
