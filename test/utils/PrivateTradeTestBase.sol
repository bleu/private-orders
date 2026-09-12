// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {ICowAuthentication, ICowSettlement} from "../../src/vendor/CowWrapper.sol";
import {CowWrapperHelpers} from "../../src/vendor/CowWrapperHelpers.sol";

import {IVault} from "cowprotocol/contracts/interfaces/IVault.sol";
import {IERC20} from "cowprotocol/contracts/interfaces/IERC20.sol";
import {GPv2Settlement} from "cowprotocol/contracts/GPv2Settlement.sol";
import {GPv2AllowListAuthentication} from "cowprotocol/contracts/GPv2AllowListAuthentication.sol";
import {GPv2Order} from "cowprotocol/contracts/libraries/GPv2Order.sol";
import {GPv2Trade} from "cowprotocol/contracts/libraries/GPv2Trade.sol";
import {GPv2Interaction} from "cowprotocol/contracts/libraries/GPv2Interaction.sol";
import {GPv2Signing} from "cowprotocol/contracts/mixins/GPv2Signing.sol";

import {ComposableCoW} from "composable-cow/ComposableCoW.sol";
import {IConditionalOrder} from "composable-cow/interfaces/IConditionalOrder.sol";

import {PrivateTradeAuthoriser} from "../../src/PrivateTradeAuthoriser.sol";
import {PrivateTradeWrapper} from "../../src/PrivateTradeWrapper.sol";
import {PrivateTradeOrder} from "../../src/PrivateTradeOrder.sol";
import {PrivateTradeLib} from "../../src/libraries/PrivateTradeLib.sol";

import {PrivateTradeBuilder} from "../../src/libraries/PrivateTradeBuilder.sol";
import {PrivateOffer, PrivateTradeTerms, PrivateTradeRole} from "../../src/interfaces/IPrivateTrade.sol";

import {GPv2TradeEncoder} from "../../src/vendor/GPv2TradeEncoder.sol";
import {TestERC20} from "./TestERC20.sol";
import {TestPrivateWallet} from "./TestPrivateWallet.sol";

