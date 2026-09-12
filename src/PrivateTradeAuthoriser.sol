// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {ComposableCoW} from "composable-cow/ComposableCoW.sol";
import {IConditionalOrder} from "composable-cow/interfaces/IConditionalOrder.sol";

import {PrivateTradeRole, PrivateTradeTerms} from "./interfaces/IPrivateTrade.sol";

/// @dev The Shed exposes the address that controls it, but only to itself.
interface IShedAdminView {
  function admin() external view returns (address);
}

/// @title PrivateTradeAuthoriser
/// @notice Authorises a conditional order, but only if the terms pay the party's own wallet.
///
/// @dev A party's bundle carries the terms, and those same terms are what gets created here. Checking
/// the beneficiary against the terms *about to be used* is what stops a proposer from naming itself
/// as the counterparty's beneficiary: the Shed refuses to create the order at all, before anything
/// reaches an orderbook or a solver.
///
/// The check has to be unforgeable in two ways, and both come from how this contract is invoked.
///
/// **It runs as the Shed.** The party's bundle executes this with `delegatecall`, which is the only
/// context in which a Shed can read its own admin: the proxy answers `admin()` only when the caller
/// is the proxy itself, so the implementation can read it and no external caller can. That is also
/// why this cannot be a plain call, and why the beneficiary cannot be checked from outside.
///
/// **The side is derived, not declared.** `staticInput` carries a role, and a bundle is composed by
/// whoever proposes the trade, so the role cannot be trusted. The executing Shed decides the side
/// instead — it can only be the party whose address appears in the terms — and a declared role that
/// disagrees is rejected. Otherwise a proposer could point the victim's Shed at the *other* side's
/// check, which it would pass while the victim's own proceeds went elsewhere.
contract PrivateTradeAuthoriser {
  error PrivateTrade_NotAParty(address shed);
  error PrivateTrade_RoleDoesNotMatchShed(PrivateTradeRole declared, PrivateTradeRole actual);
  error PrivateTrade_BeneficiaryNotOwner(uint256 side, address beneficiary, address owner);

  /// @notice Read the terms, check this side's beneficiary, and create the order.
  /// @dev Called by the party's Shed with `delegatecall`, so `address(this)` is the Shed and the
  /// `create` below is owned by it.
  function createChecked(ComposableCoW composableCoW, IConditionalOrder.ConditionalOrderParams calldata params)
    external
  {
    (PrivateTradeRole declared, PrivateTradeTerms memory terms) =
      abi.decode(params.staticInput, (PrivateTradeRole, PrivateTradeTerms));

    (PrivateTradeRole actual, address beneficiary) = _sideOf(address(this), terms);
    if (declared != actual) revert PrivateTrade_RoleDoesNotMatchShed(declared, actual);

    address owner = IShedAdminView(address(this)).admin();
    if (beneficiary != owner) revert PrivateTrade_BeneficiaryNotOwner(uint256(actual), beneficiary, owner);

    composableCoW.create(params, false);
  }

  /// @notice Which side a Shed is in these terms, and who that side pays.
  function _sideOf(address shed, PrivateTradeTerms memory terms) private pure returns (PrivateTradeRole, address) {
    if (shed == terms.offer.maker) return (PrivateTradeRole.Maker, terms.makerBeneficiary);
    if (shed == terms.taker) return (PrivateTradeRole.Taker, terms.takerBeneficiary);
    revert PrivateTrade_NotAParty(shed);
  }
}
