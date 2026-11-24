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
  /** true when USDG / registry are local mocks (enables faucet + "register demo agent") */
  mocks: boolean;
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
  },
  // TODO: Robinhood Chain testnet — <chainId>: { ...addresses from contracts/deployments/<chainId>.json }
};

export function addressesFor(chainId: number): TabbAddresses | undefined {
  return ADDRESSES[chainId];
}

export function isDeployed(a: TabbAddresses | undefined): a is TabbAddresses {
  return !!a && a.agentCreditManager !== ZERO && a.pool !== ZERO;
}
