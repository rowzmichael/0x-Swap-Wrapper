// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ZeroExSwapWrapper
 * @author Idowu Badejo
 * @notice A minimal wrapper around the 0x Settler/AllowanceHolder swap infrastructure.
 *
 * @dev This contract demonstrates how to integrate 0x Swap API v2 at the contract
 * level. The core pattern is:
 *
 *   1. The caller pre-approves this wrapper for the sell token.
 *   2. The wrapper pulls the sell token from the caller.
 *   3. The wrapper approves the 0x AllowanceHolder and forwards the swap calldata.
 *   4. The wrapper verifies that the caller receives at least minBuyAmount of the
 *      buy token, reverting if slippage exceeds the caller's tolerance.
 *   5. Any surplus buy tokens remain with the caller; no funds are held by this
 *      contract after a successful swap.
 *
 * This contract is not intended for production use without a full security review.
 * It is a portfolio demonstration of 0x integration patterns, ERC-20 approval flows,
 * slippage protection, and event-driven accounting.
 *
 * @custom:security-contact idowu@example.com
 */
contract ZeroExSwapWrapper is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Immutables ────────────────────────────────────────────────────────────

    /**
     * @notice The 0x AllowanceHolder contract address.
     * @dev This is the contract that must receive token approvals when using the
     * /swap/allowance-holder endpoint. Never approve the Settler contract directly.
     * On Ethereum mainnet: 0x0000000000001ff3684f28c67538d4d072c22734
     */
    address public immutable allowanceHolder;

    // ─── Events ────────────────────────────────────────────────────────────────

    /**
     * @notice Emitted after a swap executes successfully.
     * @param caller         Address that initiated the swap.
     * @param sellToken      ERC-20 token sold.
     * @param buyToken       ERC-20 token received.
     * @param sellAmount     Exact amount of sellToken transferred in.
     * @param buyAmountOut   Actual amount of buyToken received by the caller.
     */
    event SwapExecuted(
        address indexed caller,
        address indexed sellToken,
        address indexed buyToken,
        uint256 sellAmount,
        uint256 buyAmountOut
    );

    // ─── Errors ────────────────────────────────────────────────────────────────

    /// @notice Reverts when the received buy amount falls below the caller's minimum.
    error SlippageExceeded(uint256 received, uint256 minimum);

    /// @notice Reverts when swapCalldata is empty.
    error EmptyCalldata();

    /// @notice Reverts when the swap call to the 0x Settler contract fails.
    error SwapCallFailed(bytes returnData);

    // ─── Constructor ───────────────────────────────────────────────────────────

    /**
     * @param _allowanceHolder The 0x AllowanceHolder address for the target chain.
     * @dev Set this per-chain using the address returned by the 0x API's
     * `issues.allowance.spender` field. On Ethereum mainnet this is
     * 0x0000000000001ff3684f28c67538d4d072c22734.
     */
    constructor(address _allowanceHolder) {
        require(_allowanceHolder != address(0), "ZeroExSwapWrapper: zero address");
        allowanceHolder = _allowanceHolder;
    }

    // ─── External functions ────────────────────────────────────────────────────

    /**
     * @notice Executes a token swap through 0x Swap API v2 (AllowanceHolder path).
     *
     * @dev Call flow:
     *   1. Pull `sellAmount` of `sellToken` from msg.sender into this contract.
     *   2. Approve AllowanceHolder to spend the sell amount.
     *   3. Forward `swapTarget` + `swapCalldata` — this is the `transaction.to`
     *      and `transaction.data` from the 0x quote response.
     *   4. Measure the caller's buy token balance before and after. The delta is
     *      the actual buy amount.
     *   5. Revert if delta < minBuyAmount (slippage check).
     *   6. Reset any lingering AllowanceHolder approval to zero.
     *
     * @param sellToken     ERC-20 token the caller wants to sell.
     * @param buyToken      ERC-20 token the caller wants to receive.
     * @param sellAmount    Amount of sellToken to sell (in token base units).
     * @param minBuyAmount  Minimum acceptable amount of buyToken (slippage protection).
     *                      Source from the 0x API's `minBuyAmount` field.
     * @param swapTarget    The contract to call with swapCalldata. This is
     *                      `transaction.to` from the 0x quote response (the Settler).
     * @param swapCalldata  Encoded swap calldata. This is `transaction.data` from
     *                      the 0x quote response.
     *
     * @return buyAmountOut Actual amount of buyToken received.
     */
    function swap(
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        uint256 minBuyAmount,
        address swapTarget,
        bytes calldata swapCalldata
    ) external nonReentrant returns (uint256 buyAmountOut) {
        if (swapCalldata.length == 0) revert EmptyCalldata();

        IERC20 sell = IERC20(sellToken);
        IERC20 buy  = IERC20(buyToken);

        // Step 1: Pull sell tokens from caller into this contract.
        sell.safeTransferFrom(msg.sender, address(this), sellAmount);

        // Step 2: Approve the AllowanceHolder (not the Settler) for the sell amount.
        // Reset to zero first to handle tokens like USDT that require it.
        sell.forceApprove(allowanceHolder, 0);
        sell.forceApprove(allowanceHolder, sellAmount);

        // Step 3: Snapshot caller's buy token balance before the swap.
        uint256 buyBalanceBefore = buy.balanceOf(msg.sender);

        // Step 4: Forward the call to the 0x Settler (swapTarget).
        // The Settler pulls sell tokens via AllowanceHolder and routes the swap.
        // The Settler sends buy tokens directly to the `taker` address encoded in
        // swapCalldata, which must be msg.sender (set via the `taker` param in
        // the 0x API request).
        (bool success, bytes memory returnData) = swapTarget.call(swapCalldata);
        if (!success) revert SwapCallFailed(returnData);

        // Step 5: Measure actual buy amount received.
        uint256 buyBalanceAfter = buy.balanceOf(msg.sender);
        buyAmountOut = buyBalanceAfter - buyBalanceBefore;

        // Step 6: Slippage check. Revert if the received amount is below the minimum.
        if (buyAmountOut < minBuyAmount) {
            revert SlippageExceeded(buyAmountOut, minBuyAmount);
        }

        // Step 7: Revoke the AllowanceHolder approval. Any unused sell amount
        // should not persist as an allowance.
        sell.forceApprove(allowanceHolder, 0);

        // Step 8: If the Settler sent any surplus sell tokens back to this contract
        // rather than to the caller, return them.
        uint256 sellRemainder = sell.balanceOf(address(this));
        if (sellRemainder > 0) {
            sell.safeTransfer(msg.sender, sellRemainder);
        }

        emit SwapExecuted(
            msg.sender,
            sellToken,
            buyToken,
            sellAmount,
            buyAmountOut
        );
    }

    // ─── View functions ────────────────────────────────────────────────────────

    /**
     * @notice Returns the AllowanceHolder address this wrapper is configured for.
     * @dev Useful for front-end clients that need to prompt the user to approve
     * the correct contract before calling swap().
     */
    function getAllowanceTarget() external view returns (address) {
        return allowanceHolder;
    }

    // ─── Safety ────────────────────────────────────────────────────────────────

    /**
     * @dev This contract is not designed to hold any ERC-20 balances between
     * transactions. Any tokens sent directly to this address are not recoverable
     * through the swap() function and should be considered lost.
     *
     * Do not transfer tokens to this contract address directly.
     */
    receive() external payable {
        revert("ZeroExSwapWrapper: does not accept ETH");
    }
}
