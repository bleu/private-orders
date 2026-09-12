// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {console} from "forge-std/console.sol";
import {IERC20} from "cowprotocol/contracts/interfaces/IERC20.sol";
import {IConditionalOrder} from "composable-cow/interfaces/IConditionalOrder.sol";
import {ComposableCoW} from "composable-cow/ComposableCoW.sol";
import {COWShedFactory} from "cow-shed/COWShedFactory.sol";
import {COWShedForComposableCoW} from "cow-shed/COWShedForComposableCoW.sol";
import {Call} from "cow-shed/ICOWAuthHook.sol";
import {IComposableCow} from "cow-shed/IComposableCow.sol";

import {PrivateTradeTerms, PrivateTradeRole, PrivateTrade_NoActiveTrade} from "../src/interfaces/IPrivateTrade.sol";
import {PrivateTradeTestBase} from "./utils/PrivateTradeTestBase.sol";

/// @notice The real EOA path: two externally owned accounts own their orders through CoW Sheds.
///
/// @dev Everything here is the production contract set from `cowdao-grants/cow-shed` v2.1.0:
/// `COWShedFactory`, `COWShedProxy`, and `COWShedForComposableCoW` as the implementation. The owner
/// signs one `ExecuteHooks` bundle; anyone can relay it. The bundle does the two things that must
/// happen inside the Shed's own context: approve the vault relayer, and authorise the conditional
/// order with `ComposableCoW.create`.
contract PrivateTradeShedTest is PrivateTradeTestBase {
  bytes32 internal constant EIP712_DOMAIN_TYPE_HASH =
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
  bytes32 internal constant EXECUTE_HOOKS_TYPE_HASH = keccak256(
    "ExecuteHooks(Call[] calls,bytes32 nonce,uint256 deadline)Call(address target,uint256 value,bytes callData,bool allowFailure,bool isDelegateCall)"
  );
  bytes32 internal constant CALL_TYPE_HASH =
    keccak256("Call(address target,uint256 value,bytes callData,bool allowFailure,bool isDelegateCall)");
  bytes32 internal constant DOMAIN_NAME = keccak256("COWShed");
  bytes32 internal constant DOMAIN_VERSION = keccak256("2.1.0");

  COWShedFactory internal factory;
  COWShedForComposableCoW internal implementation;

  address internal aliceEoa;
  uint256 internal alicePk;
  address internal bobEoa;
  uint256 internal bobPk;

  address internal aliceShed;
  address internal bobShed;

  function setUp() public override {
    super.setUp();

    implementation = new COWShedForComposableCoW(IComposableCow(address(cow)));
    factory = new COWShedFactory(address(implementation));

    (aliceEoa, alicePk) = makeAddrAndKey("alice-eoa");
    (bobEoa, bobPk) = makeAddrAndKey("bob-eoa");

    aliceShed = factory.proxyOf(aliceEoa);
    bobShed = factory.proxyOf(bobEoa);
  }

  /// @dev The whole flow: two EOAs, two Sheds, one settlement. Tokens land in the Sheds, which
  /// their owners control.
  function test_settlesWithShedOwnedOrders() public {
    PrivateTradeTerms memory terms = _termsFull(aliceShed, bobShed, bobShed, aliceEoa, bobEoa);

    IConditionalOrder.ConditionalOrderParams memory makerParams = _params(PrivateTradeRole.Maker, terms, "maker");
    IConditionalOrder.ConditionalOrderParams memory takerParams = _params(PrivateTradeRole.Taker, terms, "taker");

    // The deterministic Shed addresses can be funded before the proxies even exist.
    usdc.mint(aliceShed, USDC_AMOUNT);
    wbtc.mint(bobShed, WBTC_AMOUNT);

    _relayBundle(aliceEoa, alicePk, aliceShed, _bundle(address(usdc), USDC_AMOUNT, makerParams));
    _relayBundle(bobEoa, bobPk, bobShed, _bundle(address(wbtc), WBTC_AMOUNT, takerParams));

    assertGt(aliceShed.code.length, 0, "shed not deployed");
    assertTrue(cow.singleOrders(aliceShed, cow.hash(makerParams)), "maker order not authorised");

    vm.prank(solver);
    wrapper.wrappedSettle(_settleData(terms, makerParams, takerParams), _chainedWrapperData(terms));

    assertEq(usdc.balanceOf(aliceShed), 0, "shed still holds USDC");
    assertEq(wbtc.balanceOf(bobShed), 0, "shed still holds WBTC");

    // The Shed owns the order, but the proceeds belong to the party: they are paid to the wallet
    // that controls the Shed, not to the Shed, so nobody has to withdraw them afterwards.
    assertEq(wbtc.balanceOf(aliceEoa), WBTC_AMOUNT, "alice's wallet did not receive WBTC");
    assertEq(usdc.balanceOf(bobEoa), USDC_AMOUNT, "bob's wallet did not receive USDC");
    assertEq(wbtc.balanceOf(aliceShed), 0, "alice's shed received the proceeds");
    assertEq(usdc.balanceOf(bobShed), 0, "bob's shed received the proceeds");
  }

  /// @dev The Shed has to authorise the order. With the approval in place but no `create` call,
  /// the signature path works and ComposableCoW itself refuses the order.
  function test_orderMustBeAuthorisedByTheShed() public {
    PrivateTradeTerms memory terms = _termsFull(aliceShed, bobShed, bobShed, aliceEoa, bobEoa);
    IConditionalOrder.ConditionalOrderParams memory makerParams = _params(PrivateTradeRole.Maker, terms, "maker");
    IConditionalOrder.ConditionalOrderParams memory takerParams = _params(PrivateTradeRole.Taker, terms, "taker");

    usdc.mint(aliceShed, USDC_AMOUNT);
    wbtc.mint(bobShed, WBTC_AMOUNT);

    // Alice's Shed exists and has approved the relayer, but she never authorised the order.
    _relayBundleWithNonce(
      aliceEoa, alicePk, aliceShed, _approveOnlyBundle(address(usdc), USDC_AMOUNT), keccak256("approve-only")
    );
    _relayBundle(bobEoa, bobPk, bobShed, _bundle(address(wbtc), WBTC_AMOUNT, takerParams));

    assertGt(aliceShed.code.length, 0, "alice shed should exist");
    assertFalse(cow.singleOrders(aliceShed, cow.hash(makerParams)), "order should not be authorised");

    bytes memory settleData = _settleData(terms, makerParams, takerParams);
    bytes memory chained = _chainedWrapperData(terms);

    vm.prank(solver);
    vm.expectRevert(ComposableCoW.SingleOrderNotAuthed.selector);
    wrapper.wrappedSettle(settleData, chained);
  }

  /// @dev The signed bundle is bound to the Shed address, so a relayer cannot replay Alice's
  /// bundle onto Bob's Shed.
  function test_bundleSignatureIsBoundToTheShed() public {
    PrivateTradeTerms memory terms = _termsFull(aliceShed, bobShed, bobShed, aliceEoa, bobEoa);
    IConditionalOrder.ConditionalOrderParams memory makerParams = _params(PrivateTradeRole.Maker, terms, "maker");

    Call[] memory calls = _bundle(address(usdc), USDC_AMOUNT, makerParams);
    bytes32 nonce = keccak256("alice-bundle");
    uint256 deadline = block.timestamp + 1 hours;

    // Sign against Alice's Shed, then try to execute it for Bob's Shed.
    bytes32 digest = _executeHooksDigest(aliceShed, calls, nonce, deadline);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);
    bytes memory signature = abi.encodePacked(r, s, v);

    vm.expectRevert();
    factory.executeHooks(calls, nonce, deadline, bobEoa, signature);
  }

  /// @dev The same nonce cannot be used twice.
  function test_bundleNonceCannotBeReplayed() public {
    PrivateTradeTerms memory terms = _termsFull(aliceShed, bobShed, bobShed, aliceEoa, bobEoa);
    IConditionalOrder.ConditionalOrderParams memory makerParams = _params(PrivateTradeRole.Maker, terms, "maker");

    usdc.mint(aliceShed, USDC_AMOUNT);
    Call[] memory calls = _bundle(address(usdc), USDC_AMOUNT, makerParams);
    bytes32 nonce = keccak256("replayed");

    _relayBundleWithNonce(aliceEoa, alicePk, aliceShed, calls, nonce);

    bytes32 digest = _executeHooksDigest(aliceShed, calls, nonce, block.timestamp + 1 hours);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

    vm.expectRevert();
    factory.executeHooks(calls, nonce, block.timestamp + 1 hours, aliceEoa, abi.encodePacked(r, s, v));
  }

  // --- bundles

  /// @dev Exactly the two calls a Shed must make for a private trade: approve, then authorise.
  function _bundle(address sellToken, uint256 sellAmount, IConditionalOrder.ConditionalOrderParams memory params)
    internal
    view
    returns (Call[] memory calls)
  {
    calls = new Call[](2);
    calls[0] = Call({
      target: sellToken,
      value: 0,
      callData: abi.encodeCall(IERC20.approve, (relayer, sellAmount)),
      allowFailure: false,
      isDelegateCall: false
    });
    calls[1] = Call({
      target: address(cow),
      value: 0,
      callData: abi.encodeCall(ComposableCoW.create, (params, false)),
      allowFailure: false,
      isDelegateCall: false
    });
  }

  /// @dev The funding half of a bundle, without authorising an order.
  function _approveOnlyBundle(address sellToken, uint256 sellAmount) internal view returns (Call[] memory calls) {
    calls = new Call[](1);
    calls[0] = Call({
      target: sellToken,
      value: 0,
      callData: abi.encodeCall(IERC20.approve, (relayer, sellAmount)),
      allowFailure: false,
      isDelegateCall: false
    });
  }

  function _relayBundle(address owner, uint256 pk, address shed, Call[] memory calls) internal {
    _relayBundleWithNonce(owner, pk, shed, calls, keccak256(abi.encode("bundle", owner)));
  }

  /// @dev Anyone can relay. The relayer only needs the owner's signature.
  function _relayBundleWithNonce(address owner, uint256 pk, address shed, Call[] memory calls, bytes32 nonce) internal {
    uint256 deadline = block.timestamp + 1 hours;
    bytes32 digest = _executeHooksDigest(shed, calls, nonce, deadline);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

    vm.prank(makeAddr("relayer"));
    factory.executeHooks(calls, nonce, deadline, owner, abi.encodePacked(r, s, v));
  }

  /// @dev Mirrors `LibAuthenticatedHooks.hashToSign`, including the single-byte `v` signature
  /// encoding.
  function _executeHooksDigest(address shed, Call[] memory calls, bytes32 nonce, uint256 deadline)
    internal
    view
    returns (bytes32)
  {
    bytes32 domainSeparator =
      keccak256(abi.encode(EIP712_DOMAIN_TYPE_HASH, DOMAIN_NAME, DOMAIN_VERSION, block.chainid, shed));

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

    bytes32 callsHash = keccak256(abi.encodePacked(callHashes));
    bytes32 structHash = keccak256(abi.encode(EXECUTE_HOOKS_TYPE_HASH, callsHash, nonce, deadline));

    return keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
  }
}
