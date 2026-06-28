// Direct deploy via Viem — bypass Hardhat Ignition's interactive prompts.
// Useful for CI / non-interactive deploys.
import { createWalletClient, http, createPublicClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import artifact from "../artifacts/contracts/BountyJudge.sol/BountyJudge.json" with { type: "json" };

const DEPLOYER_KEY = process.env.DEPLOYER_PRIVATE_KEY;
if (!DEPLOYER_KEY) {
  console.error("DEPLOYER_PRIVATE_KEY env required");
  process.exit(1);
}

const account = privateKeyToAccount(`0x${DEPLOYER_KEY}`);
console.log("Deployer address:", account.address);

const transport = http("https://rpc.ritualfoundation.org");
const publicClient = createPublicClient({ transport });
const walletClient = createWalletClient({ account, transport });

const chainId = await publicClient.getChainId();
console.log("Chain ID:", chainId);

const balance = await publicClient.getBalance({ address: account.address });
console.log("Balance:", balance.toString(), "wei");

const nonce = await publicClient.getTransactionCount({ address: account.address });
console.log("Nonce:", nonce);

console.log("Sending deploy tx...");
const txHash = await walletClient.deployContract({
  abi: artifact.abi,
  bytecode: artifact.bytecode,
  args: [],
});

console.log("Deploy tx hash:", txHash);

console.log("Waiting for receipt...");
const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
console.log("Deploy status:", receipt.status === "success" ? "SUCCESS" : "FAILED");
console.log("Contract address:", receipt.contractAddress);
console.log("Block number:", receipt.blockNumber.toString());
console.log("Gas used:", receipt.gasUsed.toString());