// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Script, console} from "forge-std/Script.sol";

import {IERC20} from "cowprotocol/contracts/interfaces/IERC20.sol";
import {ComposableCoW} from "composable-cow/ComposableCoW.sol";
import {IConditionalOrder} from "composable-cow/interfaces/IConditionalOrder.sol";
import {COWShedFactory} from "cow-shed/COWShedFactory.sol";
import {Call} from "cow-shed/ICOWAuthHook.sol";

import {PrivateOffer, PrivateTradeTerms, PrivateTradeRole} from "../src/interfaces/IPrivateTrade.sol";
import {PrivateTradeBuilder} from "../src/libraries/PrivateTradeBuilder.sol";
import {ShedBundle} from "../src/libraries/ShedBundle.sol";
import {PrivateTradeAuthoriser} from "../src/PrivateTradeAuthoriser.sol";
import {PrivateTradeLib} from "../src/libraries/PrivateTradeLib.sol";
import {PrivateTradeAppData} from "../src/libraries/PrivateTradeAppData.sol";
import {PrivateTradeWrapper} from "../src/PrivateTradeWrapper.sol";

interface IMintable {
  function mint(address to, uint256 amount) external;
}

interface IShedImplementation {
  function VERSION() external view returns (string memory);
}

/// @notice Prepares both halves of a private trade on a running chain and writes the two payloads
/// the rest of the flow consumes:
///
/// - `out-json/private-trade-offer.json` — the *private* half. The maker's terms and its JIT order,
///   read only by the sub-solver. This is what never reaches the orderbook.
/// - `out-json/private-trade-order.json` — the *public* half. The taker's order, ready to POST to
///   the orderbook, with the appData document inline.
///
/// It funds both Sheds, relays both owner-signed hook bundles (approve + authorise), and derives
/// everything else with `PrivateTradeBuilder`. No private key signs an order: the orders are valid
/// through the Shed-owned conditional orders and the wrapper's published terms.
contract PreparePrivateTrade is Script {
  bytes32 internal constant EIP712_DOMAIN_TYPE_HASH =
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
  bytes32 internal constant EXECUTE_HOOKS_TYPE_HASH = keccak256(
    "ExecuteHooks(Call[] calls,bytes32 nonce,uint256 deadline)Call(address target,uint256 value,bytes callData,bool allowFailure,bool isDelegateCall)"
  );
  bytes32 internal constant CALL_TYPE_HASH =
    keccak256("Call(address target,uint256 value,bytes callData,bool allowFailure,bool isDelegateCall)");

  /// @dev Everything the script reads from the environment, in one place, to keep the stack shallow.
  struct Config {
    address wrapper;
    address handler;
    address shedFactory;
    address composableCoW;
    address usdc;
    address dai;
    uint256 usdcAmount;
    uint256 daiAmount;
    uint256 validFor;
    address authoriser;
    address makerEoa;
    address takerEoa;
    address makerShed;
    address takerShed;
    uint256 deployerPrivateKey;
    uint256 makerPrivateKey;
    uint256 takerPrivateKey;
  }

  function run() external {
    Config memory c = _config();

    PrivateTradeTerms memory terms = PrivateTradeTerms({
      offer: PrivateOffer({
        maker: c.makerShed,
        allowedTaker: c.takerShed,
        sellToken: c.usdc,
        sellAmount: c.usdcAmount,
        buyToken: c.dai,
        buyAmount: c.daiAmount,
        validTo: uint32(block.timestamp + c.validFor),
        salt: keccak256(abi.encode("private-trade-offline", c.makerShed, c.takerShed, block.timestamp))
      }),
      taker: c.takerShed,
      makerBeneficiary: c.makerEoa,
      takerBeneficiary: c.takerEoa
    });

    (
      IConditionalOrder.ConditionalOrderParams memory makerParams,
      IConditionalOrder.ConditionalOrderParams memory takerParams
    ) = PrivateTradeBuilder.conditionalOrderParams(c.handler, terms);

    bytes32 appData = PrivateTradeBuilder.appDataHash(terms, c.wrapper);

    vm.startBroadcast(c.deployerPrivateKey);
    IMintable(c.usdc).mint(c.makerShed, c.usdcAmount);
    IMintable(c.dai).mint(c.takerShed, c.daiAmount);
    _relay(
      shedFactoryOf(c),
      c,
      RelayArgs({
        owner: c.makerEoa,
        ownerPrivateKey: c.makerPrivateKey,
        shed: c.makerShed,
        sellToken: c.usdc,
        sellAmount: c.usdcAmount,
        params: makerParams,
        salt: terms.offer.salt,
        label: "maker"
      })
    );
    _relay(
      shedFactoryOf(c),
      c,
      RelayArgs({
        owner: c.takerEoa,
        ownerPrivateKey: c.takerPrivateKey,
        shed: c.takerShed,
        sellToken: c.dai,
        sellAmount: c.daiAmount,
        params: takerParams,
        salt: terms.offer.salt,
        label: "taker"
      })
    );
    vm.stopBroadcast();

    require(PrivateTradeWrapper(c.wrapper).activeOfferId() == bytes32(0), "unexpected active offer");

    _writeOffer(c, terms, appData, makerParams);
    _writeTakerOrder(c, terms, appData, takerParams);

    console.log("maker shed", c.makerShed);
    console.log("taker shed", c.takerShed);
    console.logBytes32(appData);
  }

  function _config() private view returns (Config memory c) {
    c.deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    c.makerPrivateKey = vm.envUint("MAKER_PRIVATE_KEY");
    c.takerPrivateKey = vm.envUint("TAKER_PRIVATE_KEY");
    c.authoriser = vm.envAddress("PRIVATE_TRADE_AUTHORISER");
    c.wrapper = vm.envAddress("PRIVATE_TRADE_WRAPPER");
    c.handler = vm.envAddress("PRIVATE_TRADE_HANDLER");
    c.shedFactory = vm.envAddress("COWSHED_COMPOSABLE_COW_FACTORY_ADDRESS");
    c.composableCoW = vm.envAddress("COMPOSABLE_COW_ADDRESS");
    c.usdc = vm.envAddress("USDC_ADDRESS");
    c.dai = vm.envAddress("DAI_ADDRESS");
    c.usdcAmount = vm.envUint("PRIVATE_TRADE_USDC_AMOUNT");
    c.daiAmount = vm.envUint("PRIVATE_TRADE_DAI_AMOUNT");
    c.validFor = vm.envUint("PRIVATE_TRADE_VALID_FOR");
    c.makerEoa = vm.addr(c.makerPrivateKey);
    c.takerEoa = vm.addr(c.takerPrivateKey);
    c.makerShed = COWShedFactory(c.shedFactory).proxyOf(c.makerEoa);
    c.takerShed = COWShedFactory(c.shedFactory).proxyOf(c.takerEoa);
  }

  function shedFactoryOf(Config memory c) private pure returns (COWShedFactory) {
    return COWShedFactory(c.shedFactory);
  }

  /// @dev Bundled into a struct: this many locals in one frame compiles to stack-too-deep.
  struct RelayArgs {
    address owner;
    uint256 ownerPrivateKey;
    address shed;
    address sellToken;
    uint256 sellAmount;
    IConditionalOrder.ConditionalOrderParams params;
    bytes32 salt;
    string label;
  }

  function _relay(COWShedFactory shedFactory, Config memory c, RelayArgs memory a) private {
    Call[] memory calls = new Call[](2);
    calls[0] = Call({
      target: a.sellToken,
      value: 0,
      callData: abi.encodeCall(IERC20.approve, (vm.envAddress("VAULT_RELAYER_ADDRESS"), a.sellAmount)),
      allowFailure: false,
      isDelegateCall: false
    });
    // Through the authoriser: an order that pays anyone but the party must not be creatable.
    calls[1] = ShedBundle.createCall(c.authoriser, c.composableCoW, a.params);

    // Unique per run: the offer salt is fresh each time, so re-running does not collide with
    // an already-consumed nonce.
    bytes32 nonce = keccak256(abi.encode("private-trade-offline", a.label, a.owner, a.salt));
    uint256 deadline = block.timestamp + 1 hours;

    shedFactory.executeHooks(calls, nonce, deadline, a.owner, _sign(shedFactory, a, calls, nonce, deadline));
  }

  // --- payloads

  /// @dev The half that stays private: the terms, the bundle data, and the maker's JIT order.
  function _writeOffer(
    Config memory c,
    PrivateTradeTerms memory terms,
    bytes32 appData,
    IConditionalOrder.ConditionalOrderParams memory makerParams
  ) private {
    bytes memory bundleData = PrivateTradeBuilder.wrapperData(terms, c.wrapper);
    uint256[] memory prices = PrivateTradeBuilder.clearingPrices(terms);

    string memory json = '{"wrapper":"';
    json = string.concat(json, vm.toString(c.wrapper));
    json = string.concat(json, '","appDataHash":"', vm.toString(appData));
    json = string.concat(json, '","taker":"', vm.toString(terms.taker));
    json = string.concat(json, '","sellToken":"', vm.toString(terms.offer.sellToken));
    json = string.concat(json, '","buyToken":"', vm.toString(terms.offer.buyToken));
    json = string.concat(json, '","sellAmount":"', vm.toString(c.usdcAmount));
    json = string.concat(json, '","buyAmount":"', vm.toString(c.daiAmount));
    json = string.concat(json, '","prices":{"', vm.toString(terms.offer.sellToken));
    json = string.concat(json, '":"', vm.toString(prices[0]));
    json = string.concat(json, '","', vm.toString(terms.offer.buyToken));
    json = string.concat(json, '":"', vm.toString(prices[1]), '"},');
    json = string.concat(json, '"wrapperData":"', vm.toString(bundleData));
    json = string.concat(json, '","makerJitOrder":');
    json = string.concat(json, _jitOrder(terms, appData, makerParams));
    json = string.concat(json, "}\n");

    vm.writeFile("out-json/private-trade-offer.json", json);
  }

  /// @dev The `JitOrder` shape from the solver DTO.
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

  /// @dev The half that is posted: the taker's mirror order, with the appData document inline so
  /// the orderbook and the driver see the bundle without a separate registration step.
  function _writeTakerOrder(
    Config memory c,
    PrivateTradeTerms memory terms,
    bytes32 appData,
    IConditionalOrder.ConditionalOrderParams memory takerParams
  ) private {
    string memory document = string(
      PrivateTradeAppData.document(c.wrapper, PrivateTradeBuilder.wrapperData(terms, c.wrapper))
    );

    string memory json = '{"sellToken":"';
    json = string.concat(json, vm.toString(terms.offer.buyToken));
    json = string.concat(json, '","buyToken":"', vm.toString(terms.offer.sellToken));
    json = string.concat(json, '","sellAmount":"', vm.toString(terms.offer.buyAmount));
    json = string.concat(json, '","buyAmount":"', vm.toString(terms.offer.sellAmount));
    json = string.concat(json, '","validTo":', vm.toString(uint256(terms.offer.validTo)));
    json = string.concat(json, ',"appData":', _jsonString(bytes(document)));
    json = string.concat(json, ',"feeAmount":"0","kind":"sell","partiallyFillable":false');
    json = string.concat(json, ',"sellTokenBalance":"erc20","buyTokenBalance":"erc20"');
    json = string.concat(json, ',"signingScheme":"eip1271","signature":"');
    // Payload only: the driver prepends the owner when it encodes the settlement.
    json = string.concat(
      json, vm.toString(PrivateTradeBuilder.eip1271Payload(PrivateTradeLib.takerOrder(terms, appData), takerParams))
    );
    json = string.concat(json, '","from":"', vm.toString(terms.taker), '"}\n');

    vm.writeFile("out-json/private-trade-order.json", json);
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

  // --- bundles

  function _bundle(
    address sellToken,
    uint256 sellAmount,
    IConditionalOrder.ConditionalOrderParams memory params,
    address composableCoW
  ) private view returns (Call[] memory calls) {
    address authoriser = vm.envAddress("PRIVATE_TRADE_AUTHORISER");
    calls = new Call[](2);
    calls[0] = Call({
      target: sellToken,
      value: 0,
      callData: abi.encodeCall(IERC20.approve, (GPv2VaultRelayerAddress(), sellAmount)),
      allowFailure: false,
      isDelegateCall: false
    });
    calls[1] = Call({
      target: authoriser,
      value: 0,
      callData: abi.encodeCall(PrivateTradeAuthoriser.createChecked, (ComposableCoW(composableCoW), params)),
      allowFailure: false,
      isDelegateCall: true
    });
  }

  function GPv2VaultRelayerAddress() private view returns (address) {
    return vm.envAddress("VAULT_RELAYER_ADDRESS");
  }

  function _relay(
    COWShedFactory shedFactory,
    address owner,
    uint256 ownerPrivateKey,
    address shed,
    Call[] memory calls,
    string memory label
  ) private {
    bytes32 nonce = keccak256(abi.encode("private-trade-offline", label, owner));
    uint256 deadline = block.timestamp + 1 hours;
    bytes32 digest = _executeHooksDigest(shedFactory, shed, calls, nonce, deadline);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

    shedFactory.executeHooks(calls, nonce, deadline, owner, abi.encodePacked(r, s, v));
  }

  function _sign(COWShedFactory shedFactory, RelayArgs memory a, Call[] memory calls, bytes32 nonce, uint256 deadline)
    private
    view
    returns (bytes memory)
  {
    bytes32 digest = _executeHooksDigest(shedFactory, a.shed, calls, nonce, deadline);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(a.ownerPrivateKey, digest);
    return abi.encodePacked(r, s, v);
  }

  function _executeHooksDigest(
    COWShedFactory shedFactory,
    address shed,
    Call[] memory calls,
    bytes32 nonce,
    uint256 deadline
  ) private view returns (bytes32) {
    // The domain version lives in the deployed implementation and has changed between releases.
    bytes32 version = keccak256(bytes(IShedImplementation(shedFactory.implementation()).VERSION()));
    bytes32 domainSeparator =
      keccak256(abi.encode(EIP712_DOMAIN_TYPE_HASH, keccak256("COWShed"), version, block.chainid, shed));

    bytes32[] memory callHashes = new bytes32[](calls.length);
    for (uint256 i = 0; i < calls.length; ++i) {
      callHashes[i] = keccak256(
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
      keccak256(abi.encode(EXECUTE_HOOKS_TYPE_HASH, keccak256(abi.encodePacked(callHashes)), nonce, deadline));
    return keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
  }
}
