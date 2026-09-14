// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {GPv2Order} from "cowprotocol/contracts/libraries/GPv2Order.sol";
import {GPv2Signing} from "cowprotocol/contracts/mixins/GPv2Signing.sol";
import {IERC20} from "cowprotocol/contracts/interfaces/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PrivateOffer, PrivateTradeTerms, PrivateTradeRole} from "../interfaces/IPrivateTrade.sol";

/// @title PrivateTradeLib
/// @notice Derives the two orders a private trade implies, and checks them against what a settlement claims.
library PrivateTradeLib {
  /// @dev EIP-712 style type hash. `offerId` is a commitment to the maker's terms only, so the
  /// maker order never has to reference the taker order's hash (which would be a cycle).
  bytes32 internal constant OFFER_TYPE_HASH = keccak256(
    "PrivateOffer(address maker,address allowedTaker,address sellToken,uint256 sellAmount,address buyToken,uint256 buyAmount,uint32 validTo,bytes32 salt)"
  );

  /// @notice The identifier of an offer: a commitment to its terms.
  function offerId(PrivateOffer memory offer) internal pure returns (bytes32) {
    return keccak256(
      abi.encode(
        OFFER_TYPE_HASH,
        offer.maker,
        offer.allowedTaker,
        offer.sellToken,
        offer.sellAmount,
        offer.buyToken,
        offer.buyAmount,
        offer.validTo,
        offer.salt
      )
    );
  }

  /// @notice The order the maker must have authorised for these terms.
  function makerOrder(PrivateTradeTerms memory terms, bytes32 appData) internal pure returns (GPv2Order.Data memory) {
    PrivateOffer memory offer = terms.offer;
    return GPv2Order.Data({
      sellToken: IERC20(offer.sellToken),
      buyToken: IERC20(offer.buyToken),
      // The Shed owns the order; the party receives the proceeds.
      receiver: terms.makerBeneficiary,
      sellAmount: offer.sellAmount,
      buyAmount: offer.buyAmount,
      validTo: offer.validTo,
      appData: appData,
      feeAmount: 0,
      kind: GPv2Order.KIND_SELL,
      partiallyFillable: false,
      sellTokenBalance: GPv2Order.BALANCE_ERC20,
      buyTokenBalance: GPv2Order.BALANCE_ERC20
    });
  }

  /// @notice The order the taker must have authorised for these terms: the mirror of the offer.
  function takerOrder(PrivateTradeTerms memory terms, bytes32 appData) internal pure returns (GPv2Order.Data memory) {
    PrivateOffer memory offer = terms.offer;
    return GPv2Order.Data({
      sellToken: IERC20(offer.buyToken),
      buyToken: IERC20(offer.sellToken),
      receiver: terms.takerBeneficiary,
      sellAmount: offer.buyAmount,
      buyAmount: offer.sellAmount,
      validTo: offer.validTo,
      appData: appData,
      feeAmount: 0,
      kind: GPv2Order.KIND_SELL,
      partiallyFillable: false,
      sellTokenBalance: GPv2Order.BALANCE_ERC20,
      buyTokenBalance: GPv2Order.BALANCE_ERC20
    });
  }

  /// @notice Field-by-field equality of two orders.
  function equal(GPv2Order.Data memory a, GPv2Order.Data memory b) internal pure returns (bool) {
    return address(a.sellToken) == address(b.sellToken) && address(a.buyToken) == address(b.buyToken)
      && a.receiver == b.receiver && a.sellAmount == b.sellAmount && a.buyAmount == b.buyAmount
      && a.validTo == b.validTo && a.appData == b.appData && a.feeAmount == b.feeAmount && a.kind == b.kind
      && a.partiallyFillable == b.partiallyFillable && a.sellTokenBalance == b.sellTokenBalance
      && a.buyTokenBalance == b.buyTokenBalance;
  }

  /// @notice Exact reciprocity at the declared clearing prices.
  /// @dev Reuses the settlement's own equation: for a sell order,
  /// `executedBuy = ceilDiv(sellAmount * sellPrice, buyPrice)`. Both legs must land exactly on the
  /// agreed amounts, so neither side can be filled at a better price that leaves the other short.
  function isReciprocal(PrivateTradeTerms memory terms, uint256 makerSellPrice, uint256 makerBuyPrice)
    internal
    pure
    returns (bool)
  {
    return isReciprocal(terms, makerSellPrice, makerBuyPrice, makerBuyPrice, makerSellPrice);
  }

  /// @notice Exact reciprocity using each trade's own clearing-price indices.
  function isReciprocal(
    PrivateTradeTerms memory terms,
    uint256 makerSellPrice,
    uint256 makerBuyPrice,
    uint256 takerSellPrice,
    uint256 takerBuyPrice
  ) internal pure returns (bool) {
    if (makerSellPrice == 0 || makerBuyPrice == 0) return false;
    if (takerSellPrice == 0 || takerBuyPrice == 0) return false;

    uint256 makerSellAmount = terms.offer.sellAmount;
    uint256 makerBuyAmount = terms.offer.buyAmount;

    uint256 takerSellAmount = makerBuyAmount;
    uint256 takerBuyAmount = makerSellAmount;

    uint256 makerExecutedBuy = Math.mulDiv(makerSellAmount, makerSellPrice, makerBuyPrice, Math.Rounding.Up);
    uint256 takerExecutedBuy = Math.mulDiv(takerSellAmount, takerSellPrice, takerBuyPrice, Math.Rounding.Up);

    return makerExecutedBuy == makerBuyAmount && takerExecutedBuy == takerBuyAmount;
  }

  /// @notice The scheme a trade must use. Always EIP-1271: both parties are contract accounts so
  /// that their order validity can depend on the settlement that contains them.
  function scheme() internal pure returns (GPv2Signing.Scheme) {
    return GPv2Signing.Scheme.Eip1271;
  }
}
