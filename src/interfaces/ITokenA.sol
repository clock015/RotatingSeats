// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @dev 针对 Token A 的接口
 */
interface ITokenA is IERC20 {
    /**
     * @notice 销毁指定账户的代币
     * @param account 被销毁代币的持有者
     * @param amount 销毁数量
     */
    function burnFrom(address account, uint256 amount) external;
}
