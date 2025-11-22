import { ethers } from "ethers";
import dotenv from "dotenv";

import { loadPegGuardConfig, JitJobConfig, toPoolKeyTuple } from "./config.js";

dotenv.config();

const managerAbi = [
  "function executeBurst((address,address,uint24,int24,address),uint128,uint256,uint256,address,uint64) external returns (uint256)",
  "function settleBurst((address,address,uint24,int24,address),uint256,uint256) external",
  "function bursts(bytes32) view returns (uint256 tokenId,address funder,uint128 liquidity,uint64 expiry,bool active)",
  "function flashBurst((address,address,uint24,int24,address),uint128,uint256,uint256,address,bytes) external returns (uint256,uint256,uint256,uint256)"
] as const;

const hookAbi = [
  "function getPoolSnapshot((address,address,uint24,int24,address)) view returns (tuple(bytes32 priceFeedId0,bytes32 priceFeedId1,uint24 baseFee,uint24 maxFee,uint24 minFee),tuple(uint8 mode,bool jitLiquidityActive,uint256 lastDepegBps,uint256 lastConfidenceBps,uint24 lastOverrideFee,uint256 reserveBalance,uint256 totalPenaltyFees,uint256 totalRebates))"
] as const;

const borrowerAbi = [
  "function initiateFlashBurst((address,address,uint24,int24,address,uint128,uint256,uint256,address,bytes,address,uint256,address)) external"
] as const;

type RuntimeJob = JitJobConfig & {
  poolTuple: ReturnType<typeof toPoolKeyTuple>;
  poolId: string;
  label: string;
};

const DEFAULT_INTERVAL = Number(process.env.LOOP_INTERVAL_MS ?? "45000");
const DEFAULT_MODE_THRESHOLD = Number(process.env.JIT_MODE_THRESHOLD ?? "2");

const configFile = loadPegGuardConfig(process.env.PEG_GUARD_CONFIG);

const RPC_URL = configFile?.rpcUrl ?? process.env.RPC_URL;
const PRIVATE_KEY = configFile?.privateKey ?? process.env.PRIVATE_KEY;
const MANAGER_ADDRESS = configFile?.jit?.manager ?? process.env.PEG_GUARD_JIT_MANAGER;
const HOOK_ADDRESS = configFile?.jit?.hook ?? process.env.PEG_GUARD_HOOK;

if (!RPC_URL || !PRIVATE_KEY || !MANAGER_ADDRESS || !HOOK_ADDRESS) {
  throw new Error("JIT configuration missing RPC_URL / PRIVATE_KEY / manager + hook addresses");
}

const jobs = buildJobs();
if (jobs.length === 0) throw new Error("No JIT jobs configured");

const provider = new ethers.JsonRpcProvider(RPC_URL);
const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
const manager = new ethers.Contract(MANAGER_ADDRESS, managerAbi, wallet);
const hook = new ethers.Contract(HOOK_ADDRESS, hookAbi, provider);

const borrowerCache = new Map<string, ethers.Contract>();

function getBorrower(address: string) {
  const normalized = ethers.getAddress(address);
  if (!borrowerCache.has(normalized)) {
    borrowerCache.set(normalized, new ethers.Contract(normalized, borrowerAbi, wallet));
  }
  return borrowerCache.get(normalized)!;
}