/// @notice Shared harness: a real settlement contract, a real ComposableCoW, the real wrapper and
/// handler, and three contract wallets standing in for CoW Sheds.
///
/// @dev `IVault` is a plain address on purpose. With `BALANCE_ERC20` on both sides — which the
/// wrapper enforces — `GPv2Transfer` moves tokens with plain `transferFrom`/`transfer` and never
/// touches the vault. Token balances therefore really move in these tests.
abstract contract PrivateTradeTestBase is Test {
  uint256 internal constant USDC_AMOUNT = 100e6;
  uint256 internal constant WBTC_AMOUNT = 5e6; // 0.05 WBTC at 8 decimals
  bytes32 internal constant APP_DATA = keccak256("cow.private.trades.test");

  GPv2AllowListAuthentication internal allowList;
  GPv2Settlement internal settlement;
  ComposableCoW internal cow;
  PrivateTradeAuthoriser internal authoriser;
  PrivateTradeWrapper internal wrapper;
  PrivateTradeOrder internal handler;
  CowWrapperHelpers internal helpers;

  TestERC20 internal usdc;
  TestERC20 internal wbtc;

  TestPrivateWallet internal alice;
  TestPrivateWallet internal bob;
  TestPrivateWallet internal carol;

  address internal aliceOwner = makeAddr("alice-owner");
  address internal bobOwner = makeAddr("bob-owner");
  address internal carolOwner = makeAddr("carol-owner");

  /// @dev Stands in for the BYOS bonded solver: the only account allowed to submit settlements.
  address internal solver = makeAddr("byos-solver");

  address internal relayer;

  function setUp() public virtual {
    allowList = new GPv2AllowListAuthentication();
    allowList.initializeManager(address(this));

    settlement = new GPv2Settlement(allowList, IVault(makeAddr("balancer-vault")));
    relayer = address(settlement.vaultRelayer());

    cow = new ComposableCoW(address(settlement));

    wrapper = new PrivateTradeWrapper(ICowSettlement(address(settlement)));
    authoriser = new PrivateTradeAuthoriser();
    handler = new PrivateTradeOrder(wrapper);
    helpers = new CowWrapperHelpers(ICowAuthentication(address(allowList)));

    allowList.addSolver(address(wrapper));
    allowList.addSolver(solver);

    usdc = new TestERC20("USD Coin", "USDC", 6);
    wbtc = new TestERC20("Wrapped BTC", "WBTC", 8);

    alice = new TestPrivateWallet(cow, aliceOwner);
    bob = new TestPrivateWallet(cow, bobOwner);
    carol = new TestPrivateWallet(cow, carolOwner);
  }

  // --- fixtures

  function _terms(address taker) internal view returns (PrivateTradeTerms memory) {
    return _terms(taker, address(0));
  }

  function _terms(address taker, address allowedTaker) internal view returns (PrivateTradeTerms memory) {
    return _termsFor(address(alice), taker, allowedTaker);
  }

  /// @dev Terms with explicit beneficiaries, for fixtures whose order owners are real Sheds.
  function _termsFull(
    address maker,
    address taker,
    address allowedTaker,
    address makerBeneficiary,
    address takerBeneficiary
  ) internal view returns (PrivateTradeTerms memory terms) {
    terms = _termsFor(maker, taker, allowedTaker);
    terms.makerBeneficiary = makerBeneficiary;
    terms.takerBeneficiary = takerBeneficiary;
  }

  /// @dev Same as `_terms`, but with an arbitrary maker. Used when the order owner is a CoW Shed
  /// rather than a test wallet.
  function _termsFor(address maker, address taker, address allowedTaker)
    internal
    view
    returns (PrivateTradeTerms memory)
  {
    return PrivateTradeTerms({
      offer: PrivateOffer({
        maker: maker,
        allowedTaker: allowedTaker,
        sellToken: address(usdc),
        sellAmount: USDC_AMOUNT,
        buyToken: address(wbtc),
        buyAmount: WBTC_AMOUNT,
        validTo: uint32(block.timestamp + 1 days),
        salt: keccak256(abi.encode("private-trade", maker, taker, allowedTaker))
      }),
      taker: taker,
      makerBeneficiary: _walletOwner(maker),
      takerBeneficiary: _walletOwner(taker)
    });
  }

  /// @dev The wallet a fixture's order owner belongs to. A Shed's admin is not readable from outside
  /// it — the proxy answers `admin()` only to itself — so a caller using real Sheds passes the EOAs
  /// explicitly with `_termsFull`.
  function _walletOwner(address who) internal view returns (address) {
    if (who == address(alice)) return aliceOwner;
    if (who == address(bob)) return bobOwner;
    return who;
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
      handler: IConditionalOrder(address(handler)), salt: keccak256(bytes(salt)), staticInput: abi.encode(role, terms)
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
    trades = _tradesWithAppData(terms, makerParams, takerParams, APP_DATA);
  }

  function _tradesWithAppData(
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
    uint256 buyTokenIndex
  ) internal pure returns (GPv2Trade.Data memory) {
    return _trade(order, params, owner, sellTokenIndex, buyTokenIndex, APP_DATA);
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
    interactions = [new GPv2Interaction.Data[](0), new GPv2Interaction.Data[](0), new GPv2Interaction.Data[](0)];
  }

  /// @dev Delegates to the production builder so the harness cannot drift from it.
  function _wrapperData(PrivateTradeTerms memory terms) internal view returns (bytes memory) {
    return PrivateTradeBuilder.wrapperData(terms, address(wrapper));
  }

  /// @dev The bundle chain for a single private trade wrapper. No next-wrapper address follows,
  /// because the wrapper only runs as the final bundle.
  function _chainedWrapperData(PrivateTradeTerms memory terms) internal view returns (bytes memory) {
    bytes memory data = _wrapperData(terms);
    return abi.encodePacked(uint16(data.length), data);
  }

  /// @dev The exact calldata a solver would send to `GPv2Settlement.settle`.
  function _settleDataWith(
    IERC20[] memory tokens,
    uint256[] memory clearingPrices,
    GPv2Trade.Data[] memory trades,
    GPv2Interaction.Data[][3] memory interactions
  ) internal view returns (bytes memory) {
    return abi.encodeCall(settlement.settle, (tokens, clearingPrices, trades, interactions));
  }

  function _settleData(
    PrivateTradeTerms memory terms,
    IConditionalOrder.ConditionalOrderParams memory makerParams,
    IConditionalOrder.ConditionalOrderParams memory takerParams
  ) internal view returns (bytes memory) {
    return _settleDataWith(_tokens(), _clearingPrices(), _trades(terms, makerParams, takerParams), _emptyInteractions());
  }

  /// @dev Submit the pair through the wrapper, as the bonded solver would.
  function _settle(
    PrivateTradeTerms memory terms,
    IConditionalOrder.ConditionalOrderParams memory makerParams,
    IConditionalOrder.ConditionalOrderParams memory takerParams
  ) internal returns (bytes4 magic) {
    vm.prank(solver);
    magic = wrapper.wrappedSettle(_settleData(terms, makerParams, takerParams), _chainedWrapperData(terms));
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
    makerParams = _authorize(alice, PrivateTradeRole.Maker, terms, "maker");
    takerParams = _authorize(bob, PrivateTradeRole.Taker, terms, "taker");
  }
}
