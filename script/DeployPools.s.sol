// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.7.6;
pragma abicoder v2;

import "forge-std/StdJson.sol";
import "forge-std/Script.sol";
import {CLFactory} from "contracts/core/CLFactory.sol";
import {IUniswapV3Factory} from "script/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "script/interfaces/IUniswapV3Pool.sol";
import "forge-std/console2.sol";

contract DeployPools is Script {
    using stdJson for string;

    uint256 public deployPrivateKey = vm.envUint("PRIVATE_KEY_DEPLOY");
    address public deployerAddress = vm.rememberKey(deployPrivateKey);
    string public constantsFilename = vm.envString("CONSTANTS_FILENAME");
    string public jsonConstants;
    string public jsonOutput;

    mapping(uint24 => int24) public feeToTickSpacing;
    IUniswapV3Factory public immutable v3Factory;

    CLFactory public factory;

    constructor() {
        // slipstream tick spacings
        feeToTickSpacing[100] = 1;
        // feeToTickSpacing[500] = 50; // duplicate
        feeToTickSpacing[500] = 100;
        feeToTickSpacing[3000] = 200;
        feeToTickSpacing[10_000] = 2_000;

        v3Factory = IUniswapV3Factory(0x30D9e1f894FBc7d2227Dd2a017F955d5586b1e14); // gobv1 uniswap v3 factory
    }

    function run() public {
        string memory root = vm.projectRoot();
        string memory basePath = concat(root, "/script/constants/");
        string memory path = concat(basePath, constantsFilename);

        // load in vars
        jsonConstants = vm.readFile(path);
        address[] memory tokenAs = abi.decode(jsonConstants.parseRaw(".tokenA"), (address[]));
        address[] memory tokenBs = abi.decode(jsonConstants.parseRaw(".tokenB"), (address[]));
        uint24[] memory fees = abi.decode(jsonConstants.parseRaw(".fees"), (uint24[]));

        path = concat(basePath, "output/DeployCL-");
        path = concat(path, constantsFilename);
        jsonOutput = vm.readFile(path);
        factory = CLFactory(abi.decode(jsonOutput.parseRaw(".PoolFactory"), (address)));

        vm.startBroadcast(deployerAddress);
        address pool;
        address newPool;
        for (uint256 i = 0; i < tokenAs.length; i++) {
            address tokenB = tokenBs[i] == address(0x62440594BE441fAec7F9fd4a3A8D1F4AD86E2987) ? address(0x701ACA29AE0F5d24555f1E8A6Cf007541291d110) : tokenBs[i]; // take gobv1 price for gobv2
            pool = v3Factory.getPool({tokenA: tokenAs[i], tokenB: tokenB, fee: 100});
            (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
            // uint160 sqrtPriceX96 = 79245593361322215068791885849;
            newPool = factory.createPool({
                tokenA: tokenAs[i],
                tokenB: tokenBs[i],
                tickSpacing: feeToTickSpacing[fees[i]],
                sqrtPriceX96: sqrtPriceX96
            });
            console2.log(newPool);
        }
        vm.stopBroadcast();
    }

    function concat(string memory a, string memory b) internal pure returns (string memory) {
        return string(abi.encodePacked(a, b));
    }
}
