import fs from "fs";
import path from "path";
import { ethers } from "ethers";

export type PoolKeyConfig = {
  currency0: string;
  currency1: string;
  fee: number;
  tickSpacing: number;
  hooks: string;
};

export type KeeperJobConfig = {
  id?: string;
  pool: PoolKeyConfig;
  priceFeedIds: string[];
  intervalMs?: number;
  pythEndpoint?: string | string[]; // Support multiple endpoints for failover
};

export type KeeperConfig = {
  contract: string;
  pyth: string;
  jobs: KeeperJobConfig[];
};

export type FlashBorrowerConfig = {
  address: string;
  asset: string;
  amount: string;
  executor?: string;
  executorData?: string;
};

export type JitJobConfig = {
  id?: string;
  pool: PoolKeyConfig;
  liquidity: string;
  amount0Max: string;
  amount1Max: string;
  duration?: number;
  modeThreshold?: number;
  settleBufferSec?: number;
  intervalMs?: number;
  executor?: string;
  executorData?: string;
  flashBorrower?: FlashBorrowerConfig;
};

export type JitConfig = {
  manager: string;
  hook: string;
  jobs: JitJobConfig[];
};

export type PegGuardConfigFile = {
  rpcUrl?: string;
  privateKey?: string;
  keeper?: KeeperConfig;
  jit?: JitConfig;
};

export function loadPegGuardConfig(configPath?: string): PegGuardConfigFile | null {
  if (!configPath) return null;
  const resolved = path.resolve(configPath);
  if (!fs.existsSync(resolved)) {
    console.warn(`[config] No config file at ${resolved}, falling back to env vars`);
    return null;
  }

  try {
    const raw = fs.readFileSync(resolved, "utf-8");
    const parsed = JSON.parse(raw) as PegGuardConfigFile;
    return parsed;
  } catch (err) {
    console.error(`[config] Failed to parse ${resolved}`, err);
    throw err;
  }
}

export function toPoolKeyTuple(cfg: PoolKeyConfig) {
  return [
    ethers.getAddress(cfg.currency0),
    ethers.getAddress(cfg.currency1),
    Number(cfg.fee),
    Number(cfg.tickSpacing),
    ethers.getAddress(cfg.hooks)
  ] as const;
}
