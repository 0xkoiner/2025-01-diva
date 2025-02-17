// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IWToken} from "./interfaces/IWToken.sol";

/**
 * @dev See {IWToken}.
 */
 // @audit-medium: Missconfusing of owner. If owner of WTOKEN is same owner of AaveDIVAWrapperCore, it should be passed as parameter in constructor
contract WToken is IWToken, ERC20 {
    address private _owner; // address(this) // @audit-question: why not to do immutable _owner? no function to change!!
    uint8 private _decimals; // @audit-question: why decimal here if have call decimal in IWToken?

    constructor(string memory symbol_, uint8 decimals_, address owner_) ERC20(symbol_, symbol_) {
        // audit-question: the symbol should be with prefix `W`?
        // audit-question: the name should be same as symbol?
        // name = symbol for simplicity
        _owner = owner_;
        _decimals = decimals_;
    }

    modifier onlyOwner() {
        require(_owner == msg.sender, "WToken: caller is not owner");
        _;
    }

    /**
     * @dev See {IWToken-mint}.
     */
    function mint(address _recipient, uint256 _amount) external override onlyOwner {
        _mint(_recipient, _amount);
    }

    /**
     * @dev See {IWToken-burn}.
     */
    function burn(address _redeemer, uint256 _amount) external override onlyOwner {
        _burn(_redeemer, _amount);
    }

    /**
     * @dev See {IWToken-owner}.
     */
    function owner() external view override returns (address) {
        return _owner;
    }

    /**
     * @dev See {IWToken-decimals}.
     */
    function decimals() public view override(ERC20, IWToken) returns (uint8) {
        return _decimals;
    }
}
