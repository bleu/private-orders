// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Test} from 'forge-std/Test.sol';

import {IVault} from 'cowprotocol/contracts/interfaces/IVault.sol';
import {IERC20} from 'cowprotocol/contracts/interfaces/IERC20.sol';
import {GPv2Settlement} from 'cowprotocol/contracts/GPv2Settlement.sol';
import {GPv2AllowListAuthentication} from 'cowprotocol/contracts/GPv2AllowListAuthentication.sol';
import {GPv2Order} from 'cowprotocol/contracts/libraries/GPv2Order.sol';
import {GPv2Trade} from 'cowprotocol/contracts/libraries/GPv2Trade.sol';
import {GPv2Interaction} from 'cowprotocol/contracts/libraries/GPv2Interaction.sol';
import {GPv2Signing} from 'cowprotocol/contracts/mixins/GPv2Signing.sol';

import {ComposableCoW} from 'composable-cow/ComposableCoW.sol';
import {IConditionalOrder} from 'composable-cow/interfaces/IConditionalOrder.sol';

import {PrivateTradeWrapper} from '../../src/PrivateTradeWrapper.sol';
import {PrivateTradeOrder} from '../../src/PrivateTradeOrder.sol';
import {PrivateTradeLib} from '../../src/libraries/PrivateTradeLib.sol';
import {PrivateOffer, PrivateTradeTerms, PrivateTradeRole} from '../../src/interfaces/IPrivateTrade.sol';

import {GPv2TradeEncoder} from './GPv2TradeEncoder.sol';
import {TestERC20} from './TestERC20.sol';
import {TestPrivateWallet} from './TestPrivateWallet.sol';

