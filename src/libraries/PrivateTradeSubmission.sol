// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {GPv2Settlement} from "cowprotocol/contracts/GPv2Settlement.sol";
import {COWShedFactory} from "cow-shed/COWShedFactory.sol";
import {COWShed} from "cow-shed/COWShed.sol";
import {IConditionalOrder} from "composable-cow/interfaces/IConditionalOrder.sol";
import {Call} from "cow-shed/ICOWAuthHook.sol";

import {PrivateTradeTerms} from "../interfaces/IPrivateTrade.sol";
import {PrivateTradeBuilder} from "./PrivateTradeBuilder.sol";
import {PrivateTradeProposal} from "./PrivateTradeProposal.sol";
import {ICowWrapper} from "../vendor/CowWrapper.sol";

/// @title PrivateTradeSubmission
/// @notice Everything an allowlisted submitter does for a private trade, in order.
///
/// @dev Three steps, none of which need a private key:
///
/// 1. Relay each party's Shed hook bundle, which approves the vault relayer and authorises that
///    party's conditional order. Permissionless: a valid bundle is an owner signature.
/// 2. Derive both orders, both EIP-1271 signatures, the settlement calldata and the bundle chain.
/// 3. Call `wrappedSettle` on the wrapper.
///
/// The submitter is transport, not a trust anchor. It cannot fill one half without the other, alter
/// the terms, redirect proceeds, or reuse either order: the wrapper and the order handlers refuse
/// all of that on-chain. A misbehaving submitter can only decline to submit.
///
/// The caller of `submit` must be an authenticated solver, because `CowWrapper.wrappedSettle`
/// enforces it. That is the one permission a private trade needs, and it is the role BYOS exists to
/// fill.
library PrivateTradeSubmission {
  /// @param owner The Shed's owner EOA.
  /// @param shed The Shed proxy that will execute the calls.
  /// @param calls `approve(vaultRelayer)` and `ComposableCoW.create(params)`.
  /// @param nonce Shed nonce, consumed once. Re-relaying is skipped, so submission is retry-safe.
  /// @param deadline Shed bundle deadline.
  /// @param signature Owner's `ExecuteHooks` signature.
  struct HookBundle {
    address owner;
    address shed;
    Call[] calls;
    bytes32 nonce;
    uint256 deadline;
    bytes signature;
  }

  /// @param wrapper The private trade bundle that will mediate the settlement.
  /// @param handler The conditional order handler both orders are registered with.
  /// @param shedFactory The `COWShedFactory` whose proxies own the orders.
  /// @param settlement The `GPv2Settlement` the wrapper forwards to. Passed in rather than read
  /// from the wrapper, so a submission makes no calls that are not part of settling.
  struct Context {
    address wrapper;
    address handler;
    address shedFactory;
    address settlement;
    /// @dev A signed BYOS sub-solver proposal. Leave the signature empty for a permissionless
    /// submission with no on-chain proposal check.
    PrivateTradeProposal.Proposal proposal;
  }

  /// @notice Relay both hook bundles, then submit the pair. Safe to call again if the first
  /// attempt did not land: executed bundles are skipped by nonce.
  function submit(
    Context memory context,
    PrivateTradeTerms memory terms,
    HookBundle memory maker,
    HookBundle memory taker
  ) internal returns (bytes4) {
    relayBundles(context, maker, taker);
    return submitPrepared(context, terms);
  }

  /// @notice Submit a pair whose orders are already authorised and funded.
  function submitPrepared(Context memory context, PrivateTradeTerms memory terms) internal returns (bytes4 magic) {
    GPv2Settlement settlement = GPv2Settlement(payable(context.settlement));

    bytes32 appData = PrivateTradeBuilder.appDataHash(terms, context.wrapper, context.proposal);
    (
      IConditionalOrder.ConditionalOrderParams memory makerParams,
      IConditionalOrder.ConditionalOrderParams memory takerParams
    ) = PrivateTradeBuilder.conditionalOrderParams(context.handler, terms);

    bytes memory data = PrivateTradeBuilder.settleData(settlement, terms, makerParams, takerParams, appData);
    bytes memory chain =
      PrivateTradeBuilder.chainedWrapperData(terms, context.wrapper, context.proposal);

    magic = ICowWrapper(context.wrapper).wrappedSettle(data, chain);
  }

  /// @notice Relay both hook bundles. Skips any bundle whose nonce is already consumed.
  function relayBundles(Context memory context, HookBundle memory maker, HookBundle memory taker) internal {
    _relay(context.shedFactory, maker);
    _relay(context.shedFactory, taker);
  }

  function _relay(address shedFactory, HookBundle memory bundle) private {
    // The proxy may not exist yet: the factory deploys it while executing the bundle. A call to
    // a codeless address succeeds with no return data, which would fail to decode here.
    if (bundle.shed.code.length > 0 && COWShed(payable(bundle.shed)).nonces(bundle.nonce)) return;
    COWShedFactory(shedFactory)
      .executeHooks(bundle.calls, bundle.nonce, bundle.deadline, bundle.owner, bundle.signature);
  }
}
