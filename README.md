# CAPdropper 🪂👑

Multi-tenant, game-ready ERC-20 airdrop vault gated by the **Midas Gate Registry** on Base.

Built for **Pump It Dry**, **CAPSTILLER games**, and independent creators.

---

## 🏛️ Core Architecture

CAPdropper allows any game or player to sponsor and lock an ERC-20 token airdrop (e.g. `$CAP`, `$BNKR`, `$USDC`) that is distributed **evenly across all holders of every active ERC-721 collection in the Midas Gate**.

### 🔑 Security & Invariants
1. **Gate Snapshotting**: Drops query `getAllERC721Gates()` on `0x54C3C8C9E2180c6b90652983d1c15cF933f1a263` at drop creation time. Active collections are snapshotted permanently into that `dropId`. Future changes to the gate registry never corrupt existing drops.
2. **Automated Supply Counting**: Distribution split is automatically calculated by scanning all minted token IDs across active gate collections (e.g. 8,888 minted tokens for King Midas) with zero manual guesswork.
3. **Per-Token-ID Claim Lock**: Claiming is tracked strictly per `(dropId, collectionAddress, tokenId)`. The caller must be the verified on-chain `ownerOf(tokenId)`. Once claimed, that specific NFT cannot double-dip even if transferred or traded.
4. **Fee-on-Transfer Protection**: Measures contract balance before and after `transferFrom` so tokens with burn/tax mechanics never brick remaining claimers.
5. **Pull-Over-Push Expiration**: When a drop's duration expires, `finalizeDrop(dropId)` splits remaining unclaimed tokens:
   - **90%** refunded to the original drop creator.
   - **10%** allocated to the protocol treasury (`0xA12506f742F4AB0980a57264871DB56A1A150793`).
   Funds are credited to `pendingBalances` so creator and treasury pull independently via `withdrawPending()`. A reverting or blacklisted address can never lock the other party's funds.
6. **Batch Claiming**: Supports claiming across multiple collections and token IDs in a single gas-efficient transaction.

---

## 📜 Key Contracts on Base (Mainnet)

| Contract | Network | Address | Description |
|---|---|---|---|
| **CAPdropper Vault** | Base | `0x17Db8FaD0154c64bbc0D8154556291c11D16b9F7` | Master airdrop & escrow vault (Live) |
| **Midas Gate Registry** | Base | `0x54C3C8C9E2180c6b90652983d1c15cF933f1a263` | Authoritative Midas Gate registry with matrix light sockets & admin keys |
| **Active Midas Collection** | Base | `0x3bc52b9835e6ed74d562ed2df42755aa7c27e8b7` | King Midas (8,888 minted NFTs) |
| **Protocol Treasury** | Base | `0xA12506f742F4AB0980a57264871DB56A1A150793` | Designated 10% expiration fee recipient |

---

## 🕹️ Game Integration (e.g. Pump It Dry)

1. Player bets / offers 10,000 tokens for game play.
2. Player approves CAPdropper contract (`0x17Db8FaD0154c64bbc0D8154556291c11D16b9F7`) for 10,000 tokens.
3. Client triggers `fundDropWithMidasGate(token, amount, totalEligibleNFTs, durationSeconds, treasury)` using the automated gate token ID count.
4. All eligible NFT holders in the Midas Gate can claim their equal share from the game portal.
5. After duration expires (e.g. 7 days), 90% of unclaimed tokens revert to the player, and 10% goes to protocol treasury.
