import { PriceServiceConnection } from "@pythnetwork/price-service-client";
import { ethers } from "ethers";
import dotenv from "dotenv";

dotenv.config();

type PoolKey = {
  currency0: string;
  currency1: string;
  fee: number;
  tickSpacing: number;
  hooks: string;
};

const keeperAbi = [
  "function evaluateAndUpdate((address,address,uint24,int24,address)) external",
  "function getPoolSnapshot((address,address,uint24,int24,address)) view returns (tuple(bytes32 priceFeedId0,bytes32 priceFeedId1,uint24 baseFee,uint24 maxFee,uint24 minFee),tuple(uint8 mode,bool jitLiquidityActive,uint256 lastDepegBps,uint256 lastConfidenceBps,uint24 lastOverrideFee,uint256 reserveBalance,uint256 totalPenaltyFees,uint256 totalRebates))"
] as const;

const pythAbi = [
  "function getUpdateFee(bytes[] calldata) external view returns (uint256)",
  "function updatePriceFeeds(bytes[] calldata priceUpdateData) external payable"
] as const;

const {
  RPC_URL,
  PRIVATE_KEY,
  PEG_GUARD_KEEPER,
  PEG_GUARD_PYTH,
  POOL_CURRENCY0,
  POOL_CURRENCY1,
  POOL_FEE,
  POOL_TICK_SPACING,
  PEG_GUARD_HOOK,
  PRICE_FEED_IDS,
  PYTH_ENDPOINT = "https://xc-mainnet.pyth.network",
  KEEPER_INTERVAL_MS = "60000"
} = process.env;

if (
  !RPC_URL ||
  !PRIVATE_KEY ||
  !PEG_GUARD_KEEPER ||
  !PEG_GUARD_PYTH ||
  !POOL_CURRENCY0 ||
  !POOL_CURRENCY1 ||
  !POOL_FEE ||
  !POOL_TICK_SPACING ||
  !PEG_GUARD_HOOK ||
  !PRICE_FEED_IDS
) {
  throw new Error("Missing keeper configuration env vars");
}

const poolKey: PoolKey = {
  currency0: ethers.getAddress(POOL_CURRENCY0),
  currency1: ethers.getAddress(POOL_CURRENCY1),
  fee: Number(POOL_FEE),
  tickSpacing: Number(POOL_TICK_SPACING),
  hooks: ethers.getAddress(PEG_GUARD_HOOK)
};

const poolKeyTuple = [
  poolKey.currency0,
  poolKey.currency1,
  poolKey.fee,
  poolKey.tickSpacing,
  poolKey.hooks
];

const provider = new ethers.JsonRpcProvider(RPC_URL);
const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
const keeper = new ethers.Contract(PEG_GUARD_KEEPER, keeperAbi, wallet);
const pyth = new ethers.Contract(PEG_GUARD_PYTH, pythAbi, wallet);

const priceFeedIds = PRICE_FEED_IDS.split(",").map((id) => id.trim());
const priceService = new PriceServiceConnection(PYTH_ENDPOINT);
const intervalMs = Number(KEEPER_INTERVAL_MS);

async function runCycle() {
  try {
    console.log(`[keeper] fetching price updates for ${priceFeedIds.join(",")}`);
    const updateData = await priceService.getPriceFeedsUpdateData(priceFeedIds);
    const fee = await pyth.getUpdateFee(updateData);
    const updateTx = await pyth.updatePriceFeeds(updateData, { value: fee });
    await updateTx.wait();
    console.log(`[keeper] pushed Pyth update. tx=${updateTx.hash}`);

    const evalTx = await keeper.evaluateAndUpdate(poolKeyTuple);
    const receipt = await evalTx.wait();
    console.log(`[keeper] evaluateAndUpdate mined. tx=${receipt.hash}`);
  } catch (err) {
    console.error(`[keeper] cycle failed`, err);
  }
}

async function main() {
  console.log(`[keeper] booting PegGuard keeper for ${PEG_GUARD_KEEPER}`);
  await runCycle();
  setInterval(runCycle, intervalMs);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
