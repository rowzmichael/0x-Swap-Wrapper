# 0x-Swap-Wrapper

A minimal Solidity contract that wraps the 0x Swap API v2 (AllowanceHolder path) to execute
ERC-20 token swaps with slippage protection, clean approval handling, and on-chain accounting.

Built as a portfolio demonstration of 0x protocol integration patterns. Not audited or intended for production use without a full security review.

---

## What This Is

The 0x Swap API aggregates liquidity from 150+ DEXs and market makers and returns a calldata
payload ready to submit to the 0x Settler contract. The tricky parts of integrating it at
the contract level are:

- Token approvals must go to the **AllowanceHolder**, not the Settler. Approving the Settler
  directly can result in lost tokens.
- The API's `minBuyAmount` field should be enforced on-chain, not just trusted off-chain.
- Any lingering approvals should be cleaned up after execution.
- Surplus sell tokens returned by the Settler should be forwarded to the caller, not left
  in the wrapper.

This contract handles all of that. The caller approves this wrapper for the sell token,
calls `swap()` with the data from the 0x API quote, and receives the buy token directly.

---

## Contract: `ZeroExSwapWrapper.sol`

```
contracts/
└── ZeroExSwapWrapper.sol
```

### Key design decisions

**Immutable AllowanceHolder address.** The AllowanceHolder address is set at deploy time
and cannot be changed. This removes any admin vector that could redirect approvals to a
malicious contract.

**Balance delta accounting.** Rather than trusting the Settler's return value (which can
vary by integration path), the contract measures the caller's buy token balance before and
after the swap. The delta is the actual received amount. This is more robust across different
Settler versions and routing paths.

**Approval reset before and after.** `forceApprove(0)` runs before setting the approval
(to handle USDT-style tokens that reject non-zero-to-non-zero approvals) and again after
the swap to revoke any unused allowance.

**NonReentrant.** All external state changes use OpenZeppelin's `ReentrancyGuard`. The
swap call to the Settler is an external call on an arbitrary address, which warrants this
protection even though the Settler itself is trusted.

**ETH rejected.** The contract has no payable logic and reverts on any ETH transfer. This
prevents accidental ETH locks.

---

## How to Use It

### 1. Deploy

Deploy `ZeroExSwapWrapper` with the correct `AllowanceHolder` address for your target chain.

| Chain    | AllowanceHolder address                        |
|----------|------------------------------------------------|
| Ethereum | `0x0000000000001ff3684f28c67538d4d072c22734`   |
| Base     | `0x0000000000001ff3684f28c67538d4d072c22734`   |
| Arbitrum | `0x0000000000001ff3684f28c67538d4d072c22734`   |
| Polygon  | `0x0000000000001ff3684f28c67538d4d072c22734`   |

The AllowanceHolder address is the same across all supported EVM chains.

### 2. Fetch a quote from the 0x API

```bash
curl "https://api.0x.org/swap/allowance-holder/quote?\
chainId=1&\
sellToken=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2&\
buyToken=0x6B175474E89094C44Da98b954EedeAC495271d0F&\
sellAmount=1000000000000000000&\
taker=YOUR_CALLER_ADDRESS" \
-H "0x-api-key: YOUR_API_KEY" \
-H "0x-version: v2"
```

From the response you need:
- `transaction.to` → your `swapTarget`
- `transaction.data` → your `swapCalldata`
- `minBuyAmount` → your `minBuyAmount` (after applying your own slippage tolerance on top)

### 3. Approve this wrapper for the sell token

The **caller** (not this contract) must approve `ZeroExSwapWrapper` to spend the sell token.

```solidity
IERC20(sellToken).approve(address(swapWrapper), sellAmount);
```

### 4. Call `swap()`

```solidity
uint256 received = swapWrapper.swap(
    sellToken,    // e.g. WETH address
    buyToken,     // e.g. DAI address
    sellAmount,   // e.g. 1e18 (1 WETH)
    minBuyAmount, // from 0x API response, adjusted for your slippage tolerance
    swapTarget,   // transaction.to from API response
    swapCalldata  // transaction.data from API response
);
```

The buy tokens arrive directly in `msg.sender`'s wallet. No claiming step.

---

## Interface

```solidity
function swap(
    address sellToken,
    address buyToken,
    uint256 sellAmount,
    uint256 minBuyAmount,
    address swapTarget,
    bytes calldata swapCalldata
) external returns (uint256 buyAmountOut);

function getAllowanceTarget() external view returns (address);
```

### Events

```solidity
event SwapExecuted(
    address indexed caller,
    address indexed sellToken,
    address indexed buyToken,
    uint256 sellAmount,
    uint256 buyAmountOut
);
```

### Errors

```solidity
error SlippageExceeded(uint256 received, uint256 minimum);
error EmptyCalldata();
error SwapCallFailed(bytes returnData);
```

---

## Development Setup

### Requirements

- [Foundry](https://getfoundry.sh/) (forge, cast, anvil)
- Node.js 18+ (for API scripts)

### Install

```bash
git clone https://github.com/idowubadejo/zerox-swap-wrapper
cd zerox-swap-wrapper
forge install
```

### Build

```bash
forge build
```

### Test

Tests run against a local Anvil fork of Ethereum mainnet. You need an RPC URL.

```bash
cp .env.example .env
# Add your RPC_URL_MAINNET to .env

forge test --fork-url $RPC_URL_MAINNET -vv
```

The test suite covers:
- Successful WETH → DAI swap using a live 0x quote
- Revert on slippage exceeding `minBuyAmount`
- Revert on empty calldata
- Approval cleanup: AllowanceHolder allowance is zero after any swap
- Surplus sell token forwarding

---

## Security Notes

**This contract is unaudited.** The core 0x infrastructure (AllowanceHolder, Settler) is
audited and battle-tested, but this wrapper has not been reviewed by a third party.

Key risks to understand before any production use:

**swapTarget is arbitrary.** This contract forwards calldata to whichever `swapTarget`
address the caller provides. On-chain, there is no verification that `swapTarget` is
actually a 0x Settler contract. The caller is responsible for ensuring they pass the
correct address from the 0x API response. A malicious or incorrect `swapTarget` could
drain tokens that were pulled into this contract.

**taker must be the caller.** The 0x API encodes the `taker` address into `swapCalldata`.
If the taker is set to anything other than `msg.sender`, the buy tokens will go to a
different address and the balance delta check will revert. Always set `taker` to the
address calling `swap()` when fetching the quote.

**No ETH swap support.** This wrapper handles ERC-20 to ERC-20 swaps only. ETH/WETH swaps
require additional handling that is not implemented here.

---

## Dependencies

- [OpenZeppelin Contracts v5](https://github.com/OpenZeppelin/openzeppelin-contracts)
  - `IERC20`, `SafeERC20` (forceApprove), `ReentrancyGuard`

---

## References

- [0x Swap API v2 Docs](https://0x.org/docs/0x-swap-api/introduction)
- [0x Cheat Sheet](https://0x.org/docs/introduction/0x-cheat-sheet)
- [AllowanceHolder vs Permit2](https://0x.org/docs/0x-swap-api/guides/swap-tokens-with-0x-swap-api)
- [0x GitHub](https://github.com/0xProject)

## License

MIT
