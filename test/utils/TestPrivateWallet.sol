// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {ComposableCoW} from 'composable-cow/ComposableCoW.sol';
import {IConditionalOrder} from 'composable-cow/interfaces/IConditionalOrder.sol';
import {ERC1271Forwarder} from 'composable-cow/ERC1271Forwarder.sol';
import {IERC20} from 'cowprotocol/contracts/interfaces/IERC20.sol';

/// @notice Minimal account that stands in for a CoW Shed: an owner-controlled contract wallet
/// that can authorise ComposableCoW orders, hold tokens, and approve the vault relayer.
///
/// @dev It inherits `ERC1271Forwarder`, so an order it owns is valid on-chain exactly the way a
/// Shed-owned order would be. This keeps the settlement tests independent from Shed deployment
/// while exercising the real signature-verification path.
contract TestPrivateWallet is ERC1271Forwarder {
    address public immutable OWNER;

    error TestPrivateWallet_OnlyOwner();
    error TestPrivateWallet_CallFailed(bytes reason);

    constructor(ComposableCoW composableCoW_, address owner_) ERC1271Forwarder(composableCoW_) {
        OWNER = owner_;
    }

    modifier onlyOwner() {
        if (msg.sender != OWNER) revert TestPrivateWallet_OnlyOwner();
        _;
    }

    function approve(address token, address spender, uint256 amount) external onlyOwner {
        IERC20(token).approve(spender, amount);
    }

    function createOrder(ComposableCoW composableCoW, IConditionalOrder.ConditionalOrderParams calldata params)
        external
        onlyOwner
    {
        composableCoW.create(params, false);
    }

    function execute(address target, bytes calldata data) external onlyOwner returns (bytes memory) {
        (bool ok, bytes memory result) = target.call(data);
        if (!ok) revert TestPrivateWallet_CallFailed(result);
        return result;
    }

    receive() external payable {}
}