/// @notice Shared harness: a real settlement contract, a real ComposableCoW, the real wrapper and
/// handler, and three contract wallets standing in for CoW Sheds.
///
/// @dev `IVault` is a plain address on purpose. With `BALANCE_ERC20` on both sides — which the
/// wrapper enforces — `GPv2Transfer` moves tokens with plain `transferFrom`/`transfer` and never
/// touches the vault. Token balances therefore really move in these tests.
abstract contract PrivateTradeTestBase is Test {
    uint256 internal constant USDC_AMOUNT = 100e6;
    uint256 internal constant WBTC_AMOUNT = 5e6; // 0.05 WBTC at 8 decimals
    bytes32 internal constant APP_DATA = keccak256('cow.private.trades.test');

    GPv2AllowListAuthentication internal allowList;
    GPv2Settlement internal settlement;
    ComposableCoW internal cow;
    PrivateTradeWrapper internal wrapper;
    PrivateTradeOrder internal handler;

    TestERC20 internal usdc;
    TestERC20 internal wbtc;

    TestPrivateWallet internal alice;
    TestPrivateWallet internal bob;
    TestPrivateWallet internal carol;

    address internal aliceOwner = makeAddr('alice-owner');
    address internal bobOwner = makeAddr('bob-owner');
    address internal carolOwner = makeAddr('carol-owner');

    /// @dev Stands in for the BYOS bonded solver: the only account allowed to submit settlements.
    address internal solver = makeAddr('byos-solver');

    address internal relayer;

    function setUp() public virtual {
        allowList = new GPv2AllowListAuthentication();
        allowList.initializeManager(address(this));

        settlement = new GPv2Settlement(allowList, IVault(makeAddr('balancer-vault')));
        relayer = address(settlement.vaultRelayer());

        cow = new ComposableCoW(address(settlement));

        wrapper = new PrivateTradeWrapper(payable(address(settlement)));
        handler = new PrivateTradeOrder(wrapper);

        allowList.addSolver(address(wrapper));
        allowList.addSolver(solver);

        usdc = new TestERC20('USD Coin', 'USDC', 6);
        wbtc = new TestERC20('Wrapped BTC', 'WBTC', 8);

        alice = new TestPrivateWallet(cow, aliceOwner);
        bob = new TestPrivateWallet(cow, bobOwner);
        carol = new TestPrivateWallet(cow, carolOwner);
    }

    // --- fixtures

    function _terms(address taker) internal view returns (PrivateTradeTerms memory) {
        return _terms(taker, address(0));
    }

    function _terms(address taker, address allowedTaker) internal view returns (PrivateTradeTerms memory) {
        return PrivateTradeTerms({
            offer: PrivateOffer({
                maker: address(alice),
                allowedTaker: allowedTaker,
                sellToken: address(usdc),
                sellAmount: USDC_AMOUNT,
                buyToken: address(wbtc),
                buyAmount: WBTC_AMOUNT,
                validTo: uint32(block.timestamp + 1 days),
                salt: keccak256(abi.encode('private-trade', taker, allowedTaker))
            }),
            taker: taker,
            appData: APP_DATA
        });
    }

    function _fund(TestPrivateWallet wallet, TestERC20 token, uint256 amount) internal {
        token.mint(address(wallet), amount);
    }

    function _approveRelayer(TestPrivateWallet wallet, TestERC20 token, uint256 amount) internal {
        vm.prank(wallet.OWNER());
        wallet.approve(address(token), relayer, amount);
    }

    /// @dev Both parties funded and approved, the way a Shed hook bundle would leave them.
    function _fundAndApprove(PrivateTradeTerms memory terms) internal {
        _fund(alice, usdc, terms.offer.sellAmount);
        _approveRelayer(alice, usdc, terms.offer.sellAmount);
        _fund(bob, wbtc, terms.offer.buyAmount);
        _approveRelayer(bob, wbtc, terms.offer.buyAmount);
    }

    function _params(PrivateTradeRole role, PrivateTradeTerms memory terms, string memory salt)
        internal
        view
        returns (IConditionalOrder.ConditionalOrderParams memory)
    {
        return IConditionalOrder.ConditionalOrderParams({
            handler: IConditionalOrder(address(handler)),
            salt: keccak256(bytes(salt)),
            staticInput: abi.encode(role, terms)
        });
    }

    function _authorize(
        TestPrivateWallet wallet,
        PrivateTradeRole role,
        PrivateTradeTerms memory terms,
        string memory salt
    ) internal returns (IConditionalOrder.ConditionalOrderParams memory params) {
        params = _params(role, terms, salt);
        vm.prank(wallet.OWNER());
        wallet.createOrder(cow, params);
    }

    // --- settlement construction

    function _trades(
        PrivateTradeTerms memory terms,
        IConditionalOrder.ConditionalOrderParams memory makerParams,
        IConditionalOrder.ConditionalOrderParams memory takerParams
    ) internal pure returns (GPv2Trade.Data[] memory trades) {
        trades = new GPv2Trade.Data[](2);
        trades[0] = _trade(
            PrivateTradeLib.makerOrder(terms), makerParams, terms.offer.maker, 0, 1
        );
        trades[1] = _trade(PrivateTradeLib.takerOrder(terms), takerParams, terms.taker, 1, 0);
    }

    function _trade(
        GPv2Order.Data memory order,
        IConditionalOrder.ConditionalOrderParams memory params,
        address owner,
        uint256 sellTokenIndex,
        uint256 buyTokenIndex
    ) internal pure returns (GPv2Trade.Data memory) {
        ComposableCoW.PayloadStruct memory payload =
            ComposableCoW.PayloadStruct({proof: new bytes32[](0), params: params, offchainInput: ''});

        return GPv2Trade.Data({
            sellTokenIndex: sellTokenIndex,
            buyTokenIndex: buyTokenIndex,
            receiver: order.receiver,
            sellAmount: order.sellAmount,
            buyAmount: order.buyAmount,
            validTo: order.validTo,
            appData: order.appData,
            feeAmount: order.feeAmount,
            flags: GPv2TradeEncoder.encodeFlags(order, GPv2Signing.Scheme.Eip1271),
            executedAmount: order.sellAmount,
            signature: abi.encodePacked(owner, abi.encode(order, payload))
        });
    }

    function _tokens() internal view returns (IERC20[] memory tokens) {
        tokens = new IERC20[](2);
        tokens[0] = IERC20(address(usdc));
        tokens[1] = IERC20(address(wbtc));
    }

    /// @dev Clearing prices that make the two legs exact mirrors: `price0 / price1 == buyAmount / sellAmount`.
    function _clearingPrices() internal pure returns (uint256[] memory prices) {
        prices = new uint256[](2);
        prices[0] = WBTC_AMOUNT;
        prices[1] = USDC_AMOUNT;
    }

    function _emptyInteractions() internal pure returns (GPv2Interaction.Data[][3] memory interactions) {
        interactions = [
            new GPv2Interaction.Data[](0),
            new GPv2Interaction.Data[](0),
            new GPv2Interaction.Data[](0)
        ];
    }

    function _wrapperData(PrivateTradeTerms memory terms) internal pure returns (bytes memory) {
        return abi.encode(PrivateTradeLib.offerId(terms.offer), terms);
    }

    /// @dev Full happy-path setup: wallet fixtures plus both conditional orders authorised.
    function _readyTrade()
        internal
        returns (
            PrivateTradeTerms memory terms,
            IConditionalOrder.ConditionalOrderParams memory makerParams,
            IConditionalOrder.ConditionalOrderParams memory takerParams
        )
    {
        terms = _terms(address(bob), address(bob));
        _fundAndApprove(terms);
        makerParams = _authorize(alice, PrivateTradeRole.Maker, terms, 'maker');
        takerParams = _authorize(bob, PrivateTradeRole.Taker, terms, 'taker');
    }
}
