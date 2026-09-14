// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IERC20} from "cowprotocol/contracts/interfaces/IERC20.sol";
import {IConditionalOrder} from "composable-cow/interfaces/IConditionalOrder.sol";
import {COWShed} from "cow-shed/COWShed.sol";
import {COWShedFactory} from "cow-shed/COWShedFactory.sol";
import {COWShedForComposableCoW} from "cow-shed/COWShedForComposableCoW.sol";
import {Call} from "cow-shed/ICOWAuthHook.sol";
import {IComposableCow} from "cow-shed/IComposableCow.sol";

import {Safe} from "safe/Safe.sol";
import {SafeProxy} from "safe/proxies/SafeProxy.sol";
import {SafeProxyFactory} from "safe/proxies/SafeProxyFactory.sol";
import {ExtensibleFallbackHandler} from "safe/handler/ExtensibleFallbackHandler.sol";
import {EIP712} from "safe/handler/extensible/SignatureVerifierMuxer.sol";

import {GPv2Trade} from "cowprotocol/contracts/libraries/GPv2Trade.sol";

import {
  PrivateTradeTerms,
  PrivateTradeRole,
  PrivateTradeOrderAuthorised,
  PrivateTrade_NotOfferMaker,
  PrivateTrade_TakerNotAllowed,
  PrivateTrade_BadSettlementShape
} from "../src/interfaces/IPrivateTrade.sol";
import {PrivateTradeAuthoriser} from "../src/PrivateTradeAuthoriser.sol";
import {PrivateTradeLib} from "../src/libraries/PrivateTradeLib.sol";
import {ShedBundle} from "../src/libraries/ShedBundle.sol";
import {PrivateTradeTestBase} from "./utils/PrivateTradeTestBase.sol";

