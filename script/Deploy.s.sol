// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {SLT} from "../src/SLT.sol";
import {IndexOracle} from "../src/IndexOracle.sol";
import {MintContract} from "../src/MintContract.sol";

/// @title Deploy
/// @notice Deploys the full SLT V1 stack to Avalanche C-Chain (or Fuji testnet).
///
/// Required env vars:
///   - DEPLOYER_PRIVATE_KEY (do NOT commit; prefer hardware wallet / KMS in prod)
///   - TREASURY_SAFE_ADDRESS  (Gnosis Safe deployed via UI before this script)
///   - INDEX_INITIAL          (1000000000000000000 = 1.0)
///   - MIN_MINT_AMOUNT        (1000000000 = $1,000 with 6 decimals)
///   - MAX_MINT_AMOUNT        (5000000000000 = $5,000,000)
///   - USDC_ADDRESS, USDT_ADDRESS  (canonical Avalanche stablecoins)
///
/// Usage:
///   forge script script/Deploy.s.sol --rpc-url avalanche --broadcast --verify
contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address treasurySafe = vm.envAddress("TREASURY_SAFE_ADDRESS");
        uint256 initialIndex = vm.envUint("INDEX_INITIAL");
        uint256 minMint = vm.envUint("MIN_MINT_AMOUNT");
        uint256 maxMint = vm.envUint("MAX_MINT_AMOUNT");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address usdt = vm.envAddress("USDT_ADDRESS");

        address deployer = vm.addr(deployerKey);
        console2.log("Deployer:", deployer);
        console2.log("Treasury Safe:", treasurySafe);

        vm.startBroadcast(deployerKey);

        // 1. Deploy IndexOracle.
        //    Admin = treasurySafe (Safe controls config).
        //    Guardian = treasurySafe (Safe can pause).
        //    Updater = deployer (rotated to Chainlink adapter post-deploy).
        IndexOracle oracle = new IndexOracle(initialIndex, treasurySafe, treasurySafe, deployer);
        console2.log("IndexOracle:", address(oracle));

        // 2. Deploy SLT.
        //    Admin = treasurySafe (Safe is BURNER).
        //    Pauser = treasurySafe (Safe can emergency-pause transfers).
        SLT slt = new SLT(treasurySafe, treasurySafe, address(oracle));
        console2.log("SLT:", address(slt));

        // 3. Deploy MintContract.
        //    Admin = treasurySafe.
        //    Pauser = treasurySafe.
        MintContract mintContract =
            new MintContract(address(slt), address(oracle), treasurySafe, treasurySafe, treasurySafe, minMint, maxMint);
        console2.log("MintContract:", address(mintContract));

        // 4. Deployer-managed bootstrap config (must be transferred away post-deploy).
        //    Whitelist canonical stablecoins. The admin role on MintContract is treasurySafe,
        //    but we need CONFIG_ROLE here. Grant it to the deployer temporarily, then revoke.
        //    NOTE: In production, do this via Safe transaction instead.
        bytes32 CONFIG_ROLE = mintContract.CONFIG_ROLE();
        bytes32 ADMIN_ROLE = mintContract.DEFAULT_ADMIN_ROLE();
        // The Safe is admin; deployer needs the Safe to grant CONFIG_ROLE. As a deployment-time
        // simplification, we assert the Safe holds admin rights, and skip whitelisting here.
        // Stablecoin whitelist will be set via Safe transaction post-deployment.
        require(mintContract.hasRole(ADMIN_ROLE, treasurySafe), "Safe must hold admin role");
        console2.log("USDC to whitelist via Safe tx:", usdc);
        console2.log("USDT to whitelist via Safe tx:", usdt);

        // 5. The MINTER_ROLE on SLT must be granted to MintContract via Safe transaction.
        //    Output what Safe needs to do.
        bytes32 MINTER_ROLE = slt.MINTER_ROLE();
        console2.log("Safe must grant MINTER_ROLE on SLT to MintContract:");
        console2.logBytes32(MINTER_ROLE);
        console2.log("MintContract address:", address(mintContract));

        vm.stopBroadcast();

        console2.log("--- DEPLOYMENT COMPLETE ---");
        console2.log("Next steps via Safe tx:");
        console2.log("  1. SLT.grantRole(MINTER_ROLE, MintContract)");
        console2.log("  2. MintContract.setStablecoinAccepted(USDC, true)");
        console2.log("  3. MintContract.setStablecoinAccepted(USDT, true)");
        console2.log("  4. IndexOracle: rotate ORACLE_UPDATER_ROLE from deployer to Chainlink adapter");
        console2.log("  5. SLT.lockMinterRole(MintContract)  -- seals minter set (H-01 / L-04), one-way");
        console2.log(
            "  6. SLT.lockBurnSource()              -- seals burn source = Treasury Safe (M-01), one-way; needs burnSourceCount()==1"
        );
        console2.log("  Treasury Safe changes: setTreasurySafe(new) -> wait 24h -> executeTreasurySafe() (M-03)");
    }
}
