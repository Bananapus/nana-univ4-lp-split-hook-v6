// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

/// @notice Sanity test: each chain's PositionManager address declared in `Deploy.s.sol::_getPositionManager()`
/// must have deployed bytecode on the live network. The pre-fix script hardcoded the mainnet PositionManager
/// for Sepolia, Base Sepolia, and Arbitrum Sepolia, which does not exist on those testnets.
/// @dev Tests use `vm.try_createSelectFork` semantics via try/catch so missing RPC env vars do not fail CI.
contract DeployPositionManagerAddressesForkTest is Test {
    address internal constant MAINNET_PM = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address internal constant OPTIMISM_PM = 0x3C3Ea4B57a46241e54610e5f022E5c45859A1017;
    address internal constant BASE_PM = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address internal constant ARBITRUM_PM = 0xd88F38F930b7952f2DB2432Cb002E7abbF3dD869;
    address internal constant SEPOLIA_PM = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;
    address internal constant BASE_SEPOLIA_PM = 0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80;
    address internal constant ARBITRUM_SEPOLIA_PM = 0xAc631556d3d4019C95769033B5E719dD77124BAc;

    function _assertHasCode(string memory chainName, address pm, uint256 forkBlock) internal {
        // Pin chains that already have a stable fork block in this suite. Some CI RPCs lag their advertised latest
        // block, and an unpinned fork can fail before the bytecode assertion runs.
        if (forkBlock == 0) {
            try vm.createSelectFork(chainName) {
                _assertCodeAt({chainName: chainName, pm: pm});
            } catch {
                vm.skip(true);
            }
        } else {
            try vm.createSelectFork(chainName, forkBlock) {
                _assertCodeAt({chainName: chainName, pm: pm});
            } catch {
                vm.skip(true);
            }
        }
    }

    function _assertCodeAt(string memory chainName, address pm) internal view {
        uint256 size;
        assembly {
            size := extcodesize(pm)
        }
        assertGt(size, 0, string.concat("PositionManager has no code on ", chainName));
    }

    function test_fork_mainnetPositionManager() public {
        _assertHasCode("ethereum", MAINNET_PM, 21_700_000);
    }

    function test_fork_optimismPositionManager() public {
        _assertHasCode("optimism", OPTIMISM_PM, 0);
    }

    function test_fork_basePositionManager() public {
        _assertHasCode("base", BASE_PM, 0);
    }

    function test_fork_arbitrumPositionManager() public {
        _assertHasCode("arbitrum", ARBITRUM_PM, 0);
    }

    function test_fork_sepoliaPositionManager() public {
        _assertHasCode("ethereum_sepolia", SEPOLIA_PM, 0);
    }

    function test_fork_baseSepoliaPositionManager() public {
        _assertHasCode("base_sepolia", BASE_SEPOLIA_PM, 0);
    }

    function test_fork_arbitrumSepoliaPositionManager() public {
        _assertHasCode("arbitrum_sepolia", ARBITRUM_SEPOLIA_PM, 0);
    }
}
