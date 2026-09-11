// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {GPv2Wrapper} from 'cowprotocol/contracts/GPv2Wrapper.sol';
import {GPv2Trade} from 'cowprotocol/contracts/libraries/GPv2Trade.sol';
import {GPv2Order} from 'cowprotocol/contracts/libraries/GPv2Order.sol';
import {GPv2Interaction} from 'cowprotocol/contracts/libraries/GPv2Interaction.sol';
import {GPv2Signing} from 'cowprotocol/contracts/mixins/GPv2Signing.sol';
import {IERC20} from 'cowprotocol/contracts/interfaces/IERC20.sol';

import {
    IPrivateTradeWrapper,
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
    PrivateTrade_NoActiveTrade
} from './interfaces/IPrivateTrade.sol';
import {PrivateTradeLib} from './libraries/PrivateTradeLib.sol';

/// @title PrivateTradeWrapper
/// @notice The only way a pair of private trade orders can be settled.
///
/// @dev Both orders in a pair are contract orders (EIP-1271) whose validity depends on this
/// contract. The wrapper validates that a settlement is *exactly* the pair the terms describe,
/// publishes the terms for the duration of the settlement, and only then calls the real
/// `GPv2Settlement.settle`. The orders' own `verify` implementations read the published terms.
/// Outside that window the orders are unusable, so a leaked order cannot be detached from its
/// counterparty or filled by an unrelated solver.
///
/// The wrapper holds no funds and executes no arbitrary interactions: it forwards to the
/// settlement and nothing else.
contract PrivateTradeWrapper is GPv2Wrapper, IPrivateTradeWrapper {
    /// @dev Offer being settled, readable by order handlers during `settle`.
    bytes32 private _activeOfferId;

    /// @dev Counterparty being settled, readable by order handlers during `settle`.
    address private _activeTaker;

    /// @dev Belt-and-braces reentrancy lock. `GPv2Settlement.settle` is already non-reentrant.
    bool private _settling;

    constructor(address payable upstreamSettlement_) GPv2Wrapper(upstreamSettlement_) {}

    /// @inheritdoc IPrivateTradeWrapper
    function activeOfferId() external view returns (bytes32) {
        return _activeOfferId;
    }

    /// @inheritdoc IPrivateTradeWrapper
    function activeTaker() external view returns (address) {
        return _activeTaker;
    }

    /// @inheritdoc GPv2Wrapper
    /// @param wrapperData `abi.encode(bytes32 declaredOfferId, PrivateTradeTerms terms)`
    function _wrap(
        IERC20[] calldata tokens,
        uint256[] calldata clearingPrices,
        GPv2Trade.Data[] calldata trades,
        GPv2Interaction.Data[][3] calldata interactions,
        bytes calldata wrapperData
    ) internal override {
        if (_settling) revert PrivateTrade_NoActiveTrade();
        _settling = true;

        (bytes32 declaredOfferId, PrivateTradeTerms memory terms) =
            abi.decode(wrapperData, (bytes32, PrivateTradeTerms));

        bytes32 id = PrivateTradeLib.offerId(terms.offer);
        if (id != declaredOfferId) revert PrivateTrade_OfferIdMismatch();

        _validate(tokens, clearingPrices, trades, interactions, terms);

        _activeOfferId = id;
        _activeTaker = terms.taker;

        _internalSettle(tokens, clearingPrices, trades, interactions);

        _activeOfferId = bytes32(0);
        _activeTaker = address(0);
        _settling = false;
    }

    /// @dev Rejects anything that is not an exact, fully-filled, interaction-free mirror pair.
    function _validate(
        IERC20[] calldata tokens,
        uint256[] calldata clearingPrices,
        GPv2Trade.Data[] calldata trades,
        GPv2Interaction.Data[][3] calldata interactions,
        PrivateTradeTerms memory terms
    ) private pure {
        if (tokens.length != 2 || clearingPrices.length != 2 || trades.length != 2) {
            revert PrivateTrade_BadSettlementShape();
        }
        if (
            interactions[0].length != 0 || interactions[1].length != 0 || interactions[2].length != 0
        ) {
            revert PrivateTrade_InteractionsNotAllowed();
        }

        // The taker must be a real, distinct counterparty.
        if (terms.taker == address(0) || terms.taker == terms.offer.maker) revert PrivateTrade_BadTaker();
        if (terms.offer.allowedTaker != address(0) && terms.offer.allowedTaker != terms.taker) {
            revert PrivateTrade_TakerNotAllowed(terms.offer.allowedTaker, terms.taker);
        }

        // Canonical token order: index 0 is the maker's sell token.
        if (
            address(tokens[0]) != terms.offer.sellToken || address(tokens[1]) != terms.offer.buyToken
        ) {
            revert PrivateTrade_OrderMismatch(0);
        }
        if (!PrivateTradeLib.isReciprocal(terms, clearingPrices[0], clearingPrices[1])) {
            revert PrivateTrade_NotReciprocal();
        }

        address[2] memory expectedOwners = [terms.offer.maker, terms.taker];
        GPv2Order.Data[] memory expected = new GPv2Order.Data[](2);
        expected[0] = PrivateTradeLib.makerOrder(terms);
        expected[1] = PrivateTradeLib.takerOrder(terms);

        for (uint256 i = 0; i < 2; ++i) {
            GPv2Order.Data memory order;
            GPv2Signing.Scheme signingScheme = GPv2Trade.extractOrder(trades[i], tokens, order);

            if (signingScheme != PrivateTradeLib.scheme() || !PrivateTradeLib.equal(order, expected[i])) {
                revert PrivateTrade_OrderMismatch(i);
            }
            if (trades[i].executedAmount != expected[i].sellAmount) revert PrivateTrade_NotFullyFilled(i);

            // EIP-1271 order owners are carried in the first 20 bytes of the signature, exactly as
            // `GPv2Signing.recoverOrderFromEip1271` does it.
            if (trades[i].signature.length <= 20) revert PrivateTrade_UnexpectedOwner(i, expectedOwners[i], address(0));
            address owner = address(bytes20(trades[i].signature));
            if (owner != expectedOwners[i]) revert PrivateTrade_UnexpectedOwner(i, expectedOwners[i], owner);
        }
    }
}