function buildJobs(): RuntimeJob[] {
  if (configFile?.jit?.jobs?.length) {
    return configFile.jit.jobs.map((job, idx) => {
      const tuple = toPoolKeyTuple(job.pool);
      const poolId = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
          ["address", "address", "uint24", "int24", "address"],
          tuple
        )
      );
      return {
        ...job,
        poolTuple: tuple,
        poolId,
        label: job.id ?? `jit-${idx + 1}`
      };
    });
  }

  const {
    POOL_CURRENCY0,
    POOL_CURRENCY1,
    POOL_TICK_SPACING,
    PEG_GUARD_HOOK: envHook,
    POOL_KEY_FEE,
    JIT_LIQUIDITY = "1000000000000000000",
    JIT_AMOUNT0_MAX = "0",
    JIT_AMOUNT1_MAX = "0",
    JIT_DURATION = "900"
  } = process.env;

  if (!POOL_CURRENCY0 || !POOL_CURRENCY1 || !POOL_TICK_SPACING || !envHook) {
    return [];
  }

  const job: JitJobConfig = {
    id: "env",
    pool: {
      currency0: POOL_CURRENCY0,
      currency1: POOL_CURRENCY1,
      fee: POOL_KEY_FEE !== undefined ? Number(POOL_KEY_FEE) : 0x800000,
      tickSpacing: Number(POOL_TICK_SPACING),
      hooks: envHook
    },
    liquidity: JIT_LIQUIDITY,
    amount0Max: JIT_AMOUNT0_MAX,
    amount1Max: JIT_AMOUNT1_MAX,
    duration: Number(JIT_DURATION),
    modeThreshold: DEFAULT_MODE_THRESHOLD,
    settleBufferSec: 5
  };

  const tuple = toPoolKeyTuple(job.pool);
  const poolId = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["address", "address", "uint24", "int24", "address"],
      tuple
    )
  );

  return [{ ...job, poolTuple: tuple, poolId, label: job.id ?? "env" }];
}

async function maybeExecuteBurst(job: RuntimeJob) {
  const [, state] = await hook.getPoolSnapshot(job.poolTuple);
  const burst = await manager.bursts(job.poolId);
  const threshold = job.modeThreshold ?? DEFAULT_MODE_THRESHOLD;

  if (Number(state.mode) >= threshold && !burst.active) {
    console.log(`[jit:${job.label}] executing burst`);
    if (job.flashBorrower) {
      await executeFlashBurst(job);
    } else {
      const tx = await manager.executeBurst(
        job.poolTuple,
        BigInt(job.liquidity),
        BigInt(job.amount0Max),
        BigInt(job.amount1Max),
        wallet.address,
        Number(job.duration ?? 0)
      );
      await tx.wait();
      console.log(`[jit:${job.label}] burst tx ${tx.hash}`);
    }
    return;
  }

  if (burst.active) {
    const buffer = job.settleBufferSec ?? 5;
    const now = Math.floor(Date.now() / 1000);
    if (now > Number(burst.expiry) + buffer) {
      console.log(`[jit:${job.label}] settling burst tokenId=${burst.tokenId}`);
      const tx = await manager.settleBurst(job.poolTuple, 0, 0);
      await tx.wait();
      console.log(`[jit:${job.label}] settle tx ${tx.hash}`);
    }
  }
}

async function executeFlashBurst(job: RuntimeJob) {
  const fb = job.flashBorrower!;
  const borrower = getBorrower(fb.address);
  const tuple = job.poolTuple;

  const payload = [
    tuple[0],
    tuple[1],
    tuple[2],
    tuple[3],
    tuple[4],
    BigInt(job.liquidity),
    BigInt(job.amount0Max),
    BigInt(job.amount1Max),
    fb.executor ? ethers.getAddress(fb.executor) : ethers.ZeroAddress,
    fb.executorData ?? "0x",
    ethers.getAddress(fb.asset),
    BigInt(fb.amount),
    wallet.address
  ];

  const tx = await borrower.initiateFlashBurst(payload);
  await tx.wait();
  console.log(`[jit:${job.label}] flash burst via ${borrower.target} tx=${tx.hash}`);
}

async function main() {
  console.log(`[jit] monitoring ${jobs.length} pool(s) via ${MANAGER_ADDRESS}`);
  for (const job of jobs) {
    const interval = job.intervalMs ?? DEFAULT_INTERVAL;
    const loop = async () => {
      try {
        await maybeExecuteBurst(job);
      } catch (err) {
        console.error(`[jit:${job.label}] loop failed`, err);
      }
    };
    await loop();
    setInterval(loop, interval);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
