import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import poolManagerArtifact from "@uniswap/v4-core/out/PoolManager.sol/PoolManager.json";
import positionManagerArtifact from "@uniswap/v4-periphery/foundry-out/PositionManager.sol/PositionManager.json";
import positionDescriptorArtifact from "@uniswap/v4-periphery/foundry-out/PositionDescriptor.sol/PositionDescriptor.json";

// Uniswap artifacts may ship bytecode as a string or as { object: string }.
function artifactBytecode(artifact: { bytecode: string | { object: string } }): string {
  return typeof artifact.bytecode === "string" ? artifact.bytecode : artifact.bytecode.object;
}

// Initial token supply: 1,000,000 tokens with 18 decimals.
const INITIAL_SUPPLY = 1_000_000n * 10n ** 18n;

/**
 * Deploys the full RewardTokensManager stack on the local Hardhat network:
 *   1. PNPToken  — Smart-Shopper-style reward token (1 PNPT = R0.01)
 *   2. FNBToken  — eBucks-style reward token       (1 FNBT = R0.10)
 *   3. Uniswap v4 PoolManager    (from upstream artifact)
 *   4. MockPermit2               (test double for the Permit2 singleton)
 *   5. MockWETH9                 (required by PositionDescriptor constructor)
 *   6. PositionDescriptor        (from upstream artifact)
 *   7. PositionManager           (from upstream artifact)
 *   8. RewardTokensManager       — our assignment contract; creates the pool and mints positions
 */
const deployRewardTokens: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const { deploy } = hre.deployments;
  const deployerSigner = await hre.ethers.getSigner(deployer);

  // ── 1. PNPToken ──────────────────────────────────────────────────────────────
  const pnpResult = await deploy("PNPToken", {
    from: deployer,
    args: [INITIAL_SUPPLY],
    log: true,
    autoMine: true,
  });
  console.log("PNPToken deployed to:", pnpResult.address);

  // ── 2. FNBToken ──────────────────────────────────────────────────────────────
  const fnbResult = await deploy("FNBToken", {
    from: deployer,
    args: [INITIAL_SUPPLY],
    log: true,
    autoMine: true,
  });
  console.log("FNBToken deployed to:", fnbResult.address);

  // ── 3. Uniswap v4 PoolManager (deployed from upstream foundry artifact) ──────
  // PoolManager is the singleton that holds all v4 pool state.
  const poolManagerFactory = new hre.ethers.ContractFactory(
    poolManagerArtifact.abi,
    artifactBytecode(poolManagerArtifact as { bytecode: string | { object: string } }),
    deployerSigner,
  );
  // Explicit gasLimit prevents ethers from defaulting to the full block gas limit,
  // which exceeds the localhost node's per-transaction gas cap.
  const poolManager = await poolManagerFactory.deploy(deployer, { gasLimit: 8_000_000 });
  await poolManager.waitForDeployment();
  const poolManagerAddress = await poolManager.getAddress();
  console.log("PoolManager deployed to:", poolManagerAddress);

  // ── 4. MockPermit2 ───────────────────────────────────────────────────────────
  // Permit2 is the canonical approval contract used by PositionManager to pull
  // tokens when settling pool deltas. We use a mock for the local network.
  const mockPermit2Result = await deploy("MockPermit2", {
    from: deployer,
    log: true,
    autoMine: true,
  });
  console.log("MockPermit2 deployed to:", mockPermit2Result.address);

  // ── 5. MockWETH9 ─────────────────────────────────────────────────────────────
  // PositionDescriptor requires a WETH9 address; we use a minimal mock locally.
  const mockWethResult = await deploy("MockWETH9", {
    from: deployer,
    log: true,
    autoMine: true,
  });
  console.log("MockWETH9 deployed to:", mockWethResult.address);

  // ── 6. PositionDescriptor (from upstream foundry artifact) ───────────────────
  // Provides human-readable NFT metadata for v4 positions.
  const descFactory = new hre.ethers.ContractFactory(
    positionDescriptorArtifact.abi,
    artifactBytecode(positionDescriptorArtifact as { bytecode: string | { object: string } }),
    deployerSigner,
  );
  const positionDescriptor = await descFactory.deploy(
    poolManagerAddress,
    mockWethResult.address,
    hre.ethers.encodeBytes32String("ETH"),
    { gasLimit: 8_000_000 },
  );
  await positionDescriptor.waitForDeployment();
  const positionDescriptorAddress = await positionDescriptor.getAddress();
  console.log("PositionDescriptor deployed to:", positionDescriptorAddress);

  // ── 7. PositionManager (from upstream foundry artifact) ──────────────────────
  // Manages ERC-721 liquidity positions and routes liquidity actions to PoolManager.
  const pmFactory = new hre.ethers.ContractFactory(
    positionManagerArtifact.abi,
    artifactBytecode(positionManagerArtifact as { bytecode: string | { object: string } }),
    deployerSigner,
  );
  const positionManager = await pmFactory.deploy(
    poolManagerAddress,
    mockPermit2Result.address,
    500_000n,               // unsubscribed subscription limit
    positionDescriptorAddress,
    mockWethResult.address,
    { gasLimit: 8_000_000 },
  );
  await positionManager.waitForDeployment();
  const positionManagerAddress = await positionManager.getAddress();
  console.log("PositionManager deployed to:", positionManagerAddress);

  // ── 8. RewardTokensManager ───────────────────────────────────────────────────
  // Our assignment contract: creates a PNPT/FNBT Uniswap v4 pool and mints
  // concentrated liquidity positions on behalf of callers.
  const rewardManagerResult = await deploy("RewardTokensManager", {
    from: deployer,
    args: [poolManagerAddress, positionManagerAddress, pnpResult.address, fnbResult.address],
    log: true,
    autoMine: true,
  });
  console.log("RewardTokensManager deployed to:", rewardManagerResult.address);
};

export default deployRewardTokens;
deployRewardTokens.tags = ["RewardTokensManager"];
