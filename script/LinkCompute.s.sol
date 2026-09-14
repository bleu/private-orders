// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Script, console} from "forge-std/Script.sol";

import {IERC20} from "cowprotocol/contracts/interfaces/IERC20.sol";
import {ComposableCoW} from "composable-cow/ComposableCoW.sol";
import {IConditionalOrder} from "composable-cow/interfaces/IConditionalOrder.sol";
import {COWShedFactory} from "cow-shed/COWShedFactory.sol";
import {Call} from "cow-shed/ICOWAuthHook.sol";

import {PrivateOffer, PrivateTradeTerms, PrivateTradeRole} from "../src/interfaces/IPrivateTrade.sol";
import {PrivateTradeAppData} from "../src/libraries/PrivateTradeAppData.sol";
import {PrivateTradeBuilder} from "../src/libraries/PrivateTradeBuilder.sol";
import {PrivateTradeLib} from "../src/libraries/PrivateTradeLib.sol";
import {ShedBundle} from "../src/libraries/ShedBundle.sol";
import {TokenPermit} from "../src/libraries/TokenPermit.sol";

/// @notice Derives everything a private trade link needs, from a request file, with no private key
/// and no transaction. The link service calls this instead of re-deriving the payload in its own
/// language: `PrivateTradeBuilder` stays the only implementation of the rules.
///
/// In:  `out-json/link-request.json`
/// Out: `out-json/link-computed.json`
///
/// The response carries, for each side, the Shed that owns the order, the two calls its signed hook
/// bundle executes, and the EIP-712 digest to sign. Signing the digest is the only secret a party
/// needs; everything else is public.
contract LinkCompute is Script {
  struct Request {
    address maker;
    address allowedTaker;
    address sellToken;
    uint256 sellAmount;
    address buyToken;
    uint256 buyAmount;
    uint256 validFor;
    address wrapper;
    address handler;
    address shedFactory;
    address composableCoW;
    address vaultRelayer;
    address authoriser;
    bool fund;
  }

  function run() external {
    Request memory request = _request();
    PrivateTradeTerms memory terms = _terms(request);

    (
      IConditionalOrder.ConditionalOrderParams memory makerParams,
      IConditionalOrder.ConditionalOrderParams memory takerParams
    ) = PrivateTradeBuilder.conditionalOrderParams(request.handler, terms);

    bytes32 appData = PrivateTradeBuilder.appDataHash(terms, request.wrapper);
    address makerShed = COWShedFactory(request.shedFactory).proxyOf(request.maker);

    string memory json = '{"wrapper":"';
    json = string.concat(json, vm.toString(request.wrapper));
    json = string.concat(json, '","fund":', request.fund ? "true" : "false");
    json = string.concat(json, ',"offerId":"');
    json = string.concat(json, vm.toString(PrivateTradeLib.offerId(terms.offer)));
    json = string.concat(json, '","appDataHash":"', vm.toString(appData));
    json = string.concat(json, '","appDataDocument":');
    json = string.concat(
      json,
      _jsonString(
        PrivateTradeAppData.document(request.wrapper, PrivateTradeBuilder.wrapperData(terms, request.wrapper))
      )
    );
    json = string.concat(json, ',"wrapperData":"');
    json = string.concat(json, vm.toString(PrivateTradeBuilder.wrapperData(terms, request.wrapper)));
    json = string.concat(json, '","maker":"', vm.toString(request.maker));
    json = string.concat(json, '","makerShed":"', vm.toString(makerShed));
    json = string.concat(json, '","taker":"', vm.toString(terms.taker));
    json = string.concat(json, '","sellToken":"', vm.toString(request.sellToken));
    json = string.concat(json, '","sellAmount":"', vm.toString(request.sellAmount));
    json = string.concat(json, '","buyToken":"', vm.toString(request.buyToken));
    json = string.concat(json, '","buyAmount":"', vm.toString(request.buyAmount));
    json = string.concat(json, '","validTo":', vm.toString(uint256(terms.offer.validTo)));
    json = string.concat(json, ',"makerBundle":');
    json = string.concat(json, _side(request, terms, makerParams, makerShed, true));
    json = string.concat(json, ',"makerCancellation":');
    json = string.concat(json, _cancellation(request, terms, makerParams, makerShed));
    json = string.concat(json, ',"takerBundle":');
    // The taker's Shed owns their order; the taker EOA only signs the bundle.
    json = string.concat(json, _side(request, terms, takerParams, terms.taker, false));
    json = string.concat(json, ',"makerJitOrder":');
    json = string.concat(json, _jitOrder(terms, appData, makerParams));
    json = string.concat(json, ',"takerOrder":');
    json = string.concat(json, _takerOrder(request, terms, appData, takerParams));
    json = string.concat(json, ',"prices":{"', vm.toString(request.sellToken));
    json = string.concat(json, '":"', vm.toString(PrivateTradeBuilder.clearingPrices(terms)[0]));
    json = string.concat(json, '","', vm.toString(request.buyToken));
    json = string.concat(json, '":"', vm.toString(PrivateTradeBuilder.clearingPrices(terms)[1]));
    json = string.concat(json, '"}}\n');

    vm.writeFile(vm.envOr("LINK_COMPUTED_FILE", string("out-json/link-computed.json")), json);
    console.log("offerId", vm.toString(PrivateTradeLib.offerId(terms.offer)));
  }

  function _cancellation(
    Request memory request,
    PrivateTradeTerms memory terms,
    IConditionalOrder.ConditionalOrderParams memory makerParams,
    address makerShed
  ) private view returns (string memory json) {
    bytes32 nonce = keccak256(abi.encode("cancel", terms.offer.salt));
    uint256 deadline = block.timestamp + request.validFor;
    Call[] memory calls = ShedBundle.cancellationCalls(request.composableCoW, makerParams, request.wrapper, terms.offer);

    json = string.concat('{"owner":"', vm.toString(request.maker));
    json = string.concat(json, '","shed":"', vm.toString(makerShed));
    json = string.concat(json, '","nonce":"', vm.toString(nonce));
    json = string.concat(json, '","deadline":', vm.toString(deadline));
    json = string.concat(json, _jsonCalls(calls));
    json = string.concat(
      json, ',"bundleTypedData":', ShedBundle.typedData(request.shedFactory, makerShed, calls, nonce, deadline)
    );
    json = string.concat(json, ',"digest":"');
    json = string.concat(json, vm.toString(_digest(request, makerShed, calls, nonce, deadline)), '"}');
  }

  /// @dev One party's signed hook bundle: the calls, and the digest to sign.
  function _side(
    Request memory request,
    PrivateTradeTerms memory terms,
    IConditionalOrder.ConditionalOrderParams memory params,
    address shed,
    bool isMaker
  ) private view returns (string memory json) {
    address sellToken = isMaker ? request.sellToken : request.buyToken;
    uint256 sellAmount = isMaker ? request.sellAmount : request.buyAmount;
    address owner = isMaker ? request.maker : request.allowedTaker;
    bytes32 nonce = keccak256(abi.encode(isMaker ? "maker" : "taker", terms.offer.salt));
    uint256 deadline = block.timestamp + request.validFor;
    Call[] memory calls = _calls(request, params, shed, owner, sellToken, sellAmount);

    json = '{"owner":"';
    json = string.concat(json, vm.toString(owner));
    json = string.concat(json, '","shed":"', vm.toString(shed));
    json = string.concat(json, '","nonce":"', vm.toString(nonce));
    json = string.concat(json, '","deadline":', vm.toString(deadline));
    json = string.concat(json, ',"sellToken":"', vm.toString(sellToken));
    json = string.concat(json, '","sellAmount":"', vm.toString(sellAmount));
    json = string.concat(json, '","funded":', request.fund ? "true" : "false");
    // The calls as data, including the flags. The relay rebuilds the bundle from this, so a call
    // whose flags it assumed would produce a digest that does not match the signature.
    json = string.concat(json, _jsonCalls(calls));
    json = string.concat(json, _permitJson(sellToken, owner, shed, sellAmount, deadline));
    // `permitNonce` is a number, so the next fragment opens with a comma rather than a closing quote.
    // The same message as typed data, so a wallet can show the calls instead of a bare digest.
    json = string.concat(
      json, ',"bundleTypedData":', ShedBundle.typedData(request.shedFactory, shed, calls, nonce, deadline)
    );
    json = string.concat(json, ',"digest":"');
    json = string.concat(json, vm.toString(_digest(request, shed, calls, nonce, deadline)));
    json = string.concat(json, '"}');
  }

  /// @dev Where the token supports permit, the party grants the Shed its allowance by signature
  /// instead of a transaction. The relay submits it, so the party pays nothing. `permitKind` is
  /// `"none"` for a token that has no permit, and the party falls back to an `approve` transaction.
  function _permitJson(address sellToken, address owner, address shed, uint256 sellAmount, uint256 deadline)
    private
    view
    returns (string memory json)
  {
    TokenPermit.Permit memory permit = TokenPermit.build(sellToken, owner, shed, sellAmount, deadline);
    // The calls end in an array, so this fragment opens with a comma, not a closing quote.
    json = string.concat(',"permitKind":"', _permitKind(permit.kind));
    json = string.concat(json, '","permitDigest":"', vm.toString(TokenPermit.digest(permit)));
    json = string.concat(json, '","permitNonce":', vm.toString(permit.nonce));
    // Typed data only when the token's domain fields provably reproduce its own DOMAIN_SEPARATOR,
    // so a wallet cannot be shown a digest the token would reject.
    // `permitNonce` is a number, so this fragment opens with a comma, not a closing quote.
    json =
      string.concat(json, ',"permitTypedDataAvailable":', TokenPermit.typedDataAvailable(permit) ? "true" : "false");
    if (TokenPermit.typedDataAvailable(permit)) {
      json = string.concat(json, ',"permitTypedData":', TokenPermit.typedData(permit));
    }
  }

  /// @dev Parallel arrays rather than an array of objects: `abi.decode` will not turn a JSON array of
  /// objects into a struct array, and the relay needs to read these back exactly.
  function _jsonCalls(Call[] memory calls) private view returns (string memory json) {
    json = ',"callTargets":[';
    for (uint256 i = 0; i < calls.length; ++i) {
      if (i > 0) json = string.concat(json, ",");
      json = string.concat(json, '"', vm.toString(calls[i].target), '"');
    }
    json = string.concat(json, '],"callDataHex":[');
    for (uint256 i = 0; i < calls.length; ++i) {
      if (i > 0) json = string.concat(json, ",");
      json = string.concat(json, '"', vm.toString(calls[i].callData), '"');
    }
    json = string.concat(json, '],"callAllowFailure":[');
    for (uint256 i = 0; i < calls.length; ++i) {
      if (i > 0) json = string.concat(json, ",");
      json = string.concat(json, calls[i].allowFailure ? "true" : "false");
    }
    json = string.concat(json, '],"callDelegateCall":[');
    for (uint256 i = 0; i < calls.length; ++i) {
      if (i > 0) json = string.concat(json, ",");
      json = string.concat(json, calls[i].isDelegateCall ? "true" : "false");
    }
    json = string.concat(json, "]");
  }

  function _permitKind(TokenPermit.Kind kind) private pure returns (string memory) {
    if (kind == TokenPermit.Kind.Eip2612) return "eip2612";
    if (kind == TokenPermit.Kind.DaiLike) return "dai";
    return "none";
  }

  /// @dev The calls one party's bundle executes: fund the Shed, let the vault relayer take the sell
  /// tokens at settlement, and authorise the order.
  function _calls(
    Request memory request,
    IConditionalOrder.ConditionalOrderParams memory params,
    address shed,
    address owner,
    address sellToken,
    uint256 sellAmount
  ) private view returns (Call[] memory calls) {
    calls = new Call[](request.fund ? 3 : 2);
    uint256 i = 0;
    if (request.fund) {
      // Funding rides inside the same signed bundle: a separate transfer would cost a second
      // transaction and leave a window where the order is authorised but unfunded. The Shed is the
      // spender, so the party approves the Shed on the token once, beforehand.
      calls[i++] = Call({
        target: sellToken,
        value: 0,
        callData: abi.encodeCall(IERC20.transferFrom, (owner, shed, sellAmount)),
        allowFailure: false,
        isDelegateCall: false
      });
    }
    calls[i++] = Call({
      target: sellToken,
      value: 0,
      callData: abi.encodeCall(IERC20.approve, (request.vaultRelayer, sellAmount)),
      allowFailure: false,
      isDelegateCall: false
    });
    // Through the authoriser, so the Shed refuses to create an order that pays anyone but its owner.
    calls[i] = ShedBundle.createCall(request.authoriser, request.composableCoW, params);
  }

  function _digest(Request memory request, address shed, Call[] memory calls, bytes32 nonce, uint256 deadline)
    private
    view
    returns (bytes32)
  {
    return ShedBundle.digest(request.shedFactory, shed, calls, nonce, deadline);
  }

  function _jitOrder(
    PrivateTradeTerms memory terms,
    bytes32 appData,
    IConditionalOrder.ConditionalOrderParams memory params
  ) private view returns (string memory json) {
    json = '{"sellToken":"';
    json = string.concat(json, vm.toString(terms.offer.sellToken));
    json = string.concat(json, '","buyToken":"', vm.toString(terms.offer.buyToken));
    // Taken from the order the library builds, not repeated here: a hand-written field is how this
    // one stayed at zero after the order started paying a beneficiary.
    json = string.concat(json, '","receiver":"', vm.toString(PrivateTradeLib.makerOrder(terms, appData).receiver));
    json = string.concat(json, '","sellAmount":"', vm.toString(terms.offer.sellAmount));
    json = string.concat(json, '","buyAmount":"', vm.toString(terms.offer.buyAmount));
    json = string.concat(json, '","partiallyFillable":false,"validTo":');
    json = string.concat(json, vm.toString(uint256(terms.offer.validTo)));
    json = string.concat(json, ',"appData":"', vm.toString(appData));
    json = string.concat(json, '","kind":"sell","sellTokenBalance":"erc20","buyTokenBalance":"erc20"');
    json = string.concat(json, ',"signingScheme":"eip1271","signature":"');
    json = string.concat(
      json,
      vm.toString(
        PrivateTradeBuilder.eip1271Signature(PrivateTradeLib.makerOrder(terms, appData), params, terms.offer.maker)
      )
    );
    json = string.concat(json, '"}');
  }

  function _takerOrder(
    Request memory request,
    PrivateTradeTerms memory terms,
    bytes32 appData,
    IConditionalOrder.ConditionalOrderParams memory params
  ) private view returns (string memory json) {
    json = '{"sellToken":"';
    json = string.concat(json, vm.toString(terms.offer.buyToken));
    json = string.concat(json, '","buyToken":"', vm.toString(terms.offer.sellToken));
    json = string.concat(json, '","receiver":"', vm.toString(PrivateTradeLib.takerOrder(terms, appData).receiver));
    json = string.concat(json, '","sellAmount":"', vm.toString(terms.offer.buyAmount));
    json = string.concat(json, '","buyAmount":"', vm.toString(terms.offer.sellAmount));
    json = string.concat(json, '","validTo":', vm.toString(uint256(terms.offer.validTo)));
    json = string.concat(
      json,
      ',"appData":',
      _jsonString(
        PrivateTradeAppData.document(request.wrapper, PrivateTradeBuilder.wrapperData(terms, request.wrapper))
      )
    );
    json = string.concat(json, ',"feeAmount":"0","kind":"sell","partiallyFillable":false');
    json = string.concat(json, ',"sellTokenBalance":"erc20","buyTokenBalance":"erc20"');
    json = string.concat(json, ',"signingScheme":"eip1271","signature":"');
    // Payload only: the driver prepends the owner when encoding the settlement.
    json = string.concat(
      json, vm.toString(PrivateTradeBuilder.eip1271Payload(PrivateTradeLib.takerOrder(terms, appData), params))
    );
    json = string.concat(json, '","from":"', vm.toString(terms.taker), '"}');
  }

  function _jsonString(bytes memory value) private pure returns (string memory out) {
    bytes memory buffer = new bytes(value.length * 2);
    uint256 length;
    for (uint256 i = 0; i < value.length; ++i) {
      if (value[i] == '"' || value[i] == "\\") buffer[length++] = "\\";
      buffer[length++] = value[i];
    }
    bytes memory trimmed = new bytes(length);
    for (uint256 i = 0; i < length; ++i) {
      trimmed[i] = buffer[i];
    }
    out = string.concat('"', string(trimmed), '"');
  }

  function _terms(Request memory request) private view returns (PrivateTradeTerms memory) {
    return PrivateTradeTerms({
      offer: PrivateOffer({
        maker: COWShedFactory(request.shedFactory).proxyOf(request.maker),
        allowedTaker: COWShedFactory(request.shedFactory).proxyOf(request.allowedTaker),
        sellToken: request.sellToken,
        sellAmount: request.sellAmount,
        buyToken: request.buyToken,
        buyAmount: request.buyAmount,
        validTo: uint32(block.timestamp + request.validFor),
        salt: keccak256(abi.encode("private-trade-link", request.maker, request.buyToken, block.timestamp))
      }),
      taker: COWShedFactory(request.shedFactory).proxyOf(request.allowedTaker),
      // Proceeds go to the parties' own wallets, not to the Sheds that hold the orders.
      makerBeneficiary: request.maker,
      takerBeneficiary: request.allowedTaker
    });
  }

  function _request() private view returns (Request memory request) {
    string memory json = vm.readFile(vm.envOr("LINK_REQUEST_FILE", string("out-json/link-request.json")));
    request.maker = vm.parseJsonAddress(json, ".maker");
    request.allowedTaker = vm.parseJsonAddress(json, ".taker");
    request.sellToken = vm.parseJsonAddress(json, ".sellToken");
    request.sellAmount = vm.parseJsonUint(json, ".sellAmount");
    request.buyToken = vm.parseJsonAddress(json, ".buyToken");
    request.buyAmount = vm.parseJsonUint(json, ".buyAmount");
    request.validFor = vm.parseJsonUint(json, ".validFor");
    request.wrapper = vm.parseJsonAddress(json, ".wrapper");
    request.handler = vm.parseJsonAddress(json, ".handler");
    request.shedFactory = vm.parseJsonAddress(json, ".shedFactory");
    request.composableCoW = vm.parseJsonAddress(json, ".composableCoW");
    request.vaultRelayer = vm.parseJsonAddress(json, ".vaultRelayer");
    request.authoriser = vm.parseJsonAddress(json, ".authoriser");
    // Fund the Shed inside the signed bundle by default; `.fund = false` asks for authorisation
    // only, for a party who would rather move the tokens themselves.
    request.fund = !vm.keyExistsJson(json, ".fund") || vm.parseJsonBool(json, ".fund");
  }
}
