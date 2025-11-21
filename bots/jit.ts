import { ethers } from "ethers";
import dotenv from "dotenv";

dotenv.config();

const managerAbi = [
  "function executeBurst((address,address,uint24,int24,address),uint128,uint256,uint256,address,uint64) external returns (uint256)",
  "function settleBurst((address,address,uint24,int24,address),uint256,uint256) external",
  "function bursts(bytes32) view returns (uint256 tokenId,address funder,uint128 liquidity,uint64 expiry,bool active)"
] as const;

const hookAbi = [
  "function getPoolSnapshot((address,address,uint24,int24,address)) view returns (tuple(bytes32 priceFeedId0,bytes32 priceFeedId1,uint24 baseFee,uint24 maxFee,uint24 minFee),tuple(uint8 mode,bool jitLiquidityActive,uint256 lastDepegBps,uint256 lastConfidenceBps,uint24 lastOverrideFee,uint256 reserveBalance,uint256 totalPenaltyFees,uint256 totalRebates))"
] as const;

const DYNAMIC_FEE_FLAG = 0x800000;

const {
  RPC_URL,
  PRIVATE_KEY,
  PEG_GUARD_JIT_MANAGER,
  PEG_GUARD_HOOK,
  POOL_CURRENCY0,
  POOL_CURRENCY1,
  POOL_TICK_SPACING,
  JIT_LIQUIDITY = "1000000000000000000",
  JIT_AMOUNT0_MAX = "0",
  JIT_AMOUNT1_MAX = "0",
  JIT_DURATION = "900",
  JIT_MODE_THRESHOLD = "2",
  LOOP_INTERVAL_MS = "45000"
} = process.env;

if (
  !RPC_URL ||
  !PRIVATE_KEY ||
  !PEG_GUARD_JIT_MANAGER ||
  !PEG_GUARD_HOOK ||
  !POOL_CURRENCY0 ||
  !POOL_CURRENCY1 ||
  !POOL_TICK_SPACING
) {
  throw new Error("Missing JIT bot env vars");
}

const poolFeeFlag =
  process.env.POOL_KEY_FEE !== undefined
    ? Number(process.env.POOL_KEY_FEE)
    : DYNAMIC_FEE_FLAG;

const poolKeyTuple = [
  ethers.getAddress(POOL_CURRENCY0),
  ethers.getAddress(POOL_CURRENCY1),
  poolFeeFlag,
  Number(POOL_TICK_SPACING),
  ethers.getAddress(PEG_GUARD_HOOK)
] as const;

const provider = new ethers.JsonRpcProvider(RPC_URL);
const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
const manager = new ethers.Contract(PEG_GUARD_JIT_MANAGER, managerAbi, wallet);
const hook = new ethers.Contract(PEG_GUARD_HOOK, hookAbi, wallet);

const poolId = ethers.keccak256(
  ethers.AbiCoder.defaultAbiCoder().encode(
    ["address", "address", "uint24", "int24", "address"],
    poolKeyTuple
  )
);

const modeThreshold = Number(JIT_MODE_THRESHOLD);
const interval = Number(LOOP_INTERVAL_MS);

async function maybeExecuteBurst() {
  const [, state] = await hook.getPoolSnapshot(poolKeyTuple);
  const burst = await manager.bursts(poolId);

  if (Number(state.mode) >= modeThreshold && !burst.active) {
    console.log("[jit] executing burst");
    const tx = await manager.executeBurst(
      poolKeyTuple,
      BigInt(JIT_LIQUIDITY),
      BigInt(JIT_AMOUNT0_MAX),
      BigInt(JIT_AMOUNT1_MAX),
      wallet.address,
      Number(JIT_DURATION)
    );
    await tx.wait();
    console.log(`[jit] burst tx ${tx.hash}`);
    return;
  }

  if (burst.active) {
    const now = Math.floor(Date.now() / 1000);
    if (now > Number(burst.expiry) + 5) {
      console.log("[jit] settling burst");
      const tx = await manager.settleBurst(poolKeyTuple, 0, 0);
      await tx.wait();
      console.log(`[jit] settle tx ${tx.hash}`);
    }
  }
}

async function main() {
  console.log(`[jit] monitoring PegGuardJITManager at ${PEG_GUARD_JIT_MANAGER}`);
  await maybeExecuteBurst();
  setInterval(maybeExecuteBurst, interval);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
