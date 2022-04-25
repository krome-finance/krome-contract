// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// MAY need to be updated
interface IAMOMinter {
    function custodian_address() external view returns(address);
    function timelock_address() external view returns(address);

    function burnUsdkFromAMO(uint256 usdk_amount) external;
    function burnKromeFromAMO(uint256 krome_amount) external;

    function mintUsdkForAMO(address destination_amo, uint256 usdk_amount) external;
    function mintKromeForAMO(address destination_amo, uint256 krome_amount) external;

    function giveCollatToAMO(address destination_amo, uint256 collat_amount) external;
    function receiveCollatFromAMO(uint256 collat_amount) external;

    function collateral_address() external view returns(address);
    function missing_decimals() external view returns(uint256);
    function col_idx() external view returns(uint256);
}