/// @notice The same trade, for both kinds of Shed owner: an externally owned account, and a Safe.
///
/// @dev A Shed's `ADMIN` is whatever address the factory was asked to deploy for, and
/// `LibAuthenticatedHooks.authenticateHooks` branches on it: an owner without code is verified by
/// recovering its signature, an owner with code is asked over ERC-1271. So a Safe owns a Shed
/// exactly the way an EOA does, and the orders stay Shed-owned: `ComposableCoW.isValidSafeSignature`
/// is reached with the Shed as the owner either way.
///
/// Two things a Safe owner needs that an EOA does not:
///
/// 1. **A fallback handler that implements ERC-1271.** `FallbackManager.fallback` returns nothing
///    when none is set (`lib/composable-cow/lib/safe/contracts/base/FallbackManager.sol:69-71`), so
///    the Shed's query reads as an invalid signature. `ExtensibleFallbackHandler` is the handler
///    this repo installs: it also carries per-domain signature verifiers, which a Safe needs when
///    the *Safe itself* owns a ComposableCoW order rather than a Shed owning it.
/// 2. **A signature over the Safe message, not the digest.** The handler wraps the digest as a Safe
///    message (`defaultIsValidSignature`) and checks it against the Safe's owners, so the raw
///    digest must not be accepted. There is a test for that.
///
/// The stock `CompatibilityFallbackHandler` answers the same query with the same signature. The
/// Safe calls its handler rather than delegatecalling it — appending the original caller to the
/// calldata — which is what makes the handler's `ISignatureValidator(msg.sender)` resolve to the
/// Safe (`FallbackManager.sol:72-88`, `handler/CompatibilityFallbackHandler.sol:77-81`). Both
/// handlers were checked by calling a Safe from an unrelated address with a SafeMessage-wrapped
/// digest; both return the magic value.
contract PrivateTradeOwnersTest is PrivateTradeTestBase {
  bytes32 internal constant SAFE_MSG_TYPE_HASH = 0x60b3cbf8b4a223d68d641b3b6ddf9a298e7f33710cf3d3a9d1146b5a6150fbca;

  COWShedFactory internal factory;
  COWShedForComposableCoW internal implementation;

  ExtensibleFallbackHandler internal safeHandler;
  SafeProxyFactory internal safeFactory;
  Safe internal safeSingleton;

  /// @dev A Shed owner. `signer` is the key that authorises bundles: the owner itself for an EOA,
  /// an owner of the Safe otherwise.
  struct Party {
    address owner;
    address shed;
    address signer;
    uint256 pk;
    bool isSafe;
  }

  function setUp() public override {
    super.setUp();

    implementation = new COWShedForComposableCoW(IComposableCow(address(cow)));
    factory = new COWShedFactory(address(implementation));

    safeHandler = new ExtensibleFallbackHandler();
    safeFactory = new SafeProxyFactory();
    safeSingleton = new Safe();
  }

  // --- the same trade, three owner combinations

  function test_eoaOwnedShedSettlesAndPaysItsOwner() public {
    Party memory maker = _eoaParty("alice-eoa");
    Party memory taker = _eoaParty("bob-eoa");

    PrivateTradeTerms memory terms = _settleAPair(maker, taker);

    assertEq(wbtc.balanceOf(maker.owner), terms.offer.buyAmount, "alice's wallet was not paid");
    assertEq(usdc.balanceOf(taker.owner), terms.offer.sellAmount, "bob's wallet was not paid");
    assertEq(wbtc.balanceOf(maker.shed), 0, "proceeds parked in the shed");
  }

  function test_safeOwnedShedSettlesAndPaysTheSafe() public {
    Party memory maker = _safeParty("alice-safe");
    Party memory taker = _eoaParty("bob-eoa");

    PrivateTradeTerms memory terms = _settleAPair(maker, taker);

    // The Safe owns the order through its Shed and is paid itself: the beneficiary check compares
    // against the Shed's admin, which for this Shed is the Safe.
    assertEq(wbtc.balanceOf(maker.owner), terms.offer.buyAmount, "the Safe was not paid");
    assertEq(wbtc.balanceOf(maker.shed), 0, "proceeds parked in the shed");
    assertEq(wbtc.balanceOf(maker.signer), 0, "a signer was paid instead of the Safe");
    assertEq(usdc.balanceOf(taker.owner), terms.offer.sellAmount, "bob's wallet was not paid");
  }

  function test_bothSidesSafeOwned() public {
    Party memory maker = _safeParty("alice-safe");
    Party memory taker = _safeParty("bob-safe");

    PrivateTradeTerms memory terms = _settleAPair(maker, taker);

    assertEq(wbtc.balanceOf(maker.owner), terms.offer.buyAmount, "maker Safe was not paid");
    assertEq(usdc.balanceOf(taker.owner), terms.offer.sellAmount, "taker Safe was not paid");
  }

  /// @dev A Safe with no fallback handler cannot answer the Shed's ERC-1271 query at all, so its
  /// Shed can never authorise anything. This is the one setup step a Safe owner has that an EOA
  /// owner does not.
  function test_safeWithoutAFallbackHandlerCannotAuthorise() public {
    Party memory maker = _safePartyWithoutHandler("handless-safe");
    Party memory taker = _eoaParty("bob-eoa");

    PrivateTradeTerms memory terms = _termsFull(maker.shed, taker.shed, taker.shed, maker.owner, taker.owner);
    IConditionalOrder.ConditionalOrderParams memory params = _params(PrivateTradeRole.Maker, terms, "maker");
    usdc.mint(maker.shed, USDC_AMOUNT);

    Call[] memory calls = _bundle(address(usdc), USDC_AMOUNT, params);
    bytes32 nonce = keccak256("no-handler");
    uint256 deadline = block.timestamp + 1 hours;
    bytes memory signature = _signBundle(maker, calls, nonce, deadline);

    vm.prank(relayer);
    vm.expectRevert();
    factory.executeHooks(calls, nonce, deadline, maker.owner, signature);

    assertFalse(cow.singleOrders(maker.shed, cow.hash(params)), "a Shed with a silent owner authorised an order");
  }

  /// @dev A Safe's approval is over the Safe message, not over the raw digest.
  function test_safeOwnerMustSignTheSafeMessageNotTheRawDigest() public {
    Party memory maker = _safeParty("alice-safe");
    Party memory taker = _eoaParty("bob-eoa");

    PrivateTradeTerms memory terms = _termsFull(maker.shed, taker.shed, taker.shed, maker.owner, taker.owner);
    IConditionalOrder.ConditionalOrderParams memory params = _params(PrivateTradeRole.Maker, terms, "maker");
    usdc.mint(maker.shed, USDC_AMOUNT);

    Call[] memory calls = _bundle(address(usdc), USDC_AMOUNT, params);
    bytes32 nonce = keccak256("raw-digest");
    uint256 deadline = block.timestamp + 1 hours;

    // Signed over the digest the Shed computes, which is what an EOA owner would sign.
    bytes32 raw = ShedBundle.digest(address(factory), maker.shed, calls, nonce, deadline);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(maker.pk, raw);

    vm.prank(relayer);
    vm.expectRevert(bytes("GS026"));
    factory.executeHooks(calls, nonce, deadline, maker.owner, abi.encodePacked(r, s, v));

    // The same key, over the Safe message, is accepted.
    _relay(maker, calls, nonce);
    assertTrue(cow.singleOrders(maker.shed, cow.hash(params)), "the Safe message signature was not accepted");
  }

  // --- what the party actually authorised

  /// @dev The bundle a party signs carries the terms as `createChecked` calldata, which a wallet
  /// shows as a hex blob. The authoriser emits the terms decoded when it creates the order, so what
  /// was authorised is readable from the transaction itself: the audit trail for a party that
  /// blind-signed, and the thing a wallet or a watcher can reconcile against the page that proposed
  /// the terms.
  ///
  /// The authoriser is delegatecalled by the Shed, so the Shed is the event's emitter. A proposer
  /// cannot hide the terms it asked for from anyone reading the chain afterwards.
  function test_authorisationEmitsTheDecodedTerms() public {
    Party memory maker = _safeParty("alice-safe");
    Party memory taker = _eoaParty("bob-eoa");

    PrivateTradeTerms memory terms = _termsFull(maker.shed, taker.shed, taker.shed, maker.owner, taker.owner);
    IConditionalOrder.ConditionalOrderParams memory params = _params(PrivateTradeRole.Maker, terms, "maker");
    usdc.mint(maker.shed, USDC_AMOUNT);

    vm.expectEmit(true, true, true, true, maker.shed);
    emit PrivateTradeOrderAuthorised(
      maker.shed, maker.owner, PrivateTradeRole.Maker, PrivateTradeLib.offerId(terms.offer), terms
    );

    _relay(maker, _bundle(address(usdc), USDC_AMOUNT, params), keccak256("audit-trail"));
  }

  // --- the scenarios the simpler design cannot stop

  /// @dev One half alone is not a settlement. A solver holding nothing but the maker's authorised
  /// order cannot turn it into a trade: the wrapper demands the exact pair.
  function test_oneSidedSettlementIsRejected() public {
    Party memory maker = _safeParty("alice-safe");
    Party memory taker = _eoaParty("bob-eoa");

    (PrivateTradeTerms memory terms, IConditionalOrder.ConditionalOrderParams memory makerParams,) =
      _readyPair(maker, taker);
    IConditionalOrder.ConditionalOrderParams memory takerParams = _params(PrivateTradeRole.Taker, terms, "taker");

    GPv2Trade.Data[] memory makerOnly = new GPv2Trade.Data[](1);
    makerOnly[0] = _trades(terms, makerParams, takerParams)[0];

    vm.prank(solver);
    vm.expectRevert(PrivateTrade_BadSettlementShape.selector);
    wrapper.wrappedSettle(
      _settleDataWith(_tokens(), _clearingPrices(), makerOnly, _emptyInteractions()), _chainedWrapperData(terms)
    );
  }

  /// @dev A maker who names a counterparty gets that counterparty. A rival that obtains the same
  /// offer cannot take it: `allowedTaker` is inside the offer the maker authorised, and both the
  /// wrapper and the maker's own handler re-check it.
  function test_restrictedOfferRefusesARivalTaker() public {
    Party memory maker = _safeParty("alice-safe");
    Party memory taker = _eoaParty("bob-eoa");
    Party memory rival = _eoaParty("carol-eoa");

    PrivateTradeTerms memory terms = _termsFull(maker.shed, taker.shed, taker.shed, maker.owner, taker.owner);
    IConditionalOrder.ConditionalOrderParams memory makerParams = _params(PrivateTradeRole.Maker, terms, "maker");
    usdc.mint(maker.shed, USDC_AMOUNT);
    _relay(maker, _bundle(address(usdc), USDC_AMOUNT, makerParams), keccak256("maker"));

    // The rival accepts the same offer, as itself.
    PrivateTradeTerms memory rivalTerms = _termsFull(maker.shed, rival.shed, taker.shed, maker.owner, rival.owner);
    IConditionalOrder.ConditionalOrderParams memory rivalParams = _params(PrivateTradeRole.Taker, rivalTerms, "rival");

    vm.prank(solver);
    vm.expectRevert(abi.encodeWithSelector(PrivateTrade_TakerNotAllowed.selector, taker.shed, rival.shed));
    wrapper.wrappedSettle(_settleData(rivalTerms, makerParams, rivalParams), _chainedWrapperData(rivalTerms));
  }

  /// @dev Cancellation is the maker's, through the maker's own Shed. For a Safe owner that is the
  /// Safe's transaction; neither the counterparty nor the service can do it.
  function test_cancellationComesFromTheMakerShedOnly() public {
    Party memory maker = _safeParty("alice-safe");
    Party memory taker = _eoaParty("bob-eoa");

    PrivateTradeTerms memory terms = _termsFull(maker.shed, taker.shed, taker.shed, maker.owner, taker.owner);
    IConditionalOrder.ConditionalOrderParams memory params = _params(PrivateTradeRole.Maker, terms, "maker");
    usdc.mint(maker.shed, USDC_AMOUNT);
    _relay(maker, _bundle(address(usdc), USDC_AMOUNT, params), keccak256("maker"));

    vm.prank(taker.shed);
    vm.expectRevert(abi.encodeWithSelector(PrivateTrade_NotOfferMaker.selector, maker.shed, taker.shed));
    wrapper.cancelOffer(terms.offer);

    Call[] memory cancellation = ShedBundle.cancellationCalls(address(cow), params, address(wrapper), terms.offer);
    _relay(maker, cancellation, keccak256("cancel"));

    assertFalse(cow.singleOrders(maker.shed, cow.hash(params)), "order still authorised");
    assertEq(uint256(wrapper.offerState(PrivateTradeLib.offerId(terms.offer))), 2, "offer not cancelled");
  }

  // --- the Safe-specific beneficiary rule

  /// @dev A Safe-owned Shed is paid at the Safe, not at one of the Safe's signers. Naming a signer
  /// would route the proceeds past the Safe's own controls, so the Shed refuses it.
  function test_safeOwnedShedRefusesTermsThatPayASignerInsteadOfTheSafe() public {
    Party memory maker = _safeParty("alice-safe");
    Party memory taker = _eoaParty("bob-eoa");

    PrivateTradeTerms memory terms = _termsFull(maker.shed, taker.shed, taker.shed, maker.signer, taker.owner);
    IConditionalOrder.ConditionalOrderParams memory params = _params(PrivateTradeRole.Maker, terms, "maker");
    usdc.mint(maker.shed, USDC_AMOUNT);

    _relayExpectingRevert(
      maker,
      _bundle(address(usdc), USDC_AMOUNT, params),
      keccak256("signer-beneficiary"),
      abi.encodeWithSelector(
        PrivateTradeAuthoriser.PrivateTrade_BeneficiaryNotOwner.selector, uint256(0), maker.signer, maker.owner
      )
    );

    assertFalse(cow.singleOrders(maker.shed, cow.hash(params)), "an order paying a signer was created");
  }

  /// @dev The side is derived from which Shed executes, for a Safe-owned Shed too.
  function test_safeOwnedShedCannotClaimTheOtherSide() public {
    Party memory maker = _safeParty("alice-safe");
    Party memory taker = _eoaParty("bob-eoa");

    PrivateTradeTerms memory terms = _termsFull(maker.shed, taker.shed, taker.shed, maker.owner, taker.owner);
    IConditionalOrder.ConditionalOrderParams memory params = _params(PrivateTradeRole.Taker, terms, "wrong-side");
    usdc.mint(maker.shed, USDC_AMOUNT);

    _relayExpectingRevert(
      maker,
      _bundle(address(usdc), USDC_AMOUNT, params),
      keccak256("wrong-side"),
      abi.encodeWithSelector(
        PrivateTradeAuthoriser.PrivateTrade_RoleDoesNotMatchShed.selector,
        PrivateTradeRole.Taker,
        PrivateTradeRole.Maker
      )
    );
  }

  // --- the owner-kind-aware signature check

  /// @dev `recover` is ecrecover, so a Safe-owned Shed's valid signature recovers to `address(0)`.
  /// A service pre-checking its own work would reject it, and would not be able to tell that apart
  /// from a genuinely wrong signature. `validSignature` branches on the owner the way the Shed does.
  function test_bundleSignatureCheckHandlesBothOwnerKinds() public {
    Party memory eoa = _eoaParty("alice-eoa");
    Party memory safe = _safeParty("alice-safe");
    Party memory stranger = _eoaParty("stranger");
    Party memory taker = _eoaParty("bob-eoa");

    _assertSignatureRecognised(
      eoa, _termsFull(eoa.shed, taker.shed, taker.shed, eoa.owner, taker.owner), "eoa", stranger
    );
    _assertSignatureRecognised(
      safe, _termsFull(safe.shed, taker.shed, taker.shed, safe.owner, taker.owner), "safe", stranger
    );
  }

  /// @dev The library is the chain's own answer to "what will this authorise?", so a wallet or an
  /// independent checker does not have to parse the calldata itself.
  function test_describeReportsTheSideAndBeneficiary() public {
    Party memory maker = _safeParty("alice-safe");
    Party memory taker = _eoaParty("bob-eoa");

    PrivateTradeTerms memory terms = _termsFull(maker.shed, taker.shed, taker.shed, maker.owner, taker.owner);

    (PrivateTradeRole role, address beneficiary, bytes32 offerId) = authoriser.describe(maker.shed, terms);
    assertEq(uint256(role), uint256(PrivateTradeRole.Maker), "wrong side");
    assertEq(beneficiary, maker.owner, "wrong beneficiary");
    assertEq(offerId, PrivateTradeLib.offerId(terms.offer), "wrong offerId");

    (role, beneficiary,) = authoriser.describe(taker.shed, terms);
    assertEq(uint256(role), uint256(PrivateTradeRole.Taker), "wrong side for the taker");
    assertEq(beneficiary, taker.owner, "wrong taker beneficiary");

    vm.expectRevert(abi.encodeWithSelector(PrivateTradeAuthoriser.PrivateTrade_NotAParty.selector, address(0xbeef)));
    authoriser.describe(address(0xbeef), terms);
  }

  // --- harness

  /// @dev Full pair: both bundles relayed, tokens minted into both Sheds, then the settlement.
  function _settleAPair(Party memory maker, Party memory taker) internal returns (PrivateTradeTerms memory terms) {
    IConditionalOrder.ConditionalOrderParams memory makerParams;
    IConditionalOrder.ConditionalOrderParams memory takerParams;
    (terms, makerParams, takerParams) = _readyPair(maker, taker);

    vm.prank(solver);
    wrapper.wrappedSettle(_settleData(terms, makerParams, takerParams), _chainedWrapperData(terms));
  }

  function _readyPair(Party memory maker, Party memory taker)
    internal
    returns (
      PrivateTradeTerms memory terms,
      IConditionalOrder.ConditionalOrderParams memory makerParams,
      IConditionalOrder.ConditionalOrderParams memory takerParams
    )
  {
    terms = _termsFull(maker.shed, taker.shed, taker.shed, maker.owner, taker.owner);
    makerParams = _params(PrivateTradeRole.Maker, terms, "maker");
    takerParams = _params(PrivateTradeRole.Taker, terms, "taker");

    usdc.mint(maker.shed, terms.offer.sellAmount);
    wbtc.mint(taker.shed, terms.offer.buyAmount);

    _relay(
      maker, _bundle(address(usdc), terms.offer.sellAmount, makerParams), keccak256(abi.encode("maker", maker.shed))
    );
    _relay(
      taker, _bundle(address(wbtc), terms.offer.buyAmount, takerParams), keccak256(abi.encode("taker", taker.shed))
    );
  }

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
      target: address(authoriser),
      value: 0,
      callData: abi.encodeCall(PrivateTradeAuthoriser.createChecked, (cow, params)),
      allowFailure: false,
      isDelegateCall: true
    });
  }

  function _relay(Party memory party, Call[] memory calls, bytes32 nonce) internal {
    uint256 deadline = block.timestamp + 1 hours;
    bytes memory signature = _signBundle(party, calls, nonce, deadline);

    vm.prank(relayer);
    factory.executeHooks(calls, nonce, deadline, party.owner, signature);
  }

  /// @dev Same, but the expectation is armed *after* the signature is computed: `ShedBundle.digest`
  /// makes a static call to read the deployed Shed implementation, and `vm.expectRevert` binds to
  /// the next call, so signing after arming it would spend the expectation on that read.
  function _relayExpectingRevert(Party memory party, Call[] memory calls, bytes32 nonce, bytes memory expectedRevert)
    internal
  {
    uint256 deadline = block.timestamp + 1 hours;
    bytes memory signature = _signBundle(party, calls, nonce, deadline);

    vm.prank(relayer);
    vm.expectRevert(expectedRevert);
    factory.executeHooks(calls, nonce, deadline, party.owner, signature);
  }

  /// @dev The one difference between the owner kinds: what the signature is over.
  function _signBundle(Party memory party, Call[] memory calls, bytes32 nonce, uint256 deadline)
    internal
    view
    returns (bytes memory)
  {
    bytes32 digest = ShedBundle.digest(address(factory), party.shed, calls, nonce, deadline);
    bytes32 toSign = party.isSafe ? _safeMessageHash(party.owner, digest) : digest;
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(party.pk, toSign);
    return abi.encodePacked(r, s, v);
  }

  /// @dev The hash `ExtensibleFallbackHandler.defaultIsValidSignature` checks, built with the same
  /// library the handler uses.
  function _safeMessageHash(address safe, bytes32 digest) internal view returns (bytes32) {
    bytes memory messageData = EIP712.encodeMessageData(
      Safe(payable(safe)).domainSeparator(), SAFE_MSG_TYPE_HASH, abi.encode(keccak256(abi.encode(digest)))
    );
    return keccak256(messageData);
  }

  function _assertSignatureRecognised(
    Party memory party,
    PrivateTradeTerms memory terms,
    string memory label,
    Party memory stranger
  ) internal view {
    bytes32 nonce = keccak256(abi.encode(label, party.shed));
    uint256 deadline = block.timestamp + 1 hours;
    Call[] memory calls =
      _bundle(terms.offer.sellToken, terms.offer.sellAmount, _params(PrivateTradeRole.Maker, terms, "maker"));
    ShedBundle.Bundle memory bundle_ =
      ShedBundle.Bundle({owner: party.owner, shed: party.shed, calls: calls, nonce: nonce, deadline: deadline});

    bytes memory signature = _signBundle(party, calls, nonce, deadline);
    assertTrue(ShedBundle.validSignature(bundle_, address(factory), signature), "valid signature rejected");
    // `recover` is ecrecover over the Shed digest. For an EOA that is the owner; for a Safe the same
    // bytes recover to an unrelated address, which is exactly why the branch above exists.
    assertEq(
      ShedBundle.recover(bundle_, address(factory), signature) == party.owner,
      !party.isSafe,
      "recover no longer behaves as documented"
    );

    // A different key is rejected for both owner kinds.
    bytes memory wrong = _signBundle(stranger, calls, nonce, deadline);
    assertFalse(ShedBundle.validSignature(bundle_, address(factory), wrong), "a stranger was accepted");
  }

  function _eoaParty(string memory label) internal returns (Party memory party) {
    (address owner, uint256 pk) = makeAddrAndKey(label);
    party = Party({owner: owner, shed: factory.proxyOf(owner), signer: owner, pk: pk, isSafe: false});
  }

  function _safeParty(string memory label) internal returns (Party memory party) {
    party = _deploySafe(label, address(safeHandler));
  }

  function _safePartyWithoutHandler(string memory label) internal returns (Party memory party) {
    party = _deploySafe(label, address(0));
  }

  function _deploySafe(string memory label, address handler) internal returns (Party memory party) {
    (address signer, uint256 pk) = makeAddrAndKey(string.concat(label, "-signer"));

    address[] memory owners = new address[](1);
    owners[0] = signer;

    bytes memory initializer =
      abi.encodeCall(Safe.setup, (owners, 1, address(0), "", handler, address(0), 0, payable(address(0))));
    SafeProxy proxy =
      safeFactory.createProxyWithNonce(address(safeSingleton), initializer, uint256(keccak256(bytes(label))));

    party = Party({owner: address(proxy), shed: factory.proxyOf(address(proxy)), signer: signer, pk: pk, isSafe: true});
  }
}
