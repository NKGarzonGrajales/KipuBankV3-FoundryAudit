                    💰 KipuBankV3


<p align="center"> DeFi smart contract simulating a decentralized banking system with deposits, withdrawals, oracle integration, and hierarchical roles. Built with <strong>Solidity 0.8.24</strong> and deployed on <strong>Sepolia Testnet</strong>. </p>

---

⚙️ General Description

KipuBankV3 is an advanced decentralized banking smart contract allowing ETH and ERC20 deposits/withdrawals, role-based permissions, oracle-based limits, and an internal AMM-style token swap.

---

🧠 Project Objectives

Implement hierarchical roles using AccessControl

Enable ETH & ERC20 deposits and withdrawals

Add internal AMM-style token swapping

Apply ReentrancyGuard + SafeERC20

Verify contract fully using Standard JSON Input

---


## 🧩 Deployment Parameters

| Parameter                | Description                            | Value                                        |
| ------------------------ | -------------------------------------- | -------------------------------------------- |
| `_oracle`                | Chainlink ETH/USD price feed (Sepolia) | `0x694AA1769357215DE4FAC081bf1f309aDC325306` |
| `_bankCapUsedETH`        | Initial USD cap (8 decimals)           | `0`                                          |
| `_initialEthBankCap`     | Global ETH cap                         | `1550000000000000000`                        |
| `_initialEthWithdrawCap` | Max withdrawal per transaction         | `20000000000000000`                          |

---

## ⚙️ Main Functions

| Function                               | Description             |
| -------------------------------------- | ----------------------- |
| `depositETH()`                         | Deposit ETH             |
| `depositToken(address,uint256)`        | Deposit ERC20           |
| `withdrawETH(uint256)`                 | Withdraw ETH            |
| `withdrawToken(address,uint256)`       | Withdraw ERC20          |
| `grantRole(bytes32,address)`           | Assign role             |
| `hasRole(bytes32,address)`             | Check role              |
| `rescueETH(uint256,address)`           | Admin ETH rescue        |
| `rescueERC20(address,uint256,address)` | Admin ERC20 rescue      |
| `swapVaultTokens(...)`                 | Internal AMM-style swap |


## 👥 Accounts and Roles Used

| Type                           | Address                                      | Role / Description |
| ------------------------------ | -------------------------------------------- | ------------------ |
| **Account A (Admin/Deployer)** | `0xEFCD678F3E8Ba831787b6eb41ea8A618674B1dd8` | DEFAULT_ADMIN_ROLE |
| **Account B (Tester)**         | `0xc89edce46B30416268E33fb181616f3f90580d71` | BANK_ADMIN_ROLE    |


---

## 💵 Mock Tokens Used

| Token        | Address                                      | Type / Decimals     |
| ------------ | -------------------------------------------- | ------------------- |
| **MockUSDC** | `0xCF27A9f700835895648EA5EfA6914074557c7b80` | ERC20 (6 decimals)  |
| **MockDAI**  | `0xbBf03149d20B205000c048308CF2d17c2341BfF7` | ERC20 (18 decimals) |


---

🧪 Tests Performed — Summary

| Test                 | Result                                            |
| -------------------- | ------------------------------------------------- |
| `grantRole()`        | BANK_ADMIN_ROLE assigned successfully             |
| `hasRole()`          | `true` for Account B                              |
| ETH & ERC20 Deposits | Confirmed on Etherscan                            |
| Withdrawals          | Executed successfully                             |
| `rescueETH()`        | Success (block 9615136)                           |
| AMM Swap             | DAI → USDC functional, decimals handled correctly |

---

📊 Etherscan Results (On-chain)

totalDepositedPerToken(MockUSDC) → 1000000000000000000

totalDepositedPerToken(MockDAI) → 1000000000000000000

hasRole(BANK_ADMIN_ROLE, B) → true

rescueETH() → Successful (block 9615136)

---

🔄 Internal AMM Swap

Swap tested:

swapVaultTokens(MockDAI, MockUSDC, 1e18, 0)


Results:

DAI → 0

USDC → 5

✔ Decimal handling
✔ Liquidity validated
✔ Reentrancy safe

---

🔗 Verified Contracts

Contract	Network	Address
KipuBankV3	Sepolia	https://sepolia.etherscan.io/address/0x9db4f934df129e959f9f205f3dd5cd8dcbe86a05

MockUSDC	Sepolia	https://sepolia.etherscan.io/address/0xCF27A9f700835895648EA5EfA6914074557c7b80

MockDAI	Sepolia	https://sepolia.etherscan.io/address/0xbBf03149d20B205000c048308CF2d17c2341BfF7

---

🧱 Technical Decisions

AccessControl

ReentrancyGuard

AMM swap logic

Chainlink integration

OZ Contracts 5.x

---

👩‍💻 Author

N.K.G.G. – Full Stack & Blockchain Developer

<p align="center"> <sub>© 2025 N.K.G.G. – KipuBankV3 Developed in Solidity and publicly verified on Etherscan.</sub> </p>


