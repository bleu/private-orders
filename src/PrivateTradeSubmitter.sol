// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Call} from "cow-shed/ICOWAuthHook.sol";

import {PrivateTradeTerms} from "./interfaces/IPrivateTrade.sol";
import {PrivateTradeSubmission} from "./libraries/PrivateTradeSubmission.sol";

/// @title PrivateTradeSubmitter
/// @notice The one permission a private trade needs: an allowlisted account that forwards a pair to
/// the wrapper.
///
/// @dev Deploy once, allowlist once, then anyone can relay a private trade — the link service,
/// either counterparty, or a bot. It holds no funds, stores no state, and owns no keys, so there is
/// no account to compromise.
///
/// It is deliberately narrow in what it *does*: it makes two kinds of call and nothing else.
///
/// - `COWShedFactory.executeHooks`, which runs owner-signed bundles;
/// - `ICowWrapper.wrappedSettle`, which validates the exact pair on-chain.
///
/// It is not narrow in *where* it points them. The wrapper, the factory, the handler and the
/// settlement all arrive in the caller's `Context`, so what this contract really offers an allowlisted
/// seat is "call any address that exposes those two selectors, as me". The calls are still bounded by
/// their own validation — an owner-signed bundle is the only thing `executeHooks` will run, and a pair
/// both parties signed is the only thing a private wrapper will settle — but a reviewer asked to
/// authenticate this contract is entitled to ask about that rather than take "narrow" for granted.
///
/// Baking the wrapper and the factory into immutables would make the sentence true rather than
/// accurate, at the cost of one submission contract per deployment and a constructor that has to be
/// given both. That is the change to make before asking for a seat, if the seat is wanted.
///
/// It cannot call `GPv2Settlement.settle` directly, so being on the solver allowlist grants it less
/// power than it grants an ordinary solver.
contract PrivateTradeSubmitter {
  /// @notice Relay both hook bundles, then submit the pair.
  /// @dev Safe to retry: bundles whose nonce is already consumed are skipped. A pair that already
  /// settled reverts in the settlement, as it must.
  function submit(
    PrivateTradeSubmission.Context calldata context,
    PrivateTradeTerms calldata terms,
    PrivateTradeSubmission.HookBundle calldata maker,
    PrivateTradeSubmission.HookBundle calldata taker
  ) external returns (bytes4) {
    return PrivateTradeSubmission.submit(context, terms, maker, taker);
  }

  /// @notice Submit a pair whose orders are already authorised and funded.
  function submitPrepared(PrivateTradeSubmission.Context calldata context, PrivateTradeTerms calldata terms)
    external
    returns (bytes4)
  {
    return PrivateTradeSubmission.submitPrepared(context, terms);
  }

  /// @notice Relay hook bundles without settling. Permissionless, same as calling the factory.
  function relayBundles(
    PrivateTradeSubmission.Context calldata context,
    PrivateTradeSubmission.HookBundle calldata maker,
    PrivateTradeSubmission.HookBundle calldata taker
  ) external {
    PrivateTradeSubmission.relayBundles(context, maker, taker);
  }
}
