/**
 * Tabb contract addresses per chain. Mirror of contracts/script/Config.s.sol.
 *
 * NOTHING here is invented:
 *  - 31337 (anvil): deterministic addresses produced by `forge script script/DeployLocal.s.sol` on a FRESH anvil.
 *  - 4663 (Robinhood Chain mainnet): TODO — filled in only after audit + manual deploy.
 *  - Robinhood Chain testnet: TODO — chain id and addresses unknown; add an entry after running DeployTestnet.
 */
export type Address = `0x${string}`;

export const ZERO: Address = "0x0000000000000000000000000000000000000000";

export interface TabbAddresses {
  // external
  usdg: Address;
  identityRegistry: Address; // ERC-8004 Identity Registry
  // protocol (Phase 1)
  pool: Address;
  agentCreditManager: Address;
  creditScore: Address;
  stakeVault: Address;
  payeeRegistry: Address;
  riskConfig: Address;
  registryAdapter: Address;
  interestRateModel: Address;
  // demo only
  demoProvider?: Address;
  /** Phase 2 — yield credit (separate pool). Undefined until deployed. */
  yield?: YieldAddresses;
  /** true when USDG / registry are local mocks (enables faucet + "register demo agent") */
  mocks: boolean;
}

export interface YieldAddresses {
  pool: Address;
  oracle: Address;
  risk: Address;
  tabManager: Address;
  harvester: Address;
  liquidator: Address;
  shareAdapter: Address; // ERC-4626 USDG vault shares
  ytAdapter: Address; // Clipt stock-dividend YT
  vault: Address; // TODO on 4663: USDG ERC-4626 vault (e.g. Morpho)
  yieldToken: Address; // TODO on 4663: Clipt YT
  ytFeed?: Address; // mock feed (local only)
}

export const ADDRESSES: Record<number, TabbAddresses> = {
  31337: {
    usdg: "0x5FbDB2315678afecb367f032d93F642f64180aa3",
    identityRegistry: "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512",
    interestRateModel: "0xa513E6E4b8f2a923D98304ec87F64353C4D5C853",
    pool: "0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6",
    registryAdapter: "0x8A791620dd6260079BF849Dc5567aDC3F2FdC318",
    riskConfig: "0x610178dA211FEF7D417bC0e6FeD39F05609AD788",
    stakeVault: "0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e",
    creditScore: "0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0",
    payeeRegistry: "0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82",
    agentCreditManager: "0x959922bE3CAee4b8Cd9a407cc3ac1C251C2007B1",
    demoProvider: "0x90F79bf6EB2c4f870365E785982E1f101E93b906",
    mocks: true,
    yield: {
      pool: "0x322813Fd9A801c5507c9de605d63CEA4f2CE6c44",
      oracle: "0xa85233C63b9Ee964Add6F2cffe00Fd84eb32338f",
      risk: "0x4A679253410272dd5232B3Ff7cF5dbB88f295319",
      tabManager: "0x7a2088a1bFc9d81c55368AE168C2C02570cB814F",
      harvester: "0x09635F643e140090A9A8Dcd712eD6285858ceBef",
      liquidator: "0xc5a5C42992dECbae36851359345FE25997F5C42d",
      shareAdapter: "0x851356ae760d987E095750cCeb3bC6014560891C",
      ytAdapter: "0xf5059a5D33d5853360D16C683c16e67980206f36",
      vault: "0x9E545E3C0baAB3E08CdfD552C960A1050f373042",
      yieldToken: "0xa82fF9aFd8f496c3d6ac40E2a0F282E47488CFc9",
      ytFeed: "0x1613beB3B2C4f22Ee086B2b38C1476A3cE7f78E8",
    },
  },
  4663: {
    usdg: ZERO, // TODO: USDG on Robinhood Chain (verify decimals() == 6)
    identityRegistry: ZERO, // TODO: ERC-8004 Identity Registry on Robinhood Chain
    interestRateModel: ZERO, // TODO: after manual post-audit deploy
    pool: ZERO, // TODO
    registryAdapter: ZERO, // TODO
    riskConfig: ZERO, // TODO
    stakeVault: ZERO, // TODO
    creditScore: ZERO, // TODO
    payeeRegistry: ZERO, // TODO
    agentCreditManager: ZERO, // TODO
    mocks: false,
    // yield: TODO — Phase 2 addresses (pool, oracle, risk, tabManager, harvester, liquidator, adapters,
    //        USDG ERC-4626 vault, Clipt YT) after the manual post-audit deploy
  },
  // TODO: Robinhood Chain testnet — <chainId>: { ...addresses from contracts/deployments/<chainId>.json }
};

export function addressesFor(chainId: number): TabbAddresses | undefined {
  return ADDRESSES[chainId];
}

export function isDeployed(a: TabbAddresses | undefined): a is TabbAddresses {
  return !!a && a.agentCreditManager !== ZERO && a.pool !== ZERO;
}
