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
/// It is deliberately narrow. The only calls it can make are:
///
/// - `COWShedFactory.executeHooks`, which runs owner-signed bundles and nothing else;
/// - `PrivateTradeWrapper.wrappedSettle`, which validates the exact pair on-chain.
///
/// It cannot call `GPv2Settlement.settle` directly, so being on the solver allowlist grants it less
/// power than it grants an ordinary solver. A caller can only ever cause a private trade that both
/// parties already signed to execute, and cannot cause anything else.
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
