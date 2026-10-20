// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SLT} from "../src/SLT.sol";
import {IndexOracle} from "../src/IndexOracle.sol";
import {MintContract} from "../src/MintContract.sol";

/// @notice Mock 6-decimal USDC/USDT for Fuji testnet. Public mint for faucet-style use.
/// @dev    Anyone can mint these tokens — they exist only on Fuji and have zero economic value.
contract MockStableFuji is ERC20 {
    constructor(
        string memory name,
        string memory sym
    ) ERC20(name, sym) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Public mint for testing. Anyone can request tokens to test the SLT mint flow.
    function faucet(
        uint256 amount
    ) external {
        _mint(msg.sender, amount);
    }
}

/// @title DeployFuji
/// @notice Self-contained Fuji testnet deployment.
///         Deploys mock USDC/USDT, the full SLT V1 stack, wires roles and whitelists, and
///         leaves the deployer holding admin/pauser/guardian/updater roles for testing.
///
/// Required env vars:
///   - DEPLOYER_PRIVATE_KEY   (Fuji-only disposable wallet)
///   - INDEX_INITIAL          (1000000000000000000 = 1.0)
///   - MIN_MINT_AMOUNT        (1000000000 = $1,000)
///   - MAX_MINT_AMOUNT        (5000000000000 = $5,000,000)
///
/// Usage:
///   forge script script/DeployFuji.s.sol --rpc-url fuji --broadcast --verify
///
/// After deployment, all addresses are logged. Update .env.local in the dashboard with:
///   NEXT_PUBLIC_SLT_ADDRESS, NEXT_PUBLIC_MINT_CONTRACT_ADDRESS,
///   NEXT_PUBLIC_INDEX_ORACLE_ADDRESS, NEXT_PUBLIC_USDC_ADDRESS, NEXT_PUBLIC_USDT_ADDRESS.
contract DeployFuji is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 initialIndex = vm.envUint("INDEX_INITIAL");
        uint256 minMint = vm.envUint("MIN_MINT_AMOUNT");
        uint256 maxMint = vm.envUint("MAX_MINT_AMOUNT");

        require(block.chainid == 43113, "DeployFuji: not Fuji (43113)");
        address deployer = vm.addr(deployerKey);
        console2.log("===========================================");
        console2.log("SLT V1 Fuji Testnet Deployment");
        console2.log("===========================================");
        console2.log("Deployer / Treasury (test):", deployer);

        vm.startBroadcast(deployerKey);

        // 1. Mock USDC and USDT (Fuji-only).
        MockStableFuji usdc = new MockStableFuji("Test USD Coin", "tUSDC");
        MockStableFuji usdt = new MockStableFuji("Test Tether", "tUSDT");
        console2.log("Mock USDC:", address(usdc));
        console2.log("Mock USDT:", address(usdt));

        // 2. IndexOracle. Deployer = admin + guardian + updater (single-key test setup).
        IndexOracle oracle = new IndexOracle(initialIndex, deployer, deployer, deployer);
        console2.log("IndexOracle:", address(oracle));

        // 3. SLT. Deployer = admin + pauser.
        SLT slt = new SLT(deployer, deployer, address(oracle));
        console2.log("SLT:", address(slt));

        // 4. MintContract. Deployer = admin + pauser.
        address[] memory stables = new address[](2);
        stables[0] = address(usdc);
        stables[1] = address(usdt);
        MintContract mintContract =
            new MintContract(address(slt), address(oracle), deployer, deployer, deployer, minMint, maxMint, stables);
        console2.log("MintContract:", address(mintContract));

        // 5. Wire roles (whitelist seeded in constructor, H-1; deployer has admin authority on Fuji).
        slt.grantRole(slt.MINTER_ROLE(), address(mintContract));

        // Verify before the one-way locks (mirrors mainnet runbook step 2).
        require(slt.minterCount() == 1 && slt.hasRole(slt.MINTER_ROLE(), address(mintContract)), "minter wiring");
        require(slt.burnSourceCount() == 1 && slt.authorizedBurnSource(deployer), "burn source wiring");

        // v1.1-audit lock sequence (one-way, mirrors mainnet runbook steps 3-4).
        slt.lockMinterRole(address(mintContract)); // H-01 / L-04 / M-4
        slt.lockBurnSource(deployer); // M-01 / M-3

        // 6. Mint some test stable to the deployer for an initial mint smoke test.
        usdc.faucet(10_000 * 1e6); // $10,000 tUSDC
        usdt.faucet(10_000 * 1e6); // $10,000 tUSDT

        vm.stopBroadcast();

        console2.log("===========================================");
        console2.log("DEPLOYMENT COMPLETE");
        console2.log("===========================================");
        console2.log("Roles wired:");
        console2.log("  - SLT.MINTER_ROLE granted to MintContract");
        console2.log("  - MintContract whitelisted tUSDC + tUSDT");
        console2.log("  - SLT.lockMinterRole(MintContract) + SLT.lockBurnSource(treasury) executed (one-way)");
        console2.log("  - Deployer holds: ORACLE_UPDATER, GUARDIAN, ADMIN, PAUSER, BURNER, CONFIG");
        console2.log("");
        console2.log("Add these to dashboard .env.local:");
        console2.log("NEXT_PUBLIC_CHAIN_ID=43113");
        console2.log("NEXT_PUBLIC_SLT_ADDRESS=", address(slt));
        console2.log("NEXT_PUBLIC_MINT_CONTRACT_ADDRESS=", address(mintContract));
        console2.log("NEXT_PUBLIC_INDEX_ORACLE_ADDRESS=", address(oracle));
        console2.log("NEXT_PUBLIC_USDC_ADDRESS=", address(usdc));
        console2.log("NEXT_PUBLIC_USDT_ADDRESS=", address(usdt));
        console2.log("");
        console2.log("Snowtrace:");
        console2.log("  https://testnet.snowtrace.io/address/", address(slt));
        console2.log("  https://testnet.snowtrace.io/address/", address(mintContract));
        console2.log("  https://testnet.snowtrace.io/address/", address(oracle));
    }
}
