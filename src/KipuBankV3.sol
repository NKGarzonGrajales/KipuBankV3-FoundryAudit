// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title KipuBankV3
 * @author N.K.G.G.
 * @notice Project for ETH Kipu — Module 4 (Advanced Upgraded Bank/Vault)
 *
 * @dev This version extends KipuBankV2 by incorporating full role-based access
 *      control, multi-token support, Chainlink oracle integration, improved
 *      security patterns, and a more realistic banking architecture.
 *
 * Key features implemented:
 *  - Native ETH and ERC20 deposits/withdrawals (multi-asset vault)
 *  - Role system using OpenZeppelin AccessControl:
 *        • DEFAULT_ADMIN_ROLE (full control)
 *        • BANK_ADMIN_ROLE (operational management)
 *  - Oracle integration (Chainlink ETH/USD price feed)
 *  - Global bank caps and per-transaction withdrawal limits (per token)
 *  - Reentrancy protection via ReentrancyGuard
 *  - Safe token operations using SafeERC20
 *  - Custom errors and detailed events for gas optimization and clear tracking
 *  - Emergency rescue functions for ETH and ERC20 (restricted to admin roles)
 *
 * Learning notes:
 *  - This version was fully tested using two accounts (Admin + Bank Admin)
 *    on Sepolia testnet through Remix IDE and MetaMask.
 *  - The contract was verified publicly on Etherscan using Standard JSON Input.
 *  - Comments have been added intentionally to make each design decision explicit.
 *  - address(0) continues to represent native ETH in all mappings and events.
 */


import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}


