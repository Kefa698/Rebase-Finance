async function main() {
    const Accumulator = await ethers.getContractFactory("Rebase")

    // Start deployment, returning a promise that resolves to a contract object
    const accumulator = await Accumulator.deploy({ gasLimit: 1000})
    await accumulator.deployed()
    console.log("Contract deployed to address:", accumulator.address)
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error)
        process.exit(1)
    })
