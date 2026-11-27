// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title TabbConfig
/// @notice External addresses per chain. NOTHING here is invented: every unknown address is address(0) with a TODO.
///         Mirror of /config/addresses.ts (frontend).
library TabbConfig {
    uint256 internal constant ANVIL = 31337;
    uint256 internal constant ROBINHOOD_MAINNET = 4663;
    uint256 internal constant ROBINHOOD_TESTNET = 46630; // verified via eth_chainId on rpc.testnet.chain.robinhood.com
    uint256 internal constant ELYSIUM = 99901; // Kinetiq Elysium mainnet, verified via eth_chainId on rpc.elysium.kinetiq.xyz

    struct External {
        address usdg; // TODO per chain: USDG token (verify decimals() == 6)
        address identityRegistry; // TODO per chain: ERC-8004 Identity Registry
        address reputationRegistry; // optional, unused in MVP scoring
        // Phase 2 (yield credit)
        address sequencerUptimeFeed; // TODO: Chainlink L2 sequencer uptime feed
        address usdgUsdFeed; // optional
        address usdgVault; // TODO: ERC-4626 USDG vault (e.g. Morpho) — review before whitelisting
        address cliptYieldToken; // TODO: Clipt stock-dividend YT
        address cliptYtPriceFeed; // TODO: price feed for the YT
    }

    struct Roles {
        address owner; // TODO: multisig / TimelockController
        address guardian; // TODO: pause guardian
        address treasury; // TODO: protocol treasury
        address payeeCurator; // TODO: payee whitelist curator
    }

    function externalFor(uint256 chainId) internal pure returns (External memory e) {
        if (chainId == ROBINHOOD_MAINNET) {
            // Robinhood Chain mainnet. Phase 2 entries stay TODO until verified feeds / vault / YT exist.
            e = External({
                // Verified on-chain 2026-11-25 via rpc.mainnet.chain.robinhood.com: symbol "USDG", name "Global Dollar",
                // decimals 6.
                usdg: 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168,
                // ERC-8004 IdentityRegistry (deterministic CREATE2 address; name() == "AgentIdentity", ownerOf and
                // getMetadata(agentId, "agentWallet") verified on-chain 2026-11-25).
                identityRegistry: 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432,
                reputationRegistry: address(0), // TODO (optional)
                sequencerUptimeFeed: address(0), // TODO
                usdgUsdFeed: address(0), // TODO (optional)
                usdgVault: address(0), // TODO
                cliptYieldToken: address(0), // TODO
                cliptYtPriceFeed: address(0) // TODO
            });
        }
        if (chainId == ELYSIUM) {
            // Elysium (Kinetiq) mainnet, verified on-chain 2026-11-27. Stablecoin is USDC (6 decimals), bridged from
            // HyperEVM. No ERC-8004 Identity Registry exists on Elysium yet -> address(0) (protocol not deployable).
            e.usdg = 0xb47c4C8F73F009CC0C0d3f92B388d13E293F0B65; // USDC
            e.identityRegistry = address(0); // TODO: ERC-8004 Identity Registry not deployed on Elysium yet
        }
        // Robinhood Chain testnet (46630): USDG / ERC-8004 / feeds unknown -> address(0); testnet deploys use
        // DEPLOY_MOCKS=true (mock USDG with public mint, mock ERC-8004 registry, mock vault/YT/feed).
        // Anvil (31337) always deploys mocks.
    }
}
