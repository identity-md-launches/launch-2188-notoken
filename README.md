# OG Club houses and deeds

A Foundry project for two OG Club purchases using an existing, 18-decimal OG
ERC-20. `OGClubHouses` records permanent wallet membership. `OGClubDeeds` issues
the freely transferable ERC-721 **OG Club (OGCLUB)**, with one deed per Swarm Pepe
ever. Neither application is upgradeable. This assignment does not deploy or
broadcast anything.

## Build and test

Run from the repository root with Foundry and Solidity 0.8.26 installed:

```sh
forge build
FOUNDRY_FUZZ_SEED=0xea0b7115abcdc164ab9403acaf2f709e64d1d242926247d6fd3ddd431c2c3609 forge test
forge fmt --check
```

All Solidity dependencies are ordinary, vendored files: OpenZeppelin Contracts
**v5.4.0** and forge-std **v1.9.7**. No package installation, submodule, RPC, secret,
or environment variable is required for the tests. The fuzz seed above is
optional configuration, not a test dependency. The compiler is pinned by version
in `foundry.toml`; dependency source URLs and archive hashes are recorded in
`lib/dependencies.json`, with upstream licenses alongside their source.

The optimizer uses 200 runs and the Cancun EVM target. Metadata bytecode hashes
are disabled for reproducibility. FFI and filesystem cheatcode access are not
enabled.

## How to buy

All prices and approvals are integer **token wei**: 1 OG = 10^18 units. At launch,
a house costs `100000000000000000000000` (100,000 OG), and a deed costs
`250000000000000000000000` (250,000 OG).

1. Read the relevant application's `price()` and `pendingPrice()`. Check
   `paused()`, and confirm eligibility before approving.
2. From the **payer's** wallet, call `OG.approve(application, quotedPrice)` for
   exactly the accepted price. Houses and deeds have separate spender addresses.
3. From that same wallet, call one of:
   - `houses.buyHouse(quotedPrice)` to buy your own house;
   - `houses.buyHouseFor(account, quotedPrice)` to give a house to a nonzero wallet;
   - `deeds.mint(pepeId, quotedPrice)` to buy the Pepe's unique club deed.

For a deed, the payer must be the Pepe's current `ownerOf(pepeId)`, or be authorized
by the registry's
`checkDelegateForERC721(payer, currentOwner, swarmPepe, pepeId, bytes32(0))`.
The deed goes to that current owner, including a cold vault when a hot delegate
pays. The owner does not approve or spend OG for a delegate's purchase. An ERC-721
approval on the Pepe alone does not authorize a purchase. A revoked delegation or
a delegation from a previous Pepe owner is insufficient. Production registry-wide
or collection-wide delegations work if the production registry returns true for
this exact check.

Houses can be gifted without delegation or consent and do not call the recipient.
Check `hasHouse(account)` first: a gift permanently consumes that wallet's one
membership. Deeds use safe minting, so a contract Pepe owner must implement
`IERC721Receiver` (for a Safe, configure its suitable token receiver/fallback
handler). Rejection rolls back the entire purchase and both payment legs.

`maxPrice` limits the effective price at execution. An increase above it reverts
without spending tokens. A decrease charges the lower price, which can leave some
allowance from an earlier approval; revoke unused allowance when finished. An
approval transaction that succeeded remains approved if the purchase later fails.

## Payment and price behavior

Each purchase calls `transferFrom` directly from the payer to:

| Recipient | Amount |
| --- | --- |
| `0x000000000000000000000000000000000000dEaD` | `price / 2`, rounded down |
| Immutable farming `vault` | `price - price / 2` |

For a 101-wei price, the burn address gets 50 and the vault gets 51. Both recipients'
balances are measured before the transfers and again after both transfers. An
incorrect net increase reverts with `ShortTransfer`, including a tax on either
leg. The payer's exact debit is also checked, rejecting sender-paid surcharges
even when both recipients receive their full shares. Both transfers, allowances, membership flags and NFT minting roll back
together if any part fails. OpenZeppelin SafeERC20 also rejects false-returning
tokens and supports tokens that return no value on successful transfer.

Purchases never route tokens through either application. An unsolicited ERC-20
transfer to an application cannot be prevented by its recipient, and there is no
rescue or withdrawal function: do not send tokens directly to these addresses.
Sending OG to the burn address does not call the ERC-20's burn function and does
not decrease `totalSupply()`.

The token must have honest balance reporting and normal, non-rebasing transfer
semantics. Balance checks do not make a malicious token trustworthy. A transfer
fee that changes a recipient's receipt or the payer's debit is rejected. A token fee rounded
to zero causes no short receipt. A payer must differ from the vault and burn
address for positive payment shares: a self-transfer cannot increase its balance
by the required amount and will revert. A delegate or other wallet can pay for
the vault's house or deed. Construction rejects a vault equal to the burn address
or the application itself.

