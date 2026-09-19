# CAPdropper 🪂👑

Multi-tenant, game-ready ERC-20 airdrop vault gated by the **Midas Gate Registry** on Base.

Built for **Pump It Dry**, **CAPSTILLER games**, and independent creators.

---

## 🏛️ Core Architecture

CAPdropper allows any game or player to sponsor and lock an ERC-20 token airdrop (e.g. `$CAP`, `$BNKR`, `$USDC`) that is distributed **evenly across all holders of every active ERC-721 collection in the Midas Gate**.

### 🔑 Security & Invariants
1. **Gate Snapshotting**: Drops query `getAllERC721Gates()` on `0x54C3C8C9E2180c6b90652983d1c15cF933f1a263` at drop creation time. Active collections are snapshotted permanently into that `dropId`. Future changes to the gate registry never corrupt existing drops.
2. **Per-Token-ID Claim Lock**: Claiming is tracked strictly per `(dropId, collectionAddress, tokenId)`. The caller must be the verified on-chain `ownerOf(tokenId)`. Once claimed, that specific NFT cannot double-dip even if transferred or traded.
3. **Fee-on-Transfer Protection**: Measures contract balance before and after `transferFrom` so tokens with burn/tax mechanics never brick remaining claimers.
4. **Pull-Over-Push Expiration**: When a drop's duration expires, `finalizeDrop(dropId)` splits remaining unclaimed tokens:
   - **90%** refunded to the original drop creator.
   - **10%** allocated to the designated treasury.
   Funds are credited to `pendingBalances` so creator and treasury pull independently via `withdrawPending()`. A reverting or blacklisted address can never lock the other party's funds.
5. **Batch Claiming**: Supports claiming across multiple collections and token IDs in a single gas-efficient transaction.

---

## 📜 Key Contracts

| Contract | Network | Address | Description |
|---|---|---|---|
| **Midas Gate Registry** | Base | `0x54C3C8C9E2180c6b90652983d1c15cF933f1a263` | Authoritative Midas Gate registry with 10 matrix light sockets & admin keys |
| **Active Midas Collection** | Base | `0x23D9c8259A672b9F32Ba862cA6ed6B860575a661` | Primary active gate collection in Midas Gate |
| **CAPdropper Vault** | Base | *(Deploying via CREATE2 / Factory)* | Master airdrop & escrow vault |

---

## 🕹️ Game Integration (e.g. Pump It Dry)

1. Player bets / offers 10,000 CAPs for 10,000 shots.
2. On completion, player approves CAPdropper contract for 10,000 CAPs.
3. Client triggers `fundDropWithMidasGate(token, amount, totalEligibleNFTs, durationSeconds, treasury)`.
4. All eligible NFT holders in the Midas Gate can claim their equal share from the game portal.
5. After duration expires (e.g. 7 days), 90% of unclaimed CAPs revert to the player, and 10% goes to the treasury.
