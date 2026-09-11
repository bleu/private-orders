// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {GPv2Order} from "cowprotocol/contracts/libraries/GPv2Order.sol";
import {GPv2Trade} from "cowprotocol/contracts/libraries/GPv2Trade.sol";
import {GPv2Interaction} from "cowprotocol/contracts/libraries/GPv2Interaction.sol";
import {GPv2Signing} from "cowprotocol/contracts/mixins/GPv2Signing.sol";
import {IERC20} from "cowprotocol/contracts/interfaces/IERC20.sol";
import {GPv2Settlement} from "cowprotocol/contracts/GPv2Settlement.sol";

import {ComposableCoW} from "composable-cow/ComposableCoW.sol";
import {IConditionalOrder} from "composable-cow/interfaces/IConditionalOrder.sol";

import {PrivateOffer, PrivateTradeTerms, PrivateTradeRole} from "../interfaces/IPrivateTrade.sol";
import {PrivateTradeLib} from "./PrivateTradeLib.sol";
import {PrivateTradeAppData} from "./PrivateTradeAppData.sol";
import {GPv2TradeEncoder} from "../vendor/GPv2TradeEncoder.sol";

/// @title PrivateTradeBuilder
/// @notice Builds the exact payload a private trade submitter sends on-chain.
///
/// @dev This is the whole coordination surface. Given the two parties' terms and the handler that
/// will authorise their orders, it derives both orders, both EIP-1271 signatures, the settlement
/// calldata and the bundle chain. Nothing here needs a private key: order authorisation comes from
/// the Shed-owned conditional orders, not from an ECDSA signature.
///
/// A submitter therefore cannot forge a trade. It can only assemble the pair the parties agreed to,
/// and the wrapper plus the order handlers reject anything else on-chain.
library PrivateTradeBuilder {
  /// @notice Both conditional orders for a pair.
  /// @param maker `abi.encode(PrivateTradeRole.Maker, terms)`
  /// @param taker `abi.encode(PrivateTradeRole.Taker, terms)`
  function conditionalOrderParams(address handler, PrivateTradeTerms memory terms)
    internal
    pure
    returns (
      IConditionalOrder.ConditionalOrderParams memory maker,
      IConditionalOrder.ConditionalOrderParams memory taker
    )
  {
    maker = IConditionalOrder.ConditionalOrderParams({
      handler: IConditionalOrder(handler),
      salt: keccak256(abi.encode("private-trade-maker", terms.offer.salt)),
      staticInput: abi.encode(PrivateTradeRole.Maker, terms)
    });
    taker = IConditionalOrder.ConditionalOrderParams({
      handler: IConditionalOrder(handler),
      salt: keccak256(abi.encode("private-trade-taker", terms.offer.salt)),
      staticInput: abi.encode(PrivateTradeRole.Taker, terms)
    });
  }

  /// @notice The settlement's token list: `[makerSellToken, makerBuyToken]`.
  function tokens(PrivateTradeTerms memory terms) internal pure returns (IERC20[] memory result) {
    result = new IERC20[](2);
    result[0] = IERC20(terms.offer.sellToken);
    result[1] = IERC20(terms.offer.buyToken);
  }

  /// @notice Clearing prices that make the two legs exact mirrors.
  /// @dev `price0 / price1 == buyAmount / sellAmount`, so the settlement's own
  /// `executedBuy = ceilDiv(sellAmount * sellPrice, buyPrice)` lands exactly on both agreed
  /// amounts. Chosen as `[buyAmount, sellAmount]`: exact, and no rounding anywhere.
  function clearingPrices(PrivateTradeTerms memory terms) internal pure returns (uint256[] memory prices) {
    prices = new uint256[](2);
    prices[0] = terms.offer.buyAmount;
    prices[1] = terms.offer.sellAmount;
  }

  /// @notice The EIP-1271 signature a Shed-owned order carries.
  /// @dev `abi.encodePacked(owner, abi.encode(order, payload))`. The owner prefix is what
  /// `GPv2Signing.recoverEip1271Signer` reads; the rest is what the Shed forwards to
  /// ComposableCoW. No secret is involved.
  function eip1271Signature(
    GPv2Order.Data memory order,
    IConditionalOrder.ConditionalOrderParams memory params,
    address owner
  ) internal pure returns (bytes memory) {
    ComposableCoW.PayloadStruct memory payload =
      ComposableCoW.PayloadStruct({proof: new bytes32[](0), params: params, offchainInput: ""});
    return abi.encodePacked(owner, abi.encode(order, payload));
  }

  /// @notice The two trades, in the order the wrapper requires: `[maker, taker]`.
  function trades(
    PrivateTradeTerms memory terms,
    IConditionalOrder.ConditionalOrderParams memory makerParams,
    IConditionalOrder.ConditionalOrderParams memory takerParams,
    bytes32 appData
  ) internal pure returns (GPv2Trade.Data[] memory result) {
    result = new GPv2Trade.Data[](2);
    result[0] = _trade(PrivateTradeLib.makerOrder(terms, appData), makerParams, terms.offer.maker, 0, 1, appData);
    result[1] = _trade(PrivateTradeLib.takerOrder(terms, appData), takerParams, terms.taker, 1, 0, appData);
  }

  /// @notice Calldata for `GPv2Settlement.settle`, with no interactions.
  function settleData(
    GPv2Settlement settlement,
    PrivateTradeTerms memory terms,
    IConditionalOrder.ConditionalOrderParams memory makerParams,
    IConditionalOrder.ConditionalOrderParams memory takerParams,
    bytes32 appData
  ) internal pure returns (bytes memory) {
    return abi.encodeCall(
      settlement.settle,
      (tokens(terms), clearingPrices(terms), trades(terms, makerParams, takerParams, appData), emptyInteractions())
    );
  }

  /// @notice The bundle chain for a single-wrapper private trade: `[uint16 len][data]`.
  /// @dev The wrapper must be the last bundle in the chain, so no next-wrapper address follows.
  function chainedWrapperData(PrivateTradeTerms memory terms, address wrapper) internal pure returns (bytes memory) {
    bytes memory data = wrapperData(terms, wrapper);
    return abi.encodePacked(uint16(data.length), data);
  }

  /// @notice The `wrappers[].data` bytes carried in the order's appData.
  function wrapperData(PrivateTradeTerms memory terms, address wrapper) internal pure returns (bytes memory) {
    return PrivateTradeAppData.wrapperData(PrivateTradeLib.offerId(terms.offer), terms);
  }

  /// @notice The appData hash both orders must carry.
  function appDataHash(PrivateTradeTerms memory terms, address wrapper) internal pure returns (bytes32) {
    return PrivateTradeAppData.documentHash(wrapper, wrapperData(terms, wrapper));
  }

  function emptyInteractions() internal pure returns (GPv2Interaction.Data[][3] memory result) {
    result = [new GPv2Interaction.Data[](0), new GPv2Interaction.Data[](0), new GPv2Interaction.Data[](0)];
  }

  // --- internals

  function _trade(
    GPv2Order.Data memory order,
    IConditionalOrder.ConditionalOrderParams memory params,
    address owner,
    uint256 sellTokenIndex,
    uint256 buyTokenIndex,
    bytes32 appData
  ) private pure returns (GPv2Trade.Data memory) {
    return GPv2Trade.Data({
      sellTokenIndex: sellTokenIndex,
      buyTokenIndex: buyTokenIndex,
      receiver: order.receiver,
      sellAmount: order.sellAmount,
      buyAmount: order.buyAmount,
      validTo: order.validTo,
      appData: appData,
      feeAmount: order.feeAmount,
      flags: GPv2TradeEncoder.encodeFlags(order, GPv2Signing.Scheme.Eip1271),
      executedAmount: order.sellAmount,
      signature: eip1271Signature(order, params, owner)
    });
  }
}