contract KipuBankV3 is Ownable, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------- Constants & Types ----------------------

    /// @dev I use the zero-address to represent the native token (ETH) in mappings.
    address public constant NATIVE = address(0);

    /// @dev Most Chainlink ETH/USD feeds return 8 decimals (I keep this constant for clarity).
    uint8 public constant ORACLE_DECIMALS = 8;

    /// @dev Role for administrative operations besides the owner
    bytes32 public constant BANK_ADMIN_ROLE = keccak256("BANK_ADMIN_ROLE");


    // ---------------------- Custom Errors (gas-cheaper than strings) ----------------------

    error ZeroAmount(); // amount must be > 0
    error InvalidToken(address token); // e.g., using address(0) in token funcs
    error InsufficientBalance(address token, uint256 requested, uint256 available);
    error WithdrawLimitExceeded(address token, uint256 requested, uint256 limit);
    error BankCapReached(address token, uint256 attempted, uint256 cap); // exceeds global cap
    error NativeTransferFailed(address to, uint256 amount); // low-level call failed
    error OracleUnavailable(); // price feed not returning a valid price

    error InsufficientLiquidity(address token, uint256 requested, uint256 available); // new

    // ---------------------- Storage: balances and caps ----------------------

    /**
     * @notice Nested balances: user -> token -> amount.
     * @dev For ETH, token = address(0). For ERC20, token = token address.
     */
    mapping(address => mapping(address => uint256)) private balances;

    /// @notice Global TVL per token inside the contract (sum of all users).
    mapping(address => uint256) public totalDepositedPerToken;

    /// @notice Global deposit cap per token (0 = no cap).
    mapping(address => uint256) public bankCapPerToken;

    /// @notice Withdraw cap per tx per token (0 = no cap).
    mapping(address => uint256) public withdrawCapPerToken;

    /**
     * @notice USD cap (8 decimals) for ETH TVL (optional).
     * @dev Example: 100 USD cap = 100 * 1e8. If 0, this check is disabled.
     */
    uint256 public bankCapUsdETH;

    /// @notice Chainlink ETH/USD price feed (Sepolia example: 0x694A...5306).
    AggregatorV3Interface public priceFeed;

    // ---------------------- Events (to see actions in Etherscan) ----------------------

    event Deposited(address indexed user, address indexed token, uint256 amount);
    event Withdrawn(address indexed user, address indexed token, uint256 amount);

        // swap event added
        event Swapped(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );   

    event CapsUpdated(address indexed token, uint256 bankCap, uint256 withdrawCap);
    event OracleUpdated(address indexed oracle);
    event BankCapUsdEthUpdated(uint256 newCapUsd8d);

    // ---------------------- Constructor ----------------------

    /**
     * @param _oracle Chainlink ETH/USD aggregator address (8 decimals usually)
     * @param _bankCapUsdETH USD cap for ETH TVL (8 decimals). 0 = disabled.
     * @param _initialEthBankCap Global cap for ETH in wei (0 = disabled).
     * @param _initialEthWithdrawCap Per-tx withdraw cap for ETH in wei (0 = disabled).
     *
     * I keep the owner model simple (Ownable). Only the owner can change caps/oracle.
     */
    constructor(
        address _oracle,
        uint256 _bankCapUsdETH,
        uint256 _initialEthBankCap,
        uint256 _initialEthWithdrawCap
    ) Ownable(msg.sender) {
        priceFeed = AggregatorV3Interface(_oracle);
        bankCapUsdETH = _bankCapUsdETH;

        if (_initialEthBankCap > 0) bankCapPerToken[NATIVE] = _initialEthBankCap;
        if (_initialEthWithdrawCap > 0) withdrawCapPerToken[NATIVE] = _initialEthWithdrawCap;

        emit OracleUpdated(_oracle);
        emit BankCapUsdEthUpdated(_bankCapUsdETH);
        emit CapsUpdated(NATIVE, bankCapPerToken[NATIVE], withdrawCapPerToken[NATIVE]);

        // Admin Global AccessControl (0x00) -> who can grant/revoke roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        // Assign BANK_ADMIN_ROLE to the deployer (same as the owner)
        _grantRole(BANK_ADMIN_ROLE, msg.sender);
    }

    // ---------------------- Views (read-only helpers) ----------------------

    /**
     * @notice See any user balance for a given token.
     * @param user Address to query (can be msg.sender or someone else).
     * @param token address(0) for ETH; ERC-20 address for tokens.
     */
    function viewBalance(address user, address token) external view returns (uint256) {
        return balances[user][token];
    }

    /**
     * @notice Latest ETH/USD price (8 decimals). Reverts if not available.
     * @dev I use this to compute a USD-based cap for ETH TVL.
     */
    function getETHPriceUSD_8d() public view returns (uint256) {
        (, int256 price,, uint256 updatedAt, ) = priceFeed.latestRoundData();
        if (price <= 0 || updatedAt == 0) revert OracleUnavailable();
        return uint256(price);
    }

    /**
     * @notice Normalize amounts across different token decimals.
     * @dev Example: from 18 (ETH/DAI) to 6 (USDC). Handy for accounting if needed.
     */
    function normalizeDecimals(
        uint256 amount,
        uint8 fromDecimals,
        uint8 toDecimals
    ) public pure returns (uint256) {
        if (fromDecimals == toDecimals) return amount;
        if (fromDecimals > toDecimals) {
            return amount / 10 ** (fromDecimals - toDecimals);
        } else {
            return amount * 10 ** (toDecimals - fromDecimals);
        }
    }

    // ---------------------- ETH (native) deposit/withdraw ----------------------

    /**
     * @notice Deposit native ETH into your vault.
     * @dev CEI: 1) checks caps, 2) update storage, 3) emit event.
     *      Also enforces optional ETH TVL cap in USD using Chainlink.
     */
    function depositETH() external payable nonReentrant {
        uint256 amount = msg.value;
        if (amount == 0) revert ZeroAmount();

        // 1) CHECKS — per-token native cap (in wei), if set
        uint256 ethCapWei = bankCapPerToken[NATIVE];
        if (ethCapWei > 0) {
            uint256 newTotal = totalDepositedPerToken[NATIVE] + amount;
            if (newTotal > ethCapWei) revert BankCapReached(NATIVE, newTotal, ethCapWei);
        }

        // 2) CHECKS — USD cap for ETH TVL (if enabled)
        if (bankCapUsdETH > 0) {
            uint256 price8d = getETHPriceUSD_8d();                 // USD * 1e8
            uint256 currentUsd8d = (totalDepositedPerToken[NATIVE] * price8d) / 1e18;
            uint256 incomingUsd8d = (amount * price8d) / 1e18;
            if (currentUsd8d + incomingUsd8d > bankCapUsdETH) {
                revert BankCapReached(NATIVE, currentUsd8d + incomingUsd8d, bankCapUsdETH);
            }
        }

        // 3) EFFECTS
        balances[msg.sender][NATIVE] += amount;
        totalDepositedPerToken[NATIVE] += amount;

        // 4) INTERACTION (only event here)
        emit Deposited(msg.sender, NATIVE, amount);
    }

    /**
     * @notice Withdraw native ETH from your vault.
     * @dev CEI: validate caps and balance, update storage, then transfer ETH.
     */
    function withdrawETH(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        uint256 cap = withdrawCapPerToken[NATIVE];
        if (cap > 0 && amount > cap) revert WithdrawLimitExceeded(NATIVE, amount, cap);

        uint256 bal = balances[msg.sender][NATIVE];
        if (bal < amount) revert InsufficientBalance(NATIVE, amount, bal);

        // EFFECTS
        balances[msg.sender][NATIVE] = bal - amount;
        totalDepositedPerToken[NATIVE] -= amount;

        // INTERACTION — low-level call wrapped in helper + event
        _safeTransferETH(msg.sender, amount);
        emit Withdrawn(msg.sender, NATIVE, amount);
    }

    /**
     * @notice Receive ETH sent directly (no data). I treat it as a deposit.
     * @dev I replicate the same cap checks as depositETH() to keep behavior consistent.
     */
    receive() external payable {
        uint256 amount = msg.value;
        if (amount == 0) revert ZeroAmount();

        uint256 ethCapWei = bankCapPerToken[NATIVE];
        if (ethCapWei > 0) {
            uint256 newTotal = totalDepositedPerToken[NATIVE] + amount;
            if (newTotal > ethCapWei) revert BankCapReached(NATIVE, newTotal, ethCapWei);
        }
        if (bankCapUsdETH > 0) {
            uint256 price8d = getETHPriceUSD_8d();
            uint256 currentUsd8d = (totalDepositedPerToken[NATIVE] * price8d) / 1e18;
            uint256 incomingUsd8d = (amount * price8d) / 1e18;
            if (currentUsd8d + incomingUsd8d > bankCapUsdETH) {
                revert BankCapReached(NATIVE, currentUsd8d + incomingUsd8d, bankCapUsdETH);
            }
        }

        balances[msg.sender][NATIVE] += amount;
        totalDepositedPerToken[NATIVE] += amount;
        emit Deposited(msg.sender, NATIVE, amount);
    }

    // ---------------------- ERC-20 deposit/withdraw ----------------------

    /**
     * @notice Deposit an ERC-20 token (after approving this contract).
     * @dev I enforce bank cap per token (if configured). SafeERC20 handles non-standard tokens.
     */
    function depositToken(address token, uint256 amount) external nonReentrant {
        if (token == NATIVE) revert InvalidToken(token);
        if (amount == 0) revert ZeroAmount();

        uint256 cap = bankCapPerToken[token];
        if (cap > 0) {
            uint256 newTotal = totalDepositedPerToken[token] + amount;
            if (newTotal > cap) revert BankCapReached(token, newTotal, cap);
        }

        // CEI: transfer first? I prefer updating after transferFrom succeeds (safer if it reverts).
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        balances[msg.sender][token] += amount;
        totalDepositedPerToken[token] += amount;

        emit Deposited(msg.sender, token, amount);
    }

    /**
     * @notice Withdraw an ERC-20 token you deposited.
     * @dev Enforces per-tx withdraw cap if set and checks your balance.
     */
    function withdrawToken(address token, uint256 amount) external nonReentrant {
        if (token == NATIVE) revert InvalidToken(token);
        if (amount == 0) revert ZeroAmount();

        uint256 cap = withdrawCapPerToken[token];
        if (cap > 0 && amount > cap) revert WithdrawLimitExceeded(token, amount, cap);

        uint256 bal = balances[msg.sender][token];
        if (bal < amount) revert InsufficientBalance(token, amount, bal);

        // EFFECTS
        balances[msg.sender][token] = bal - amount;
        totalDepositedPerToken[token] -= amount;

        // INTERACTION
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, token, amount);
    }

        // ---------------------- Simple internal swap (ERC-20 <-> ERC-20) swap function type uniswap----------------------

    /**
     * @notice Swap between two ERC-20 tokens held inside the vault (e.g. MockDAI <-> MockUSDC).
     * @dev
     *  - Uses internal vault balances instead of external transfers.
     *  - Normalizes token decimals so stablecoins can be swapped 1:1.
     *  - Checks that the bank has enough liquidity in the output token.
     *  - Adds optional slippage control via `minAmountOut`.
     *
     * This is a simplified AMM-style swap, enough to demonstrate Uniswap-like
     * behaviour for the module requirements without implementing the full x*y=k curve.
     */
    function swapVaultTokens(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) external nonReentrant {
        if (tokenIn == tokenOut) revert InvalidToken(tokenIn);
        if (tokenIn == NATIVE || tokenOut == NATIVE) {
            // For this module we focus on ERC-20 <-> ERC-20 swaps (MockDAI, MockUSDC, etc.)
            revert InvalidToken(NATIVE);
        }
        if (amountIn == 0) revert ZeroAmount();

        // 1) CHECK: user balance in tokenIn
        uint256 userBalIn = balances[msg.sender][tokenIn];
        if (userBalIn < amountIn) {
            revert InsufficientBalance(tokenIn, amountIn, userBalIn);
        }

        // 2) COMPUTE: normalize amountIn to tokenOut decimals (1:1 rate, stablecoin style)
        uint8 decimalsIn = IERC20Metadata(tokenIn).decimals();
        uint8 decimalsOut = IERC20Metadata(tokenOut).decimals();

        uint256 amountOut = normalizeDecimals(amountIn, decimalsIn, decimalsOut);

        // Optional slippage protection (even if rate is 1:1, it is good practice)
        if (amountOut < minAmountOut) {
            revert InsufficientLiquidity(tokenOut, minAmountOut, amountOut);
        }

        // 3) CHECK: bank liquidity in tokenOut (uses the same TVL mapping)
        uint256 bankLiquidityOut = totalDepositedPerToken[tokenOut];
        if (bankLiquidityOut < amountOut) {
            revert InsufficientLiquidity(tokenOut, amountOut, bankLiquidityOut);
        }

        // 4) EFFECTS — internal accounting only, no external transfers
        balances[msg.sender][tokenIn] = userBalIn - amountIn;
        balances[msg.sender][tokenOut] += amountOut;

        totalDepositedPerToken[tokenIn] -= amountIn;
        totalDepositedPerToken[tokenOut] = bankLiquidityOut - amountOut;

        // 5) EVENT for traceability in Etherscan
        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }


    // ---------------------- Owner (admin) configuration ----------------------

    /**
     * @notice Set global bank cap and per-tx withdraw cap for a token (token=address(0) is ETH).
     * @dev Only owner (bank admin) can call this.
     */
    function setCapsForToken(address token, uint256 bankCap, uint256 withdrawCap) external onlyOwnerOrAdmin {
        bankCapPerToken[token] = bankCap;
        withdrawCapPerToken[token] = withdrawCap;
        emit CapsUpdated(token, bankCap, withdrawCap);
    }

    /**
     * @notice Update the Chainlink oracle (in case of feed migration).
     */
    function setOracle(address newOracle) external onlyOwnerOrAdmin {
        if (newOracle == address(0)) revert InvalidToken(newOracle);
        priceFeed = AggregatorV3Interface(newOracle);
        emit OracleUpdated(newOracle);
    }

    /**
     * @notice Set or update the USD cap (8 decimals) for ETH TVL. 0 disables it.
     */
    function setBankCapUsdETH(uint256 newCapUsd8d) external onlyOwnerOrAdmin {
        bankCapUsdETH = newCapUsd8d;
        emit BankCapUsdEthUpdated(newCapUsd8d);
    }

    /**
     * @notice Rescue ERC-20 tokens accidentally sent (admin only).
     * @dev This is not meant to withdraw user balances; use with caution.
     */
    function rescueERC20(address token, uint256 amount, address to) external onlyOwnerOrAdmin {
        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Rescue native ETH accidentally sent (admin only).
     */
    function rescueETH(uint256 amount, address to) external onlyOwnerOrAdmin {
        _safeTransferETH(to, amount);
    }

    // ---------------------- Internal helper ----------------------

    /// @dev Private ETH transfer helper using low-level call (more reliable than transfer()).
    function _safeTransferETH(address to, uint256 amount) private {
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) revert NativeTransferFailed(to, amount);
    }

        // ---------------------- Access modifier ----------------------
    /**
     * @dev Allows execution if the caller is either the owner or has BANK_ADMIN_ROLE.
     */
    modifier onlyOwnerOrAdmin() {
        require(
            owner() == msg.sender || hasRole(BANK_ADMIN_ROLE, msg.sender),
            "Access denied: must be owner or bank admin"
        );
        _;
    }

}