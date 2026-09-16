// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {TestERC20} from "./TestERC20.sol";

/// @title BehaviourTokens
/// @notice Tokens that behave like real ones do in ways a plain `TestERC20` does not.
///
/// @dev Every test that relies on a token behaving a particular way needs the token's behaviour pinned
/// by its own test first, or the test above it can pass for the wrong reason — a fixture that silently
/// behaves like a normal token makes every assertion built on it vacuous. Each of these has a test in
/// `test/PrivateTradeTokens.t.sol` that asserts the behaviour it exists for.

/// @notice A token that keeps a cut of every transfer, the way fee-on-transfer tokens do.
///
/// @dev The sender pays the full `amount` and the recipient is credited less; the difference goes to a
/// sink. Minting is exempt, so funding a fixture with this token means what it says.
contract FeeOnTransferToken is TestERC20 {
  uint256 public constant FEE_BPS = 500; // 5%
  address public immutable sink;

  constructor(address sink_) TestERC20("Fee Token", "FEE", 18) {
    sink = sink_;
  }

  /// @dev `_transfer` and not `_mint`: minting a fixture is not a trade, so funding one means what it
  /// says. Only a real transfer between two holders takes the cut.
  function _transfer(address from, address to, uint256 value) internal override {
    uint256 fee = (value * FEE_BPS) / 10_000;
    super._transfer(from, sink, fee);
    super._transfer(from, to, value - fee);
  }
}

/// @notice A token whose `transfer` and `transferFrom` return **nothing**, the way USDT does.
///
/// @dev This cannot inherit `ERC20`: OpenZeppelin declares `returns (bool)`, and a token with no return
/// value has a different ABI for the same selector. Callers that read the value get empty return data,
/// which is the case `GPv2SafeERC20` has to accept.
contract NoReturnToken {
  string public name = "No Return";
  string public symbol = "NORET";
  uint8 public decimals = 6;

  uint256 public totalSupply;
  mapping(address => uint256) public balanceOf;
  mapping(address => mapping(address => uint256)) public allowance;

  event Transfer(address indexed from, address indexed to, uint256 value);
  event Approval(address indexed owner, address indexed spender, uint256 value);

  function mint(address to, uint256 amount) external {
    totalSupply += amount;
    balanceOf[to] += amount;
    emit Transfer(address(0), to, amount);
  }

  function approve(address spender, uint256 amount) external returns (bool) {
    allowance[msg.sender][spender] = amount;
    emit Approval(msg.sender, spender, amount);
    return true;
  }

  // solhint-disable-next-line no-unused-vars
  function transfer(address to, uint256 amount) external {
    _move(msg.sender, to, amount);
  }

  function transferFrom(address from, address to, uint256 amount) external {
    require(allowance[from][msg.sender] >= amount, "NORET: allowance");
    allowance[from][msg.sender] -= amount;
    _move(from, to, amount);
  }

  function _move(address from, address to, uint256 amount) internal {
    require(balanceOf[from] >= amount, "NORET: balance");
    balanceOf[from] -= amount;
    balanceOf[to] += amount;
    emit Transfer(from, to, amount);
  }
}

/// @notice A token that reports failure by returning `false` instead of reverting.
///
/// @dev ERC-20 allows this and nothing in a settlement may treat it as success, or a settlement that
/// moved nothing is booked as one that did.
contract FalseReturnToken is TestERC20 {
  bool public refuse;

  constructor() TestERC20("False Return", "FALSE", 18) {}

  function setRefuse(bool refuse_) external {
    refuse = refuse_;
  }

  function transfer(address to, uint256 amount) public override returns (bool) {
    if (refuse) return false;
    return super.transfer(to, amount);
  }

  function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
    if (refuse) return false;
    return super.transferFrom(from, to, amount);
  }
}

/// @notice A token that refuses a non-zero to non-zero approval, the way USDT does.
///
/// @dev The approval has to be reset to zero before a new one. A flow that approves a fresh amount on
/// top of a standing allowance reverts against this, so a design that depends on the allowance being
/// consumed to zero depends on it silently.
contract ResetApprovalToken is TestERC20 {
  error ResetApprovalToken_ResetRequired();

  constructor() TestERC20("Reset Approval", "RESET", 6) {}

  function approve(address spender, uint256 amount) public override returns (bool) {
    uint256 current = allowance(msg.sender, spender);
    if (current != 0 && amount != 0) revert ResetApprovalToken_ResetRequired();
    return super.approve(spender, amount);
  }
}
