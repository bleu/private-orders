// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "cowprotocol/contracts/interfaces/IERC20.sol";
import {GPv2Settlement} from "cowprotocol/contracts/GPv2Settlement.sol";
import {GPv2AllowListAuthentication} from "cowprotocol/contracts/GPv2AllowListAuthentication.sol";
import {GPv2Order} from "cowprotocol/contracts/libraries/GPv2Order.sol";
import {GPv2Trade} from "cowprotocol/contracts/libraries/GPv2Trade.sol";
import {GPv2Interaction} from "cowprotocol/contracts/libraries/GPv2Interaction.sol";
import {GPv2Signing} from "cowprotocol/contracts/mixins/GPv2Signing.sol";

import {ComposableCoW} from "composable-cow/ComposableCoW.sol";
import {IConditionalOrder} from "composable-cow/interfaces/IConditionalOrder.sol";
import {COWShedFactory} from "cow-shed/COWShedFactory.sol";
import {Call} from "cow-shed/ICOWAuthHook.sol";

import {PrivateTradeWrapper} from "../../src/PrivateTradeWrapper.sol";
import {PrivateTradeOrder} from "../../src/PrivateTradeOrder.sol";
import {PrivateTradeLib} from "../../src/libraries/PrivateTradeLib.sol";
import {PrivateTradeAppData} from "../../src/libraries/PrivateTradeAppData.sol";
import {ICowSettlement} from "../../src/vendor/CowWrapper.sol";
import {
  PrivateOffer,
  PrivateTradeTerms,
  PrivateTradeRole,
  PrivateTrade_NoActiveTrade,
  PrivateTrade_ProposalPayloadMismatch
} from "../../src/interfaces/IPrivateTrade.sol";

import {GPv2TradeEncoder} from "../../src/vendor/GPv2TradeEncoder.sol";
import {PrivateTradeBuilder} from "../../src/libraries/PrivateTradeBuilder.sol";
import {PrivateTradeSubmission} from "../../src/libraries/PrivateTradeSubmission.sol";
import {PrivateTradeProposal} from "../../src/libraries/PrivateTradeProposal.sol";
import {PrivateTradeSubmitter} from "../../src/PrivateTradeSubmitter.sol";

/// @dev The Shed implementation states its own EIP-712 domain version, and the deployed version
/// differs between networks: mainnet runs 2.1.0, the offline stack runs 2.0.0. Read it from the
/// implementation instead of hardcoding, so the test signs over the domain the proxy actually uses.
interface IShedImplementation {
  function VERSION() external view returns (string memory);
}

