const hre = require("hardhat");

async function main() {
  const Project = await hre.ethers.getContractFactory("Project");
  const project = await Project.deploy();
  await project.waitForDeployment();
  console.log(`ProofChain contract deployed to: ${project.target}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
