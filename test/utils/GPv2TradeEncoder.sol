// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {GPv2Order} from 'cowprotocol/contracts/libraries/GPv2Order.sol';
import {GPv2Signing} from 'cowprotocol/contracts/mixins/GPv2Signing.sol';

/// @title GPv2TradeEncoder
/// @author mfw78 <mfw78@rndlabs.xyz>
/// @dev Encodes CoW Protocol trade flags for local tests. Copied from cowprotocol/composable-cow.
library GPv2TradeEncoder {
    uint256 constant FLAG_ORDER_KIND_BUY = 0x01;
    uint256 constant FLAG_FILL_PARTIAL = 0x02;
    uint256 constant FLAG_SELL_TOKEN_BALANCER_EXTERNAL = 0x08;
    uint256 constant FLAG_SELL_TOKEN_BALANCER_INTERNAL = 0x0c;
    uint256 constant FLAG_BUY_TOKEN_BALANCER_INTERNAL = 0x10;
    uint256 constant FLAG_SIGNATURE_SCHEME_ETHSIGN = 0x20;
    uint256 constant FLAG_SIGNATURE_SCHEME_EIP1271 = 0x40;
    uint256 constant FLAG_SIGNATURE_SCHEME_PRESIGN = 0x60;

    function encodeFlags(GPv2Order.Data memory order, GPv2Signing.Scheme signingScheme)
        internal
        pure
        returns (uint256 flags)
    {
        if (order.kind == GPv2Order.KIND_BUY) flags |= FLAG_ORDER_KIND_BUY;
        if (order.partiallyFillable) flags |= FLAG_FILL_PARTIAL;

        if (order.sellTokenBalance == GPv2Order.BALANCE_EXTERNAL) {
            flags |= FLAG_SELL_TOKEN_BALANCER_EXTERNAL;
        } else if (order.sellTokenBalance == GPv2Order.BALANCE_INTERNAL) {
            flags |= FLAG_SELL_TOKEN_BALANCER_INTERNAL;
        }

        if (order.buyTokenBalance == GPv2Order.BALANCE_INTERNAL) {
            flags |= FLAG_BUY_TOKEN_BALANCER_INTERNAL;
        }

        if (signingScheme == GPv2Signing.Scheme.EthSign) {
            flags |= FLAG_SIGNATURE_SCHEME_ETHSIGN;
        } else if (signingScheme == GPv2Signing.Scheme.Eip1271) {
            flags |= FLAG_SIGNATURE_SCHEME_EIP1271;
        } else if (signingScheme == GPv2Signing.Scheme.PreSign) {
            flags |= FLAG_SIGNATURE_SCHEME_PRESIGN;
        }
    }

    /// @dev Mirror of `encodeFlags`, used to assert the helper still agrees with the settlement.
    function decodeFlags(uint256 flags)
        internal
        pure
        returns (bytes32 kind, bool partiallyFillable, GPv2Signing.Scheme signingScheme)
    {
        kind = flags & FLAG_ORDER_KIND_BUY == FLAG_ORDER_KIND_BUY ? GPv2Order.KIND_BUY : GPv2Order.KIND_SELL;
        partiallyFillable = flags & FLAG_FILL_PARTIAL == FLAG_FILL_PARTIAL;
        bytes32 schemeBits = bytes32(flags & 0x60);
        if (schemeBits == bytes32(FLAG_SIGNATURE_SCHEME_ETHSIGN)) {
            signingScheme = GPv2Signing.Scheme.EthSign;
        } else if (schemeBits == bytes32(FLAG_SIGNATURE_SCHEME_EIP1271)) {
            signingScheme = GPv2Signing.Scheme.Eip1271;
        } else if (schemeBits == bytes32(FLAG_SIGNATURE_SCHEME_PRESIGN)) {
            signingScheme = GPv2Signing.Scheme.PreSign;
        } else {
            signingScheme = GPv2Signing.Scheme.Eip712;
        }
    }
}