/// @notice Shared end-to-end flow: two EOAs own their orders through CoW Sheds, and one settlement
/// exchanges the two assets atomically, on a real deployment of the protocol contracts.
///
/// @dev Subclasses supply the deployment addresses and the funding mechanism. Everything else --
/// the EIP-712 hook bundle, the ERC-1271 signature layout, the appData document, the clearing
/// prices -- is shared, because getting any of it subtly wrong would make the test pass for the
/// wrong reason.
abstract contract PrivateTradeE2EBase is Test {
  // Canonical on every network this runs against, including the offline stack.
  address internal constant SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
  address internal constant AUTHENTICATOR = 0x2c4c28DDBdAc9C5E7055b4C863b72eA0149D8aFE;
  address internal constant COMPOSABLE_COW = 0xfdaFc9d1902f4e0b84f65F49f244b32b31013b74;
  address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
  address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

  bytes32 internal constant EIP712_DOMAIN_TYPE_HASH =
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
  bytes32 internal constant EXECUTE_HOOKS_TYPE_HASH = keccak256(
    "ExecuteHooks(Call[] calls,bytes32 nonce,uint256 deadline)Call(address target,uint256 value,bytes callData,bool allowFailure,bool isDelegateCall)"
  );
  bytes32 internal constant CALL_TYPE_HASH =
    keccak256("Call(address target,uint256 value,bytes callData,bool allowFailure,bool isDelegateCall)");

  uint256 internal constant USDC_AMOUNT = 100e6;
  uint256 internal constant DAI_AMOUNT = 100e18;

  GPv2Settlement internal settlement;
  ComposableCoW internal cow;
  COWShedFactory internal shedFactory;
  PrivateTradeWrapper internal wrapper;
  PrivateTradeOrder internal handler;

  /// @dev The deployed, allowlisted relay. Anyone may call it; it owns no keys.
  PrivateTradeSubmitter internal submitter;

  address internal aliceEoa;
  uint256 internal alicePk;
  address internal bobEoa;
  uint256 internal bobPk;
  address internal aliceShed;
  address internal bobShed;

  /// @dev Stands in for the bonded solver that relays the settlement. This is BYOS.
  address internal solver;

  /// @dev Stands in for a BYOS sub-solver: an ordinary key with no CoW allowlist entry at all.
  /// Only its EIP-712 signature matters.
  address internal subSolver;
  uint256 internal subSolverPk;

  /// @dev `keccak256` of the Shed's EIP-712 domain version, read from the deployed implementation.
  bytes32 internal shedDomainVersion;

  bool internal active;

  /// @notice The Shed factory to use on this network.
  /// @notice Select the Shed factory to use, and the Shed implementation behind it.
  /// @dev Subclasses either point at a deployment or deploy the ComposableCoW variant themselves,
  /// because not every stack ships it: the offline stack deploys the plain `COWShed`.
  function _setUpShedFactory() internal virtual;

  /// @notice Put tokens in the two Sheds. Real balances are required: the settlement pulls them.
  function _fundSheds() internal virtual;

  /// @dev Subclasses call this after their fork is selected.
  function _setUpProtocol() internal {
    active = true;

    settlement = GPv2Settlement(payable(SETTLEMENT));
    cow = ComposableCoW(COMPOSABLE_COW);
    _setUpShedFactory();

    wrapper = new PrivateTradeWrapper(ICowSettlement(SETTLEMENT));
    handler = new PrivateTradeOrder(wrapper);
    submitter = new PrivateTradeSubmitter();

    // The wrapper becomes the direct caller of GPv2Settlement.settle, so it must be an
    // authenticated solver on this chain.
    GPv2AllowListAuthentication auth = GPv2AllowListAuthentication(AUTHENTICATOR);
    address manager = auth.manager();
    vm.prank(manager);
    auth.addSolver(address(wrapper));
    vm.prank(manager);
    auth.addSolver(address(submitter));

    shedDomainVersion = keccak256(bytes(IShedImplementation(shedFactory.implementation()).VERSION()));

    (aliceEoa, alicePk) = makeAddrAndKey("e2e-alice");
    (bobEoa, bobPk) = makeAddrAndKey("e2e-bob");
    solver = makeAddr("e2e-solver");
    (subSolver, subSolverPk) = makeAddrAndKey("byos-sub-solver");
    vm.prank(manager);
    auth.addSolver(solver);

    // The sub-solver deliberately gets no allowlist entry: BYOS's whole point is that it does not
    // need one. Only the wrapper (a bundle) and the submitter (BYOS) are allowlisted.
    assertFalse(auth.isSolver(subSolver), "sub-solver must not need an allowlist entry");

    aliceShed = shedFactory.proxyOf(aliceEoa);
    bobShed = shedFactory.proxyOf(bobEoa);
  }

  /// @dev What a party signs, and what the submitter relays.
  struct SignedTrade {
    PrivateTradeTerms terms;
    PrivateTradeSubmission.HookBundle maker;
    PrivateTradeSubmission.HookBundle taker;
  }

  function _submitterContext() internal view returns (PrivateTradeSubmission.Context memory) {
    return PrivateTradeSubmission.Context({
      wrapper: address(wrapper),
      handler: address(handler),
      shedFactory: address(shedFactory),
      settlement: address(settlement),
      proposal: PrivateTradeBuilder.unsignedProposal()
    });
  }

  /// @dev Fund both Sheds and have both parties sign their hook bundles, exactly as they would
  /// client-side. Nothing here is submitted yet.
  function _prepareTrade() internal returns (SignedTrade memory signed) {
    signed.terms = _terms(aliceShed, bobShed, bobShed);

    // Both parties must authorise the orders the builder will derive, so both sides derive them the
    // same way rather than each inventing their own params.
    (
      IConditionalOrder.ConditionalOrderParams memory makerParams,
      IConditionalOrder.ConditionalOrderParams memory takerParams
    ) = PrivateTradeBuilder.conditionalOrderParams(address(handler), signed.terms);

    _fundSheds();

    signed.maker = _signBundle(aliceEoa, alicePk, aliceShed, _bundle(USDC, USDC_AMOUNT, makerParams), "maker");
    signed.taker = _signBundle(bobEoa, bobPk, bobShed, _bundle(DAI, DAI_AMOUNT, takerParams), "taker");
  }

  /// @dev The pair, settled directly against the settlement contract, with no wrapper. This is the
  /// "another solver found both orders" case, and it must fail.
  function _runDirectSettlementReverts() internal {
    SignedTrade memory signed = _prepareTrade();

    // Relaying the bundles is permissionless, so a solver can put both orders on-chain. It still
    // cannot execute them without the wrapper.
    PrivateTradeSubmission.relayBundles(_submitterContext(), signed.maker, signed.taker);

    (
      IConditionalOrder.ConditionalOrderParams memory makerParams,
      IConditionalOrder.ConditionalOrderParams memory takerParams
    ) = PrivateTradeBuilder.conditionalOrderParams(address(handler), signed.terms);
    bytes32 appData = PrivateTradeBuilder.appDataHash(signed.terms, address(wrapper));

    IERC20[] memory tokens = PrivateTradeBuilder.tokens(signed.terms);
    uint256[] memory prices = PrivateTradeBuilder.clearingPrices(signed.terms);
    GPv2Trade.Data[] memory trades = PrivateTradeBuilder.trades(signed.terms, makerParams, takerParams, appData);
    GPv2Interaction.Data[][3] memory interactions = PrivateTradeBuilder.emptyInteractions();

    vm.prank(solver);
    vm.expectRevert(PrivateTrade_NoActiveTrade.selector);
    settlement.settle(tokens, prices, trades, interactions);

    assertEq(IERC20(USDC).balanceOf(aliceShed), USDC_AMOUNT, "funds moved despite revert");
    assertEq(IERC20(DAI).balanceOf(bobShed), DAI_AMOUNT, "funds moved despite revert");
  }

  /// @dev The full flow, driven by the submitter: relay both bundles, build the pair, submit.
  function _runPrivateTrade() internal {
    SignedTrade memory signed = _prepareTrade();

    // A production settlement contract holds balances from unrelated activity, so assert
    // retention rather than zero.
    uint256 settlementUsdcBefore = IERC20(USDC).balanceOf(SETTLEMENT);
    uint256 settlementDaiBefore = IERC20(DAI).balanceOf(SETTLEMENT);

    // No prank: `address(this)` is not an authenticated solver. The deployed submitter is, and it
    // is the submitter's identity that authenticates the calls it makes, not the caller's.
    submitter.submit(_submitterContext(), signed.terms, signed.maker, signed.taker);

    assertTrue(cow.singleOrders(aliceShed, cow.hash(_makerParams(signed.terms))), "maker order not authorised");
    assertTrue(cow.singleOrders(bobShed, cow.hash(_takerParams(signed.terms))), "taker order not authorised");

    assertEq(IERC20(USDC).balanceOf(aliceShed), 0, "alice shed still holds USDC");
    assertEq(IERC20(DAI).balanceOf(aliceShed), DAI_AMOUNT, "alice shed did not receive DAI");
    assertEq(IERC20(DAI).balanceOf(bobShed), 0, "bob shed still holds DAI");
    assertEq(IERC20(USDC).balanceOf(bobShed), USDC_AMOUNT, "bob shed did not receive USDC");
    assertEq(IERC20(USDC).balanceOf(SETTLEMENT), settlementUsdcBefore, "settlement retained USDC");
    assertEq(IERC20(DAI).balanceOf(SETTLEMENT), settlementDaiBefore, "settlement retained DAI");
  }

  /// @dev A submitter gets retried, so relaying a bundle that already executed must be a no-op
  /// rather than a revert. The pair itself still cannot settle twice.
  function _runResubmitIsSafe() internal {
    SignedTrade memory signed = _prepareTrade();

    submitter.submit(_submitterContext(), signed.terms, signed.maker, signed.taker);

    // Same bundles, same nonces: skipped, not reverted.
    submitter.relayBundles(_submitterContext(), signed.maker, signed.taker);

    // The pair cannot settle twice.
    vm.expectRevert(bytes("GPv2: order filled"));
    submitter.submitPrepared(_submitterContext(), signed.terms);

    assertEq(IERC20(DAI).balanceOf(aliceShed), DAI_AMOUNT, "alice shed did not receive DAI");
    assertEq(IERC20(USDC).balanceOf(bobShed), USDC_AMOUNT, "bob shed did not receive USDC");
  }

  /// @dev The full BYOS path: a sub-solver that holds no allowlist entry relays the parties'
  /// bundles and signs a proposal; the allowlisted submitter executes it; the wrapper verifies the
  /// proposal on-chain. `tamper` signs a commitment to a different pair.
  function _runByosProposal(bool tamper) internal {
    SignedTrade memory signed = _prepareTrade();
    PrivateTradeSubmission.Context memory context = _submitterContext();

    // Relaying is permissionless, so the sub-solver does it.
    PrivateTradeSubmission.relayBundles(context, signed.maker, signed.taker);

    bytes32 pairHash = PrivateTradeBuilder.termsHash(signed.terms, address(wrapper));
    PrivateTradeProposal.Proposal memory proposal = PrivateTradeProposal.Proposal({
      wrapper: address(wrapper),
      termsHash: tamper ? keccak256("a different pair") : pairHash,
      validUntil: block.timestamp + 30 minutes,
      signature: ""
    });
    (uint8 v, bytes32 r, bytes32 s) =
      vm.sign(subSolverPk, PrivateTradeProposal.digest(proposal, address(wrapper)));
    proposal.signature = abi.encodePacked(r, s, v);

    context.proposal = proposal;

    if (tamper) {
      vm.expectRevert(
        abi.encodeWithSelector(
          PrivateTrade_ProposalPayloadMismatch.selector, pairHash, proposal.termsHash
        )
      );
      submitter.submitPrepared(context, signed.terms);
      return;
    }

    submitter.submitPrepared(context, signed.terms);

    assertEq(IERC20(DAI).balanceOf(aliceShed), DAI_AMOUNT, "alice shed did not receive DAI");
    assertEq(IERC20(USDC).balanceOf(bobShed), USDC_AMOUNT, "bob shed did not receive USDC");
  }

  function _makerParams(PrivateTradeTerms memory terms)
    internal
    view
    returns (IConditionalOrder.ConditionalOrderParams memory maker)
  {
    (maker,) = PrivateTradeBuilder.conditionalOrderParams(address(handler), terms);
  }

  function _takerParams(PrivateTradeTerms memory terms)
    internal
    view
    returns (IConditionalOrder.ConditionalOrderParams memory taker)
  {
    (, taker) = PrivateTradeBuilder.conditionalOrderParams(address(handler), terms);
  }

  // --- fixtures

  function _terms(address maker, address taker, address allowedTaker) internal view returns (PrivateTradeTerms memory) {
    return PrivateTradeTerms({
      offer: PrivateOffer({
        maker: maker,
        allowedTaker: allowedTaker,
        sellToken: USDC,
        sellAmount: USDC_AMOUNT,
        buyToken: DAI,
        buyAmount: DAI_AMOUNT,
        validTo: uint32(block.timestamp + 1 days),
        salt: keccak256(abi.encode("e2e-private-trade", maker, taker))
      }),
      taker: taker
    });
  }

  function _params(PrivateTradeRole role, PrivateTradeTerms memory terms, string memory salt)
    internal
    view
    returns (IConditionalOrder.ConditionalOrderParams memory)
  {
    return IConditionalOrder.ConditionalOrderParams({
      handler: IConditionalOrder(address(handler)), salt: keccak256(bytes(salt)), staticInput: abi.encode(role, terms)
    });
  }

  function _tokens() internal pure returns (IERC20[] memory tokens) {
    tokens = new IERC20[](2);
    tokens[0] = IERC20(USDC);
    tokens[1] = IERC20(DAI);
  }

  /// @dev `p0 / p1 == buyAmount / sellAmount`, in the units the settlement uses.
  function _clearingPrices() internal pure returns (uint256[] memory prices) {
    prices = new uint256[](2);
    prices[0] = 1e12;
    prices[1] = 1;
  }

  function _emptyInteractions() internal pure returns (GPv2Interaction.Data[][3] memory interactions) {
    interactions = [new GPv2Interaction.Data[](0), new GPv2Interaction.Data[](0), new GPv2Interaction.Data[](0)];
  }

  function _trades(
    PrivateTradeTerms memory terms,
    IConditionalOrder.ConditionalOrderParams memory makerParams,
    IConditionalOrder.ConditionalOrderParams memory takerParams,
    bytes32 appData
  ) internal pure returns (GPv2Trade.Data[] memory trades) {
    trades = new GPv2Trade.Data[](2);
    trades[0] = _trade(PrivateTradeLib.makerOrder(terms, appData), makerParams, terms.offer.maker, 0, 1, appData);
    trades[1] = _trade(PrivateTradeLib.takerOrder(terms, appData), takerParams, terms.taker, 1, 0, appData);
  }

  function _trade(
    GPv2Order.Data memory order,
    IConditionalOrder.ConditionalOrderParams memory params,
    address owner,
    uint256 sellTokenIndex,
    uint256 buyTokenIndex,
    bytes32 appData
  ) internal pure returns (GPv2Trade.Data memory) {
    ComposableCoW.PayloadStruct memory payload =
      ComposableCoW.PayloadStruct({proof: new bytes32[](0), params: params, offchainInput: ""});

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
      signature: abi.encodePacked(owner, abi.encode(order, payload))
    });
  }

  function _chainedWrapperData(PrivateTradeTerms memory terms) internal pure returns (bytes memory) {
    bytes memory data = PrivateTradeAppData.wrapperData(PrivateTradeLib.offerId(terms.offer), terms);
    return abi.encodePacked(uint16(data.length), data);
  }

  // --- Shed bundles

  function _bundle(address sellToken, uint256 sellAmount, IConditionalOrder.ConditionalOrderParams memory params)
    internal
    view
    returns (Call[] memory calls)
  {
    calls = new Call[](2);
    calls[0] = Call({
      target: sellToken,
      value: 0,
      callData: abi.encodeCall(IERC20.approve, (address(settlement.vaultRelayer()), sellAmount)),
      allowFailure: false,
      isDelegateCall: false
    });
    calls[1] = Call({
      target: COMPOSABLE_COW,
      value: 0,
      callData: abi.encodeCall(ComposableCoW.create, (params, false)),
      allowFailure: false,
      isDelegateCall: false
    });
  }

  /// @dev Anyone can relay; the relayer only needs the owner's signature.
  function _signBundle(address owner, uint256 pk, address shed, Call[] memory calls, string memory label)
    internal
    view
    returns (PrivateTradeSubmission.HookBundle memory bundle)
  {
    bundle = PrivateTradeSubmission.HookBundle({
      owner: owner,
      shed: shed,
      calls: calls,
      nonce: keccak256(abi.encode("e2e-bundle", label, owner)),
      deadline: block.timestamp + 1 hours,
      signature: ""
    });

    bytes32 digest = _executeHooksDigest(shed, calls, bundle.nonce, bundle.deadline);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
    bundle.signature = abi.encodePacked(r, s, v);
  }

  /// @dev Mirrors `LibAuthenticatedHooks.hashToSign`, including the single-byte `v` encoding.
  function _executeHooksDigest(address shed, Call[] memory calls, bytes32 nonce, uint256 deadline)
    internal
    view
    returns (bytes32)
  {
    bytes32 domainSeparator =
      keccak256(abi.encode(EIP712_DOMAIN_TYPE_HASH, keccak256("COWShed"), shedDomainVersion, block.chainid, shed));

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
