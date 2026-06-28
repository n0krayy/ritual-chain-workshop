import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("BountyJudgeModule", (m) => {
  // Default deadlines (in seconds from deploy time):
  //   submissionDeadline = now + 3 days
  //   revealDeadline     = now + 5 days (i.e. submission + 2 days)
  // To customize for production, deploy with custom parameters or use
  // scripts/createBounty.ts after deployment.

  const bountyJudge = m.contract("BountyJudge", [], {
    value: 0n,
  });

  return { bountyJudge };
});