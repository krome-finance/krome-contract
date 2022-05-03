// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../Common/LocatorBasedProxyV2.sol";
import "../Libs/TransferHelper.sol";
import "../Usdk/IUsdkPool.sol";
import "../Usdk/IUsdkPoolV5.sol";

contract PoolMigratorAMOMinter is LocatorBasedProxyV2 {
    uint256 public col_idx;

    /* ========== MODIFIERS ========== */

    modifier onlyByManager() {
        managerPermissionRequired();
        _;
    }

    /* ========== INITIALIZER ========== */
    
    function initialize (
        address _locator
    ) public initializer {
        LocatorBasedProxyV2.initializeLocatorBasedProxy(_locator);
    }

    function collatDollarBalance() external pure returns (uint256 balance_tally) {
        return 0;
    }

    function migrate(address _pool_from, address _collateral, uint256 _col_idx, address _pool_to, uint256 _amount) external onlyByManager {
        IUsdkPool pool_from = IUsdkPool(_pool_from);
        require(pool_from.collateral_addresses(_col_idx) == _collateral, "collateral is not in idx");

        col_idx = _col_idx;
        pool_from.amoMinterBorrow(_amount);

        TransferHelper.safeTransfer(_collateral, _pool_to, _amount);
    }

    function migrateV5(address _pool_from, address _collateral, uint256 _col_idx, address _pool_to, uint256 _amount) external onlyByManager {
        IUsdkPoolV5 pool_from = IUsdkPoolV5(_pool_from);
        require(pool_from.collateral_addresses(_col_idx) == _collateral, "collateral is not in idx");

        col_idx = _col_idx;
        IUsdkPoolV5(pool_from).amoMinterBorrow(_col_idx, _amount);

        TransferHelper.safeTransfer(_collateral, _pool_to, _amount);
    }
}