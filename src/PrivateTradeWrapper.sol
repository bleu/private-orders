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
  PrivateTradeOfferState,
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
  PrivateTrade_Reentered,
  PrivateTrade_BadOffer,
  PrivateTrade_Expired,
  PrivateTrade_InvalidSettleData,
  PrivateTrade_SettlementDidNotFill,
  PrivateTrade_AppDataMismatch,
  PrivateTrade_ProposalWrongWrapper,
  PrivateTrade_ProposalExpired,
  PrivateTrade_ProposalPayloadMismatch,
  PrivateTrade_ProposalBadSignature,
  PrivateTrade_OfferConsumed,
  PrivateTrade_OfferCancelled,
  PrivateTrade_NotOfferMaker,
  PrivateTrade_CannotCancelConsumed,
  PrivateTradeOfferConsumed,
  PrivateTradeOfferCancelled,
  PrivateTradeSubmitted
} from "./interfaces/IPrivateTrade.sol";
import {PrivateTradeLib} from "./libraries/PrivateTradeLib.sol";
import {PrivateTradeProposal} from "./libraries/PrivateTradeProposal.sol";

/// @dev The one read this wrapper makes of the settlement's own bookkeeping. Declared here rather
/// than added to the vendored `ICowSettlement`, so that file stays re-vendorable from upstream.
interface IGPv2FilledAmount {
  /// @notice How much of an order GPv2 has filled, by its order UID.
  function filledAmount(bytes calldata orderUid) external view returns (uint256);
}

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
  ///
  /// Transient, because the window is a fact about one transaction: it is opened by `_wrap` and read
  /// by the order handlers while the settlement runs, and it must not be reachable from any other
  /// transaction. Persistent storage would leave a value behind that has to be cleared on every path,
  /// and would write two storage slots in the middle of a settlement.
  bytes32 private transient _activeOfferId;

  /// @dev Counterparty being settled, readable by order handlers during the settlement.
  address private transient _activeTaker;

  /// @dev A maker offer is globally single-use, independent of appData or GPv2 order UID.
  mapping(bytes32 offerId => PrivateTradeOfferState state) private _offerStates;

  constructor(ICowSettlement settlement_) CowWrapper(settlement_) {}

  /// @inheritdoc IPrivateTradeWrapper
  function activeOfferId() external view returns (bytes32) {
    return _activeOfferId;
  }

  /// @inheritdoc IPrivateTradeWrapper
  function activeTrade() external view returns (bytes32, address) {
    return (_activeOfferId, _activeTaker);
  }

  /// @inheritdoc IPrivateTradeWrapper
  function activeTaker() external view returns (address) {
    return _activeTaker;
  }

  /// @inheritdoc IPrivateTradeWrapper
  function offerState(bytes32 offerId_) external view returns (PrivateTradeOfferState) {
    return _offerStates[offerId_];
  }

  /// @inheritdoc IPrivateTradeWrapper
  function cancelOffer(PrivateOffer calldata offer) external {
    if (msg.sender != offer.maker) revert PrivateTrade_NotOfferMaker(offer.maker, msg.sender);

    bytes32 offerId_ = PrivateTradeLib.offerId(offer);
    PrivateTradeOfferState state = _offerStates[offerId_];
    if (state == PrivateTradeOfferState.Consumed) revert PrivateTrade_CannotCancelConsumed(offerId_);
    if (state == PrivateTradeOfferState.Cancelled) return;

    _offerStates[offerId_] = PrivateTradeOfferState.Cancelled;
    emit PrivateTradeOfferCancelled(offerId_);
  }

  /// @inheritdoc ICowWrapper
  function name() external pure override returns (string memory) {
    return "PrivateTradeWrapper";
  }

  /// @inheritdoc ICowWrapper
  /// @param wrapperData `abi.encode(bytes32 declaredOfferId, PrivateTradeTerms terms)`
  function validateWrapperData(bytes calldata wrapperData) external pure override {
    (bytes32 declaredOfferId, PrivateTradeTerms memory terms,) =
      abi.decode(wrapperData, (bytes32, PrivateTradeTerms, PrivateTradeProposal.Proposal));
    _validateTerms(declaredOfferId, terms);
  }

  /// @inheritdoc CowWrapper
  function _wrap(bytes calldata settleData, bytes calldata wrapperData, bytes calldata remainingWrapperData)
    internal
    override
  {
    if (remainingWrapperData.length != 0) revert PrivateTrade_NotLastWrapper();

    // One window at a time. `wrappedSettle` is vendored upstream and unguarded, so a solver that
    // re-enters (or a sell token whose `transferFrom` calls back) could otherwise validate a second
    // pair against this context, or clear it while the outer orders are still being checked. The
    // window is the guarantee, so it refuses to be shared.
    if (_activeOfferId != bytes32(0)) revert PrivateTrade_Reentered();

    FillGuard memory guard = _open(settleData, wrapperData);

    _next(settleData, remainingWrapperData);

    _close(guard);
  }

  /// @dev What `_wrap` reads before the settlement and checks after it.
  struct FillGuard {
    bytes32 offerId;
    bytes makerUid;
    bytes takerUid;
    uint256 makerFilledBefore;
    uint256 takerFilledBefore;
  }

  /// @dev Everything that has to be true, and everything that has to be recorded, before the settlement
  /// runs: the payload against the terms, the terms against the offer, the orders, the offer's own
  /// state, and the context the order handlers read while it executes.
  ///
  /// Split out of `_wrap` because `_wrap` does not have the stack for it, and because the two halves
  /// are the honest description of what happens: the window opens, the settlement runs, the window
  /// closes and the claim is checked.
  function _open(bytes calldata settleData, bytes calldata wrapperData) private returns (FillGuard memory guard) {
    (bytes32 declaredOfferId, PrivateTradeTerms memory terms, PrivateTradeProposal.Proposal memory proposal) =
      abi.decode(wrapperData, (bytes32, PrivateTradeTerms, PrivateTradeProposal.Proposal));
    bytes32 offerId_ = _validateTerms(declaredOfferId, terms);
    _validateProposal(proposal, terms, offerId_);

    // Cheapest first. A consumed or cancelled offer is refused before the payload is decoded, every
    // order is rebuilt and compared, and the fills are read — which is the entire cost of a submission
    // that was never going to be accepted. The consumed *write* stays where it is, after everything
    // has been checked.
    PrivateTradeOfferState state = _offerStates[offerId_];
    if (state == PrivateTradeOfferState.Consumed) revert PrivateTrade_OfferConsumed(offerId_);
    if (state == PrivateTradeOfferState.Cancelled) revert PrivateTrade_OfferCancelled(offerId_);

    (
      IERC20[] memory tokens,
      uint256[] memory clearingPrices,
      GPv2Trade.Data[] memory trades,
      GPv2Interaction.Data[][3] memory interactions
    ) = _decodeSettleData(settleData);

    // D2: the same orders the settlement was just validated against, rather than extracting and
    // rebuilding them a second time to derive the identifiers.
    GPv2Order.Data[2] memory settled = _validateSettlement(tokens, clearingPrices, trades, interactions, terms);

    // Read before the settlement runs, so that afterwards we can tell "the settlement succeeded" from
    // "the trade happened".
    (guard.makerUid, guard.takerUid) = _orderUids(settled, terms);
    guard.makerFilledBefore = _filled(guard.makerUid);
    guard.takerFilledBefore = _filled(guard.takerUid);

    // Effects precede the settlement call. Any downstream revert rolls this transition back.
    _offerStates[offerId_] = PrivateTradeOfferState.Consumed;
    emit PrivateTradeOfferConsumed(offerId_, terms.taker);

    _activeOfferId = offerId_;
    _activeTaker = terms.taker;
    guard.offerId = offerId_;
  }

  /// @dev The window closes, and the claim is checked. Returning from the settlement means the calldata
  /// was accepted; it does not by itself mean a fill was recorded. Validating the calldata proves the
  /// orders were the right ones and were priced reciprocally — `filledAmount` is the settlement's own
  /// record of what it moved. A bundle that returns without delivering is exactly what the framework
  /// documentation warns about, and it deserves its own error rather than being inferred.
  function _close(FillGuard memory guard) private {
    _activeOfferId = bytes32(0);
    _activeTaker = address(0);

    if (_filled(guard.makerUid) <= guard.makerFilledBefore) {
      revert PrivateTrade_SettlementDidNotFill(0, guard.offerId);
    }
    if (_filled(guard.takerUid) <= guard.takerFilledBefore) {
      revert PrivateTrade_SettlementDidNotFill(1, guard.offerId);
    }
  }

  /// @dev What GPv2 has filled of an order, by its own identifier. Declared here rather than added to
  /// the vendored `ICowSettlement`, so that file stays re-vendorable from upstream.
  function _filled(bytes memory orderUid) private view returns (uint256) {
    return IGPv2FilledAmount(address(SETTLEMENT)).filledAmount(orderUid);
  }

  // --- validation

  /// @dev A BYOS sub-solver signs *the pair* it is submitting, so a submission can be attributed: the
  /// signature covers the offer, the counterparty and this wrapper. It does not cover the settlement
  /// bytes — the same pair has more than one encoding, and the commitment travels inside the orders'
  /// appData, so hashing the calldata would be circular. BYOS's `interactionsHash` covers its routing
  /// payload; this covers less, which is worth knowing before relying on it to apportion blame for a
  /// revert.
  ///
  /// An unsigned proposal skips the check: the trade is still fully validated, and anyone may
  /// submit a pair both parties signed.
  function _validateProposal(
    PrivateTradeProposal.Proposal memory proposal,
    PrivateTradeTerms memory terms,
    bytes32 offerId_
  ) private {
    if (PrivateTradeProposal.isUnsigned(proposal)) return;

    if (proposal.wrapper != address(this)) {
      revert PrivateTrade_ProposalWrongWrapper(address(this), proposal.wrapper);
    }
    if (block.timestamp > proposal.validUntil) revert PrivateTrade_ProposalExpired(proposal.validUntil);

    bytes32 expected = PrivateTradeProposal.termsHash(offerId_, terms.taker, address(this));
    if (proposal.termsHash != expected) {
      revert PrivateTrade_ProposalPayloadMismatch(expected, proposal.termsHash);
    }

    address subSolver = PrivateTradeProposal.recover(proposal, address(this));
    if (subSolver == address(0)) revert PrivateTrade_ProposalBadSignature();

    // Attribution: the recovered signer is the identity, exactly as in BYOS's own model.
    emit PrivateTradeSubmitted(subSolver, offerId_);
  }

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
  ) private view returns (GPv2Order.Data[2] memory expected) {
    if (block.timestamp > terms.offer.validTo) revert PrivateTrade_Expired();

    // Exactly the pair, and nothing else. The token array is not required to be exactly two
    // entries: the driver emits one entry per order side, so the same token can appear several
    // times. What matters is that both orders are present and that their prices are reciprocal,
    // which is checked below through each trade's own token indices.
    if (trades.length != 2 || clearingPrices.length != tokens.length || tokens.length < 2) {
      revert PrivateTrade_BadSettlementShape();
    }
    if (interactions[0].length != 0 || interactions[1].length != 0 || interactions[2].length != 0) {
      revert PrivateTrade_InteractionsNotAllowed();
    }

    // Both orders must point at the same appData document, which is where the bundle declaration
    // lives. The document hash cannot be part of the terms (that would be a cycle), so the two
    // orders are only required to agree with each other.
    if (trades[0].appData != trades[1].appData) {
      revert PrivateTrade_AppDataMismatch(trades[0].appData, trades[1].appData);
    }

    address[2] memory expectedOwners = [terms.offer.maker, terms.taker];

    expected[0] = PrivateTradeLib.makerOrder(terms, trades[0].appData);
    expected[1] = PrivateTradeLib.takerOrder(terms, trades[1].appData);

    for (uint256 i = 0; i < 2; ++i) {
      if (trades[i].sellTokenIndex >= tokens.length || trades[i].buyTokenIndex >= tokens.length) {
        revert PrivateTrade_BadSettlementShape();
      }
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

    // Validate through each trade's own indices. Equal token addresses do not imply equal entries
    // in the price vector: a settlement may contain the same token more than once.
    if (!PrivateTradeLib.isReciprocal(
        terms,
        clearingPrices[trades[0].sellTokenIndex],
        clearingPrices[trades[0].buyTokenIndex],
        clearingPrices[trades[1].sellTokenIndex],
        clearingPrices[trades[1].buyTokenIndex]
      )) {
      revert PrivateTrade_NotReciprocal();
    }
  }

  /// @dev The identifiers the settlement records fills against: the EIP-712 order hash, its owner and
  /// its expiry, exactly as GPv2 builds an order UID. Taken from the trades themselves, which
  /// `_validateSettlement` has already required to equal the orders the terms imply.
  ///
  /// Separate from `_validateSettlement` because neither function has room for the other's locals.
  function _orderUids(GPv2Order.Data[2] memory settled, PrivateTradeTerms memory terms)
    private
    view
    returns (bytes memory makerUid, bytes memory takerUid)
  {
    bytes32 domainSeparator = SETTLEMENT.domainSeparator();
    makerUid = abi.encodePacked(GPv2Order.hash(settled[0], domainSeparator), terms.offer.maker, settled[0].validTo);
    takerUid = abi.encodePacked(GPv2Order.hash(settled[1], domainSeparator), terms.taker, settled[1].validTo);
  }
}
