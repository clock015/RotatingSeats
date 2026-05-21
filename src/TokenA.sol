// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";

contract TokenA is ERC20, ERC20Burnable, ERC20Permit, ERC20Votes {
    constructor()
        ERC20("Token A", "TKA")
        ERC20Permit("Token A") // <--- 这里必须传名称字符串
    {
        _mint(msg.sender, 1000000 * 1e18);
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(
        address owner
    ) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    function clock() public view virtual override returns (uint48) {
        return uint48(block.timestamp);
    }

    /**
     * @dev 告知外部工具（如 Etherscan 或客户端）此合约使用时间戳模式
     */
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public view virtual override returns (string memory) {
        return "mode=timestamp";
    }
}
