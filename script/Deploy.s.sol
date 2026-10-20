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
        // Oracle updater: the Chainlink/attester adapter key. Never leave it on the deployer hot key (L-3).
        address oracleUpdater = vm.envAddress("ORACLE_UPDATER_ADDRESS");

        require(block.chainid == 43114, "Deploy: not Avalanche C-Chain (43114)");
        require(treasurySafe.code.length > 0, "Deploy: TREASURY_SAFE_ADDRESS has no code (not a Safe?)");
        require(usdc.code.length > 0 && usdt.code.length > 0, "Deploy: stablecoin address has no code");
        require(oracleUpdater != address(0), "Deploy: ORACLE_UPDATER_ADDRESS unset");

        address deployer = vm.addr(deployerKey);
        console2.log("Deployer:", deployer);
        console2.log("Treasury Safe:", treasurySafe);
        console2.log("Oracle updater:", oracleUpdater);

        vm.startBroadcast(deployerKey);

        // 1. Deploy IndexOracle.
        //    Admin = treasurySafe (Safe controls config).
        //    Guardian = treasurySafe (Safe can pause).
        //    Updater = ORACLE_UPDATER_ADDRESS (adapter key), never the deployer hot key (L-3).
        IndexOracle oracle = new IndexOracle(initialIndex, treasurySafe, treasurySafe, oracleUpdater);
        console2.log("IndexOracle:", address(oracle));

        // 2. Deploy SLT.
        //    Admin = treasurySafe (Safe is BURNER).
        //    Pauser = treasurySafe (Safe can emergency-pause transfers).
        SLT slt = new SLT(treasurySafe, treasurySafe, address(oracle));
        console2.log("SLT:", address(slt));

        // 3. Deploy MintContract.
        //    Admin = treasurySafe.
        //    Pauser = treasurySafe.
        //    Stablecoins are seeded in the constructor (H-1): no instant whitelist path exists after deploy.
        address[] memory stables = new address[](2);
        stables[0] = usdc;
        stables[1] = usdt;
        MintContract mintContract = new MintContract(
            address(slt), address(oracle), treasurySafe, treasurySafe, treasurySafe, minMint, maxMint, stables
        );
        console2.log("MintContract:", address(mintContract));
        console2.log("Whitelisted at deploy: USDC", usdc);
        console2.log("Whitelisted at deploy: USDT", usdt);

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
        console2.log("  2. Verify: minterCount()==1, hasRole(MINTER_ROLE, MintContract), burnSourceCount()==1,");
        console2.log("             authorizedBurnSource(Safe)==true, acceptedStablecoin(USDC/USDT)==true");
        console2.log("  3. SLT.lockMinterRole(MintContract)  -- one-way (H-01 / L-04 / M-4)");
        console2.log("  4. SLT.lockBurnSource(Safe)          -- one-way (M-01 / M-3)");
        console2.log("  Later: setTreasurySafe(new) -> 24h -> executeTreasurySafe() (M-03);");
        console2.log("         setStablecoinAccepted(tok,true) -> 24h -> executeStablecoinAccepted(tok) (H-1)");
    }
}
