// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title TabbConfig
/// @notice External addresses per chain. NOTHING here is invented: every unknown address is address(0) with a TODO.
///         Mirror of /config/addresses.ts (frontend).
library TabbConfig {
    uint256 internal constant ANVIL = 31337;
    uint256 internal constant ROBINHOOD_MAINNET = 4663;
    uint256 internal constant ROBINHOOD_TESTNET = 46630; // verified via eth_chainId on rpc.testnet.chain.robinhood.com

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
            // Robinhood Chain mainnet — fill in before the (manual, post-audit) mainnet deploy.
            e = External({
                usdg: address(0), // TODO
                identityRegistry: address(0), // TODO
                reputationRegistry: address(0), // TODO (optional)
                sequencerUptimeFeed: address(0), // TODO
                usdgUsdFeed: address(0), // TODO (optional)
                usdgVault: address(0), // TODO
                cliptYieldToken: address(0), // TODO
                cliptYtPriceFeed: address(0) // TODO
            });
        }
        // Robinhood Chain testnet (46630): USDG / ERC-8004 / feeds unknown -> address(0); testnet deploys use
        // DEPLOY_MOCKS=true (mock USDG with public mint, mock ERC-8004 registry, mock vault/YT/feed).
        // Anvil (31337) always deploys mocks.
    }
}
