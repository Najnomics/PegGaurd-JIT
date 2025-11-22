import { PriceServiceConnection } from "@pythnetwork/price-service-client";
import { ethers } from "ethers";
import dotenv from "dotenv";

import { loadPegGuardConfig, KeeperJobConfig, toPoolKeyTuple } from "./config.js";

dotenv.config();

const keeperAbi = [
  "function evaluateAndUpdate((address,address,uint24,int24,address)) external",
  "function getPoolSnapshot((address,address,uint24,int24,address)) view returns (tuple(bytes32 priceFeedId0,bytes32 priceFeedId1,uint24 baseFee,uint24 maxFee,uint24 minFee),tuple(uint8 mode,bool jitLiquidityActive,uint256 lastDepegBps,uint256 lastConfidenceBps,uint24 lastOverrideFee,uint256 reserveBalance,uint256 totalPenaltyFees,uint256 totalRebates))"
] as const;

const pythAbi = [
  "function getUpdateFee(bytes[] calldata) external view returns (uint256)",
  "function updatePriceFeeds(bytes[] calldata priceUpdateData) external payable"
] as const;

type RuntimeJob = KeeperJobConfig & { poolTuple: ReturnType<typeof toPoolKeyTuple>; label: string };

const DEFAULT_ENDPOINT = process.env.PYTH_ENDPOINT ?? "https://xc-mainnet.pyth.network";
const DEFAULT_INTERVAL = Number(process.env.KEEPER_INTERVAL_MS ?? "60000");

const configFile = loadPegGuardConfig(process.env.PEG_GUARD_CONFIG);

const RPC_URL = configFile?.rpcUrl ?? process.env.RPC_URL;
const PRIVATE_KEY = configFile?.privateKey ?? process.env.PRIVATE_KEY;
const KEEPER_ADDRESS = configFile?.keeper?.contract ?? process.env.PEG_GUARD_KEEPER;
const PYTH_ADDRESS = configFile?.keeper?.pyth ?? process.env.PEG_GUARD_PYTH;

if (!RPC_URL || !PRIVATE_KEY || !KEEPER_ADDRESS || !PYTH_ADDRESS) {
  throw new Error("Keeper configuration missing RPC_URL / PRIVATE_KEY / keeper + pyth contracts");
}

const jobs = buildJobs();
if (jobs.length === 0) throw new Error("No keeper jobs configured");

const provider = new ethers.JsonRpcProvider(RPC_URL);
const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
const keeper = new ethers.Contract(KEEPER_ADDRESS, keeperAbi, wallet);
const pyth = new ethers.Contract(PYTH_ADDRESS, pythAbi, wallet);

const priceServiceCache = new Map<string, PriceServiceConnection>();

function getPriceService(endpoint: string) {
  if (!priceServiceCache.has(endpoint)) {
    priceServiceCache.set(endpoint, new PriceServiceConnection(endpoint));
  }
  return priceServiceCache.get(endpoint)!;
}

function buildJobs(): RuntimeJob[] {
  if (configFile?.keeper?.jobs?.length) {
    return configFile.keeper.jobs.map((job, idx) => ({
      ...job,
      poolTuple: toPoolKeyTuple(job.pool),
      label: job.id ?? `job-${idx + 1}`
    }));
  }

  const {
    POOL_CURRENCY0,
    POOL_CURRENCY1,
    POOL_TICK_SPACING,
    PEG_GUARD_HOOK,
    PRICE_FEED_IDS,
    POOL_KEY_FEE
  } = process.env;

  if (
    !POOL_CURRENCY0 ||
    !POOL_CURRENCY1 ||
    !POOL_TICK_SPACING ||
    !PEG_GUARD_HOOK ||
    !PRICE_FEED_IDS
  ) {
    return [];
  }

  const job: KeeperJobConfig = {
    id: "env",
    pool: {
      currency0: POOL_CURRENCY0,
      currency1: POOL_CURRENCY1,
      fee:
        POOL_KEY_FEE !== undefined
          ? Number(POOL_KEY_FEE)
          : 0x800000,
      tickSpacing: Number(POOL_TICK_SPACING),
      hooks: PEG_GUARD_HOOK
    },
    priceFeedIds: PRICE_FEED_IDS.split(",").map((id) => id.trim()),
    intervalMs: DEFAULT_INTERVAL,
    pythEndpoint: DEFAULT_ENDPOINT
  };

  return [{ ...job, poolTuple: toPoolKeyTuple(job.pool), label: job.id ?? "env" }];
}

async function runJob(job: RuntimeJob) {
  const interval = job.intervalMs ?? DEFAULT_INTERVAL;
  const endpoint = job.pythEndpoint ?? DEFAULT_ENDPOINT;
  const connection = getPriceService(endpoint);
  const feedIds = job.priceFeedIds.map((id) => id.trim()).filter(Boolean);
  if (feedIds.length === 0) {
    console.warn(`[keeper:${job.label}] No feed IDs configured, skipping`);
    return;
  }

  const execute = async () => {
    try {
      console.log(`[keeper:${job.label}] fetching price updates`);
      const updateData = await connection.getPriceFeedsUpdateData(feedIds);
      const fee = await pyth.getUpdateFee(updateData);
      const updateTx = await pyth.updatePriceFeeds(updateData, { value: fee });
      await updateTx.wait();
      console.log(`[keeper:${job.label}] pushed Pyth update tx=${updateTx.hash}`);

      const evalTx = await keeper.evaluateAndUpdate(job.poolTuple);
      const receipt = await evalTx.wait();
      console.log(`[keeper:${job.label}] evaluateAndUpdate tx=${receipt.hash}`);
    } catch (err) {
      console.error(`[keeper:${job.label}] cycle failed`, err);
    }
  };

  await execute();
  setInterval(execute, interval);
}

async function main() {
  console.log(`[keeper] managing ${jobs.length} pool(s) via ${KEEPER_ADDRESS}`);
  for (const job of jobs) {
    runJob(job);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