`setPrice(newPrice)` schedules a replacement exactly `priceNotice` seconds after
the call. Before that timestamp the previous price applies; at the timestamp the
new one applies automatically, without a keeper transaction. Replacing a pending
announcement restarts the full notice interval. Replacing one that has already
activated preserves its price while the next notice runs. Pausing does not stop
the clock. `pendingPrice()` returns `(newPrice, startsAt)` only while a future
change is pending, and `(0, 0)` otherwise. Use the timestamp to distinguish a
pending zero price from no pending change. Zero notice activates immediately.

Prices may be zero, including a scheduled zero price; one-wei prices are also
supported. The constructor accepts notices up to and including 30 days. The
deployer must choose the intended network policy: **0 on testnets and 604800
seconds on mainnet**. Applications do not infer deployment policy from chain id.

## Membership, deeds and owner powers

`hasHouse(account)` and `houseCount()` are permanent membership views. There is
no transfer, approval, revocation or burn API for houses. The game should use
`deeds.ownerOf(pepeId)` to determine the current club owner. Deed ownership becomes
independent of Pepe ownership once minted. Moving either NFT never allows another
deed for the same Pepe. No house membership is required to mint a deed.

The explicitly supplied owner has these powers:

| Application | Power |
| --- | --- |
| Both | Announce any future price through `setPrice`, subject to immutable notice |
| Both | Pause/resume purchases through `setPaused(bool)` |
| Deeds | Set `baseURI` until `freezeMetadata()` permanently freezes it |
| Deeds | Set global ERC-2981 receiver and rate using `setRoyalty(receiver, feeNumerator)` |
| Both | Transfer administration through OpenZeppelin's two-step ownership process, or renounce it |

Every mainnet owner must be a Safe. Owners can prevent new purchases indefinitely
by pausing, or price them out through an announced increase. They cannot redirect
purchase funds, change the payment token, shorten the notice, mint for free by
privilege, revoke houses, burn deeds, seize deeds, or restrict existing deed
approvals/transfers. They can set a zero price for everyone under the ordinary
price rules. All immutable destinations and dependency addresses stay fixed.

For handover, the current owner calls `transferOwnership(newSafe)` and that Safe
calls `acceptOwnership()`. A pending owner has no administrative power yet.
`transferOwnership(address(0))` cancels a pending handover without changing the
current owner. `renounceOwnership()` permanently removes administration; in
particular, renouncing while paused leaves new purchases disabled permanently.
An already scheduled price still activates after renunciation.

`tokenURI(id)` is exactly `baseURI + decimal(id) + ".json"`, and reverts for an
unminted deed. The initial prefix is empty, yielding, for example, `42.json`.
Supply the desired trailing slash in a prefix such as `ipfs://<metadata-CID>/`.
Freezing prevents prefix changes, including after ownership handover, but cannot
freeze mutable content served by a web host. Freezing an empty prefix is also
permanent; publish and verify metadata before freezing.

Royalties start at **500 basis points (5%)**, may range from 0 through
**1,000 basis points (10%)**, and always require a nonzero receiver. They are
global for all deeds and remain adjustable after metadata is frozen. ERC-2981
reports royalties; it does not enforce marketplace payment or tax NFT transfers.

## Sepolia deployment recipe

`script/Deploy.s.sol` is restricted to chain **11155111**. It takes explicit
`deployer` and `owner` arguments; its `deploy(deployer, owner)` function is exercised
directly in tests without environment reads. It creates, in order:

1. `MockOG(deployer)`: **notoken / nt**, 18 decimals, initially **1 whole token**
   (`1e18` units) to the specified deployer; `mint(account, amount)` is a public faucet.
2. `MockSwarmPepe()`: `mint(account, pepeId)` is public for each unused id.
3. `MockDelegateRegistry()`: the delegating vault can grant or revoke its own
   token-specific delegation with
   `delegateERC721(delegate, collection, id, bytes32(0), enabled)`.
4. `OGClubHouses(mockToken, deployer, owner, 100000 ether, 0)`.
5. `OGClubDeeds(mockToken, deployer, owner, 250000 ether, 0, mockPepe, mockRegistry, owner)`.

The mock token's **initial** supply is one token; public faucet calls intentionally
increase it so the larger purchase prices can be tested. It is not a capped
production token. The mock registry covers only explicit token-specific grants,
not every feature of delegate.xyz v2. All three mocks are test tools and must not
be used as mainnet dependencies.

After the operator supplies real Sepolia addresses and an RPC URL, this command
simulates the recipe without broadcasting:

```sh
forge script script/Deploy.s.sol:Deploy \
  --sig 'run(address,address)' "$DEPLOYER" "$OWNER" \
  --rpc-url "$SEPOLIA_RPC_URL"
```

These names refer to operator-provided shell variables, not a supplied secrets
file. The script reads no environment variables, keys, or local configuration.
Signing, broadcasting, explorer verification, and recording confirmed addresses
remain the deployment operator's responsibilities. No deployment addresses are
claimed in this repository.

`launch.json` is the equivalent five-contract Sepolia factory manifest. Its
supported `$owner` binding is the launch's supplied test deployment wallet: it
receives the initial mock token, vault payments, ownership and royalties. The
factory is never assigned an owner or recipient role. Backward `$contract:Name`
references bind the newly deployed mocks. The manifest uses the same wallet for
the test deployer and owner; use the explicit-argument script when those roles
need separate addresses. The owner address is supplied by the launch system,
not guessed or hardcoded by this project.

## Mainnet configuration and handoff

Deploy only the two application contracts on mainnet, from a fresh deployer.
The Sepolia mock script rejects mainnet, and its manifest must not be reused.

| Parameter | Mainnet value |
| --- | --- |
| `TOKEN` | The existing OG ERC-20 address supplied and verified by the project operator; must have 18 decimals and exact transfers |
| `VAULT` | The project's real farming vault address supplied and verified by the operator |
| `OWNER` | The project's Safe, explicitly passed to both constructors |
| House initial price | `100000000000000000000000` |
| Deed initial price | `250000000000000000000000` |
| `PRICE_NOTICE` | `604800` (7 days), immutable |
| `SWARM_PEPE` | `0x999ce0CE8C5f7661e0c74a568FfE27CEB9177bDB` |
| `DELEGATE_REGISTRY` | `0x00000000000000447e69651d841bD8D104Bed493` (delegate.xyz v2) |
| `ROYALTY_RECEIVER` | The owner Safe initially; it may change this through `setRoyalty` |

Constructor argument order is `(token, vault, owner, initialPrice, priceNotice)`
for houses. Deeds append `(swarmPepe, delegateRegistry, royaltyReceiver)` to those
five arguments. The named collection and registry addresses above come from the
brief; no live mainnet RPC verification was performed here. The OG token, farming
vault and Safe addresses are deliberately deployment inputs, not stand-ins. A
mainnet deployer must obtain them before creating the immutable applications.
No constructor calls external dependencies or requires their code to exist, so
the operator must verify code, chain, token decimals and registry behavior before
launch.

After launch the operator should record and verify both source/constructor
configurations, check the Safe's ownership of each, publish the correct spender
addresses, and arrange metadata hosting. The Safe sets and reviews `baseURI`
before optionally freezing it and maintains the royalty receiver. The game
indexes `HouseBought` and `ClubMinted`, follows standard ERC-721 `Transfer`
events, and uses current on-chain views as the source of truth. `ClubMinted.owner`
is the mint recipient at purchase time; an NFT receiver can immediately transfer
the deed during its receiver callback, so this event is not a current-ownership
oracle. Monitor price announcements and purchase pause events for the buying UI.

## Validation and review scope

The suite checks both payment implementations, exact even/odd/zero/one-wei splits,
price limits and notice boundaries, replacement schedules, zero address/notice
validation, owner access, events, membership permanence, delegation and
revocation, independent Pepe/deed transfers, safe recipient rejection, URI
freezing, and royalty bounds. Adversarial tokens cover transfer fees on either
leg, sender-paid surcharges, a false return after the first transfer, no-return compatibility, a second
transfer undoing the first receipt, and callbacks into every purchase entrypoint.
An NFT receiver attempts reentrancy and trades its legitimately received deed.

Stateful invariants run **128 sequences of depth 64**, mixing purchases, gifts,
price changes, time advances, pause changes, delegations and NFT trades. They
compare actual payer spending against burn-plus-vault receipts, verify both
shares independently, and check zero purchase custody, permanent houses and
permanent consumption of deed eligibility. Four unit fuzz properties run **512
cases each**. The seed in the build instructions matches the supplied verifier
seed.

Deployment tests check explicit ownership, the test faucets, the five runtimes'
EIP-170 size limit and absence of DELEGATECALL, CALLCODE and SELFDESTRUCT opcodes,
and construction without live external dependencies. Local tests do not execute
the environment-driven protected harness, which receives launch-specific values
only in the independent verification step.

Foundry tests and a manual review were performed. Slither, Mythril, a live mainnet
fork, real Safe integration, and a production registry integration test were not
run. Independent adversarial review and operator verification of the actual OG
token, Safe receiver behavior and production registry remain necessary before a
mainnet release; this deliverable is not an independent security audit.

