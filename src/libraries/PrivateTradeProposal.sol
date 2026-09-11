// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {ECDSA} from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';

/// @title PrivateTradeProposal
/// @notice The EIP-712 commitment a BYOS sub-solver signs to submit a private trade.
///
/// @dev BYOS routes auction orderflow through a Trampoline sandbox, under an invariant of "one
/// order, one trampoline call, one sub-solver". A private trade breaks that shape: it has two
/// orders, no external liquidity, and nothing for a Trampoline to do. It therefore needs its own
/// proposal type, and BYOS's own design notes say exactly that — relaxing the invariant is a signed
/// schema change.
///
/// This type follows BYOS's conventions:
///
/// - The domain name is `BYOS`. The version is separately bumped, because the struct differs.
/// - `verifyingContract` is the domain anchor. Here it is the private trade wrapper itself, the
///   contract that verifies the signature on-chain, so signatures are bound to one deployment of
///   one bundle.
/// - There is no `escrowAccount` field. The recovered signer *is* the identity, and BYOS maps it to
///   escrow collateral off-chain. It is emitted on-chain for attribution, again matching BYOS.
/// - `termsHash` is the same idea as BYOS's `interactionsHash`: it stops the operator from running
///   something other than what the sub-solver signed and then blaming it. Without it, BYOS could
///   substitute a pair and debit escrow for the revert.
///
/// @dev Why the commitment is to the pair rather than to the settlement calldata: the proposal
/// travels *inside* the orders' appData, and the settlement calldata contains those orders. Hashing
/// the calldata would therefore be circular. The pair is enough, because the wrapper derives
/// everything else from it — exact amounts, both owners, the pair of tokens, and reciprocity — so
/// no other valid execution of the same pair exists.
///
/// Two deliberate differences from BYOS's routing proposal:
///
/// - **No nonce is enforced on-chain.** BYOS needs one because a proposal can be replayed inside a
///   tradeless settlement. A private trade cannot: both orders are fill-or-kill and the settlement
///   marks them filled, so a replay is already rejected by `GPv2: order filled`. Adding nonce
///   storage would buy nothing.
/// - **`minBuyAmount` / `quoteBuyAmount` are absent.** There is no routing and no slippage: the
///   amounts are exact, and the wrapper rejects anything that is not an exact reciprocal pair.
library PrivateTradeProposal {
    /// @dev `signature` is deliberately excluded from the struct hash so the signed data and the
    /// signature can travel in one value.
    bytes32 internal constant PROPOSAL_TYPEHASH =
        keccak256('PrivateTradeProposal(address wrapper,bytes32 termsHash,uint256 validUntil)');

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)');

    bytes32 internal constant DOMAIN_NAME = keccak256('BYOS');

    /// @dev Bumped relative to BYOS's routing proposals ("0.1"): different struct, different domain.
    bytes32 internal constant DOMAIN_VERSION = keccak256('0.2');

    /// @param wrapper The private trade wrapper expected to execute this pair.
    /// @param termsHash `keccak256(abi.encode(offerId, taker, wrapper))` — the exact pair the
    /// sub-solver approved. The wrapper recomputes it from its own state.
    /// @param validUntil Expiry. The wrapper rejects a stale proposal.
    /// @param signature 65-byte `r || s || v`, or empty to skip on-chain verification.
    struct Proposal {
        address wrapper;
        bytes32 termsHash;
        uint256 validUntil;
        bytes signature;
    }

    /// @notice The commitment the sub-solver signs, recomputable by the wrapper from its own state.
    function termsHash(bytes32 offerId, address taker, address wrapper) internal pure returns (bytes32) {
        return keccak256(abi.encode(offerId, taker, wrapper));
    }

    function domainSeparator(address verifyingContract) internal view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, DOMAIN_NAME, DOMAIN_VERSION, block.chainid, verifyingContract)
        );
    }

    function hashStruct(Proposal memory proposal) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(PROPOSAL_TYPEHASH, proposal.wrapper, proposal.termsHash, proposal.validUntil)
        );
    }

    function digest(Proposal memory proposal, address verifyingContract) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(hex'1901', domainSeparator(verifyingContract), hashStruct(proposal))
        );
    }

    /// @notice Recover the sub-solver. Returns `address(0)` for a malformed signature.
    function recover(Proposal memory proposal, address verifyingContract) internal view returns (address) {
        if (proposal.signature.length != 65) return address(0);
        return ECDSA.recover(digest(proposal, verifyingContract), proposal.signature);
    }

    /// @notice `true` when the proposal carries no signature, meaning on-chain verification is
    /// skipped and only the trade itself is checked.
    function isUnsigned(Proposal memory proposal) internal pure returns (bool) {
        return proposal.signature.length == 0;
    }
}
