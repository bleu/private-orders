// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

/// @title Private Trades - shared types
/// @notice A Private Trade is a pair of reciprocal, fill-or-kill CoW orders that are
/// valid **only** inside the settlement that executes both of them together.

/// @dev Which half of the pair a conditional order represents.
enum PrivateTradeRole {
  Maker,
  Taker
}

/// @dev The terms one party commits to when creating a private offer.
/// @param maker The contract account that owns the maker order (CoW Shed, Safe, custom wallet).
/// @param allowedTaker Address permitted to accept, or `address(0)` for anyone holding the link.
/// @param sellToken Token the maker gives.
/// @param sellAmount Exact amount the maker gives.
/// @param buyToken Token the maker receives.
/// @param buyAmount Exact amount the maker receives.
/// @param validTo Unix timestamp after which the offer is dead.
/// @param salt Unique per offer, so identical terms can be re-issued.
struct PrivateOffer {
  address maker;
  address allowedTaker;
  address sellToken;
  uint256 sellAmount;
  address buyToken;
  uint256 buyAmount;
  uint32 validTo;
  bytes32 salt;
}

/// @dev The concrete pair being settled: an offer plus the taker that accepted it.
/// @param offer The maker's terms.
/// @param taker The counterparty accepting this offer, as an order-owning contract.
/// @param appData CoW appData hash both orders must commit to.
struct PrivateTradeTerms {
  PrivateOffer offer;
  address taker;
}

/// @dev Raised when the wrapper's declared `offerId` does not match the offer it carries.
error PrivateTrade_OfferIdMismatch();

/// @dev Raised when the settlement does not contain exactly two tokens and two trades.
error PrivateTrade_BadSettlementShape();

/// @dev Raised when any pre/intra/post interaction is present. A private trade executes nothing else.
error PrivateTrade_InteractionsNotAllowed();

/// @dev Raised when a trade does not match the order the terms imply, or uses the wrong signing scheme.
error PrivateTrade_OrderMismatch(uint256 tradeIndex);

/// @dev Raised when the two sides are not exact mirrors at the declared clearing prices.
error PrivateTrade_NotReciprocal();

/// @dev Raised when a trade is not a full fill.
error PrivateTrade_NotFullyFilled(uint256 tradeIndex);

/// @dev Raised when the settlement's owner (from the EIP-1271 signature) is not the expected party.
error PrivateTrade_UnexpectedOwner(uint256 tradeIndex, address expected, address actual);

/// @dev Raised when the taker is unset, or is the maker.
error PrivateTrade_BadTaker();

/// @dev Raised when the maker restricted the offer to a different counterparty.
error PrivateTrade_TakerNotAllowed(address allowed, address actual);

/// @dev Raised when an order is validated outside of an active private trade settlement.
error PrivateTrade_NoActiveTrade();

/// @dev Raised when an order is validated during a settlement for a different offer.
error PrivateTrade_WrongActiveOffer(bytes32 expected, bytes32 actual);

/// @dev Raised when an order is validated during a settlement for a different counterparty.
error PrivateTrade_WrongActiveTaker(address expected, address actual);

/// @dev Raised when the caller of `verify` is not the settlement contract.
error PrivateTrade_NotSettlementCaller(address expected, address actual);

/// @dev Raised when the order hash supplied does not match the order.
error PrivateTrade_BadOrderHash();

/// @dev Raised when `verify` is called for an owner that does not match the role.
error PrivateTrade_OwnerRoleMismatch(PrivateTradeRole role, address expected, address actual);

/// @dev Raised when the bundle is not the last one in the chain.
/// @dev Nothing may run between this wrapper's validation and `GPv2Settlement.settle`, because an
/// intermediate bundle can rewrite the settlement calldata after it has been validated.
error PrivateTrade_NotLastWrapper();

/// @dev Raised when the offer itself is structurally unusable.
error PrivateTrade_BadOffer();

/// @dev Raised when the offer's expiry has passed.
error PrivateTrade_Expired();

/// @dev Raised when `settleData` is not a call to `settle`.
error PrivateTrade_InvalidSettleData();

/// @dev Raised when an attached sub-solver proposal names a different wrapper.
error PrivateTrade_ProposalWrongWrapper(address expected, address actual);

/// @dev Raised when an attached sub-solver proposal has expired.
error PrivateTrade_ProposalExpired(uint256 validUntil);

/// @dev Raised when the executed settlement is not the one the sub-solver signed.
error PrivateTrade_ProposalPayloadMismatch(bytes32 expected, bytes32 actual);

/// @dev Raised when an attached sub-solver proposal signature does not recover.
error PrivateTrade_ProposalBadSignature();

/// @notice Emitted when a signed sub-solver proposal was verified and executed, for attribution.
event PrivateTradeSubmitted(address indexed subSolver, bytes32 indexed offerId);

/// @dev Raised when the two orders do not commit to the same appData document.
error PrivateTrade_AppDataMismatch(bytes32 makerAppData, bytes32 takerAppData);

/// @notice View of the settlement context a conditional order validates against.
interface IPrivateTradeWrapper {
  /// @notice Offer currently being settled, or `bytes32(0)` outside a private trade settlement.
  function activeOfferId() external view returns (bytes32);

  /// @notice Counterparty currently being settled, or `address(0)` outside a private trade settlement.
  function activeTaker() external view returns (address);
}
