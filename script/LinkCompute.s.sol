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

interface IShedImplementation {
  function VERSION() external view returns (string memory);
}

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
  bytes32 internal constant EIP712_DOMAIN_TYPE_HASH =
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
  bytes32 internal constant EXECUTE_HOOKS_TYPE_HASH = keccak256(
    "ExecuteHooks(Call[] calls,bytes32 nonce,uint256 deadline)Call(address target,uint256 value,bytes callData,bool allowFailure,bool isDelegateCall)"
  );
  bytes32 internal constant CALL_TYPE_HASH =
    keccak256("Call(address target,uint256 value,bytes callData,bool allowFailure,bool isDelegateCall)");

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
    json = string.concat(json, '","offerId":"');
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

    vm.writeFile("out-json/link-computed.json", json);
    console.log("offerId", vm.toString(PrivateTradeLib.offerId(terms.offer)));
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
    string memory label = isMaker ? "maker" : "taker";
    bytes32 nonce = keccak256(abi.encode(label, terms.offer.salt));
    uint256 deadline = block.timestamp + request.validFor;

    Call[] memory calls = new Call[](2);
    calls[0] = Call({
      target: sellToken,
      value: 0,
      callData: abi.encodeCall(IERC20.approve, (request.vaultRelayer, sellAmount)),
      allowFailure: false,
      isDelegateCall: false
    });
    calls[1] = Call({
      target: request.composableCoW,
      value: 0,
      callData: abi.encodeCall(ComposableCoW.create, (params, false)),
      allowFailure: false,
      isDelegateCall: false
    });

    json = '{"owner":"';
    json = string.concat(json, vm.toString(isMaker ? request.maker : request.allowedTaker));
    json = string.concat(json, '","shed":"', vm.toString(shed));
    json = string.concat(json, '","nonce":"', vm.toString(nonce));
    json = string.concat(json, '","deadline":', vm.toString(deadline));
    json = string.concat(json, ',"sellToken":"', vm.toString(sellToken));
    json = string.concat(json, '","sellAmount":"', vm.toString(sellAmount));
    json = string.concat(json, '","approveCall":"');
    json = string.concat(json, vm.toString(calls[0].callData));
    json = string.concat(json, '","createCall":"', vm.toString(calls[1].callData));
    json = string.concat(json, '","digest":"');
    json = string.concat(json, vm.toString(_digest(request, shed, calls, nonce, deadline)));
    json = string.concat(json, '"}');
  }

  function _digest(Request memory request, address shed, Call[] memory calls, bytes32 nonce, uint256 deadline)
    private
    view
    returns (bytes32)
  {
    bytes32 version =
      keccak256(bytes(IShedImplementation(COWShedFactory(request.shedFactory).implementation()).VERSION()));
    bytes32 domainSeparator =
      keccak256(abi.encode(EIP712_DOMAIN_TYPE_HASH, keccak256("COWShed"), version, block.chainid, shed));

    bytes32[] memory hashes = new bytes32[](calls.length);
    for (uint256 i = 0; i < calls.length; ++i) {
      hashes[i] = keccak256(
        abi.encode(
          CALL_TYPE_HASH,
          calls[i].target,
          calls[i].value,
          keccak256(calls[i].callData),
          calls[i].allowFailure,
          calls[i].isDelegateCall
        )
      );
    }
    bytes32 structHash =
      keccak256(abi.encode(EXECUTE_HOOKS_TYPE_HASH, keccak256(abi.encodePacked(hashes)), nonce, deadline));
    return keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
  }

  function _jitOrder(
    PrivateTradeTerms memory terms,
    bytes32 appData,
    IConditionalOrder.ConditionalOrderParams memory params
  ) private view returns (string memory json) {
    json = '{"sellToken":"';
    json = string.concat(json, vm.toString(terms.offer.sellToken));
    json = string.concat(json, '","buyToken":"', vm.toString(terms.offer.buyToken));
    json = string.concat(json, '","receiver":"', vm.toString(address(0)));
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
      taker: COWShedFactory(request.shedFactory).proxyOf(request.allowedTaker)
    });
  }

  function _request() private view returns (Request memory request) {
    string memory json = vm.readFile("out-json/link-request.json");
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
  }
}
