import { PriceServiceConnection } from "@pythnetwork/price-service-client";
import { ethers } from "ethers";
import dotenv from "dotenv";

import { loadPegGuardConfig, KeeperJobConfig, toPoolKeyTuple } from "./config.js";

dotenv.config();

const keeperAbi = [
  "function evaluateAndUpdate((address,address,uint24,int24,address)) external",
  "function getPoolSnapshot((address,address,uint24,int24,address)) view returns (tuple(bytes32 priceFeedId0,bytes32 priceFeedId1,uint24 baseFee,uint24 maxFee,uint24 minFee),tuple(uint8 mode,bool jitLiquidityActive,uint256 lastDepegBps,uint256 lastConfidenceBps,uint24 lastOverrideFee,uint256 reserveBalance,uint256 totalPenaltyFees,uint256 totalRebates))",
  "event KeeperEvaluated(bytes32 indexed poolId, uint8 targetMode, bool jitTarget, uint256 depegBps, uint256 confidenceBps)",
  "event StaleFeedDetected(bytes32 indexed poolId, bytes32 feedId)"
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
  const endpoints = Array.isArray(job.pythEndpoint) 
    ? job.pythEndpoint 
    : [job.pythEndpoint ?? DEFAULT_ENDPOINT];
  const feedIds = job.priceFeedIds.map((id) => id.trim()).filter(Boolean);
  if (feedIds.length === 0) {
    console.warn(`[keeper:${job.label}] No feed IDs configured, skipping`);
    return;
  }

  const MAX_RETRIES = 3;
  const RETRY_DELAY_MS = 5000;

  const execute = async (retryCount = 0): Promise<void> => {
    try {
      console.log(`[keeper:${job.label}] fetching price updates (attempt ${retryCount + 1})`);
      
      // Try endpoints in order until one succeeds
      let updateData: string[] | null = null;
      let lastError: Error | null = null;
      
      for (const endpoint of endpoints) {
        try {
          const connection = getPriceService(endpoint);
          updateData = await connection.getPriceFeedsUpdateData(feedIds);
          console.log(`[keeper:${job.label}] fetched updates from ${endpoint}`);
          break;
        } catch (err) {
          lastError = err as Error;
          console.warn(`[keeper:${job.label}] endpoint ${endpoint} failed:`, err);
          continue;
        }
      }

      if (!updateData) {
        throw new Error(`All endpoints failed. Last error: ${lastError?.message ?? "unknown"}`);
      }

      const fee = await pyth.getUpdateFee(updateData);
      console.log(`[keeper:${job.label}] update fee: ${ethers.formatEther(fee)} ETH`);
      
      const updateTx = await pyth.updatePriceFeeds(updateData, { value: fee });
      const updateReceipt = await updateTx.wait();
      console.log(`[keeper:${job.label}] pushed Pyth update tx=${updateReceipt.hash} block=${updateReceipt.blockNumber}`);

      // Wait a bit for the update to be processed
      await new Promise(resolve => setTimeout(resolve, 1000));

      const evalTx = await keeper.evaluateAndUpdate(job.poolTuple);
      const evalReceipt = await evalTx.wait();
      
      // Parse events to check for stale feeds and log evaluation results
      try {
        const iface = new ethers.Interface(keeperAbi);
        for (const log of evalReceipt.logs) {
          try {
            const parsed = iface.parseLog(log);
            if (parsed?.name === "KeeperEvaluated") {
              const modeNames = ["Calm", "Alert", "Crisis"];
              const mode = modeNames[Number(parsed.args.targetMode)] || "Unknown";
              console.log(`[keeper:${job.label}] evaluated pool mode=${mode} jit=${parsed.args.jitTarget} depeg=${parsed.args.depegBps}bps conf=${parsed.args.confidenceBps}bps`);
            } else if (parsed?.name === "StaleFeedDetected") {
              console.warn(`[keeper:${job.label}] STALE FEED DETECTED: poolId=${parsed.args.poolId} feedId=${parsed.args.feedId}`);
            }
          } catch {
            // Skip logs that don't match our ABI
            continue;
          }
        }
      } catch (parseErr) {
        // Event parsing failed, but transaction succeeded
        console.warn(`[keeper:${job.label}] could not parse events:`, parseErr);
      }

      console.log(`[keeper:${job.label}] evaluateAndUpdate tx=${evalReceipt.hash} block=${evalReceipt.blockNumber}`);
    } catch (err) {
      const error = err as Error;
      console.error(`[keeper:${job.label}] cycle failed:`, error.message);
      
      if (retryCount < MAX_RETRIES) {
        console.log(`[keeper:${job.label}] retrying in ${RETRY_DELAY_MS}ms...`);
        await new Promise(resolve => setTimeout(resolve, RETRY_DELAY_MS));
        return execute(retryCount + 1);
      } else {
        console.error(`[keeper:${job.label}] max retries reached, will retry on next interval`);
        // Log to monitoring/alerting system here if needed
      }
    }
  };

  await execute();
  setInterval(() => execute(), interval);
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
