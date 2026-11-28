# Vendored ERC-8004 Identity Registry

`IdentityRegistryUpgradeable.sol` is copied **unmodified** from
[erc-8004/erc-8004-contracts](https://github.com/erc-8004/erc-8004-contracts) at commit
`b9e466c250744a7e06b13dff9d3c2844ed64f825` (MIT license).

It is used only on networks where the official registry is not yet deployed (currently Elysium, chain 99901). On
those networks Tabb deploys its own instance behind an ERC-1967 proxy, owned by the protocol owner. This is not the
canonical `0x8004…` deployment. If the ERC-8004 team later deploys the canonical registry on such a network, a new
`AgentCreditManager` pointing at it is required (the manager's registry adapter is immutable).

`RegistryBootstrap.sol` (Tabb) is the first implementation behind the proxy. It mirrors the upstream `MinimalUUPS`
placeholder, but takes the owner as a parameter instead of hard-coding the ERC-8004 team's address. The deploy
script then upgrades the proxy to `IdentityRegistryUpgradeable` and calls its `initialize()`.
