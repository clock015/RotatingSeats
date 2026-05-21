// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";

contract SeatToken is ERC20, ERC20Permit, ERC20Votes {
    address public minter;

    constructor(
        string memory name,
        string memory symbol,
        address _minter
    )
        ERC20(name, symbol)
        ERC20Permit(name) // <--- 这里必须传 name
    {
        minter = _minter;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "Only minter");
        _mint(to, amount);
        if (delegates(to) == address(0)) {
            _delegate(to, to);
        }
    }

    // 必须重写 _update 以兼容 ERC20 和 ERC20Votes (OZ 5.x 标准)
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Votes) {
        if (from != address(0) && to != address(0)) revert("Non-transferable");
        super._update(from, to, value);
    }

    // 必须重写 nonces 以兼容 ERC20Permit 和 Nonces (OZ 5.x 标准)
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
