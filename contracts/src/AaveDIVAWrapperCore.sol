// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IDIVA} from "./interfaces/IDIVA.sol";
import {IAaveDIVAWrapper} from "./interfaces/IAaveDIVAWrapper.sol";
import {IAave} from "./interfaces/IAave.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IWToken} from "./interfaces/IWToken.sol";
import {WToken} from "./WToken.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @dev An abstract contract that inherits from `IAaveDIVAWrapper` and implements the core
 * functions of the AaveDIVAWrapper contract as internal functions.
 */
abstract contract AaveDIVAWrapperCore is IAaveDIVAWrapper, Ownable2Step {
    using SafeERC20 for IERC20Metadata;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // Addresses of DIVA Protocol and Aave V3 (Pool contract) that this contract interacts with.
    // Set in the constructor and retrievable via `getContractDetails`.
    address private immutable _diva;
    address private immutable _aaveV3Pool; // Pool contract address

    /*//////////////////////////////////////////////////////////////
                                STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    // Mappings between collateral tokens (e.g., USDC or USDT) to their corresponding wTokens, which are used as
    // proxy collateral tokens in DIVA Protocol. Set by contract owner via `registerCollateralToken`.
    mapping(address => address) private _collateralTokenToWToken;
    mapping(address => address) private _wTokenToCollateralToken;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Initializes the AaveDIVAWrapper contract with the addresses of DIVA Protocol, Aave V3's Pool
     * contract and the owner of the contract.
     * @param diva_ Address of the DIVA Protocol contract.
     * @param aaveV3Pool_ Address of the Aave V3 Pool contract.
     * @param owner_ Address of the owner for the contract, who will be entitled to claim the yield.
     * Retrievable via Ownable's `owner()` function or this contract's `getContractDetails` functions.
     */
    constructor(address diva_, address aaveV3Pool_, address owner_) Ownable(owner_) {
        // Validate that none of the input addresses is zero to prevent unintended initialization with default addresses.
        // Zero address check on `owner_` is performed in the OpenZeppelin's `Ownable` contract.
        if (diva_ == address(0) || aaveV3Pool_ == address(0)) {
            revert ZeroAddress();
        }

        // Store the addresses of DIVA Protocol and Aave V3 in storage.
        _diva = diva_;
        _aaveV3Pool = aaveV3Pool_;
    }

    /*//////////////////////////////////////////////////////////////
                        STATE MODIFYING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev See {IAaveDIVAWrapper-registerCollateralToken}.
     */
    function _registerCollateralToken(address _collateralToken) internal returns (address) {
        // Verify that the collateral token is not yet registered.
        if (_collateralTokenToWToken[_collateralToken] != address(0)) {
            revert CollateralTokenAlreadyRegistered();
        }

        // Retrieve the aToken address associated with the provided collateral token from Aave V3. Reverts if
        // the collateral token is not supported by Aave V3.
        // Note: aTokens have the same number of decimals as the collateral token: https://discord.com/channels/602826299974877205/636902500041228309/1249607036417867810
        address _aToken = _getAToken(_collateralToken);
        if (_aToken == address(0)) {
            revert UnsupportedCollateralToken();
        }

        IERC20Metadata _collateralTokenContract = IERC20Metadata(_collateralToken);

        // Deploy a token that represents a wrapped version of the collateral token to be used as proxy collateral in DIVA Protocol.
        // The symbol and name of the wToken are derived from the original collateral token, prefixed with 'w' (e.g., wUSDT or wUSDC).
        // This naming convention helps in identifying the token as a wrapped version of the original collateral token.
        // The wToken decimals are aligned with those of the collateral token and the aToken.
        // This contract is set as the owner and has exclusive rights to mint and burn the wToken.
        WToken _wTokenContract = new WToken(
            string(abi.encodePacked("w", _collateralTokenContract.symbol())),// @audit-low: Symbol and Name in ERC20 will be the same!
            _collateralTokenContract.decimals(),
            address(this) // wToken owner // probably the owner will be this contract
        );

        address _wToken = address(_wTokenContract);

        // Map collateral token to its corresponding wToken.
        _collateralTokenToWToken[_collateralToken] = _wToken;

        // Map wToken to its corresponding collateral token to facilitate reverse lookups.
        _wTokenToCollateralToken[_wToken] = _collateralToken;

        // Set unlimited approval for the wToken transfer to DIVA Protocol and the collateral token transfer to Aave V3. This setup reduces
        // the need for repeated approval transactions, thereby saving on gas costs.
        // The unlimited approvals are deemed safe as the `AaveDIVAWrapper` is a pass-through entity that does not hold excess wTokens or collateral tokens.
        // Should a vulnerability be discovered in DIVA Protocol or Aave, users can simply stop interacting with the `AaveDIVAWrapper` contract.
        //
        // Note that granting an infinite allowance for wToken does not reduce the allowance on `transferFrom` as it uses a newer OpenZeppelin ERC20 implementation.
        // However, this behavior may differ for collateral tokens like USDC, DAI, or WETH used in Aave. These tokens decrement the allowance with each use of
        // `transferFrom`, even if an unlimited allowance is set. Consequently, though very unlikely, AaveDIVAWrapper could eventually exhaust its allowance.
        // The `approveCollateralTokenForAave` function has been implemented to manually reset the allowance to unlimited.
        _wTokenContract.approve(_diva, type(uint256).max);
        _collateralTokenContract.approve(_aaveV3Pool, type(uint256).max);

        emit CollateralTokenRegistered(_collateralToken, _wToken);

        return _wToken;
    }

    /**
     * @dev See {IAaveDIVAWrapper-createContingentPool}.
     */
    function _createContingentPool(PoolParams calldata _poolParams) internal returns (bytes32) {
        address _wToken = _collateralTokenToWToken[_poolParams.collateralToken];
        // Confirm that the provided collateral token is registered. This check is performed early
        // to ensure an immediate and graceful revert rather than allowing execution to continue until the `mint`
        // operation at the end of the `_handleTokenOperations` function, which would then fail when attempting to call
        // the `mint` function on address(0).
        if (_wToken == address(0)) {
            revert CollateralTokenNotRegistered();
        }

        // Transfer collateral token from caller to this contract, supply to Aave, and mint wTokens.
        // Requires prior approval by the caller to transfer the collateral token to the AaveDIVAWrapper contract.
        _handleTokenOperations(_poolParams.collateralToken, _poolParams.collateralAmount, _wToken);

        // Create pool on DIVA Protocol using the wToken as collateral.
        bytes32 _poolId = IDIVA(_diva).createContingentPool(
            IDIVA.PoolParams({
                referenceAsset: _poolParams.referenceAsset,
                expiryTime: _poolParams.expiryTime,
                floor: _poolParams.floor,
                inflection: _poolParams.inflection,
                cap: _poolParams.cap,
                gradient: _poolParams.gradient,
                collateralAmount: _poolParams.collateralAmount,
                collateralToken: _collateralTokenToWToken[_poolParams.collateralToken],// @audit-question: Why not using directly _wToken // Using the address of the wToken here
                dataProvider: _poolParams.dataProvider,
                capacity: _poolParams.capacity,
                longRecipient: _poolParams.longRecipient,
                shortRecipient: _poolParams.shortRecipient,
                permissionedERC721Token: _poolParams.permissionedERC721Token
            })
        );

        emit PoolIssued(_poolId);

        return _poolId;
    }

    /**
     * @dev See {IAaveDIVAWrapper-addLiquidity}.
     */
    function _addLiquidity(
        bytes32 _poolId,
        uint256 _collateralAmount,
        address _longRecipient,
        address _shortRecipient
    ) internal {
        // Verify that the collateral token used in the DIVA Protocol pool corresponds to a registered
        // collateral token in the AaveDIVAWrapper contract. Returns zero address if the wToken is not registered.
        IDIVA.Pool memory _pool = IDIVA(_diva).getPoolParameters(_poolId);
        address _collateralToken = _wTokenToCollateralToken[_pool.collateralToken];

        // Confirm that the collateral token is registered. This check is performed early
        // to ensure an immediate and graceful revert rather than allowing execution to continue until the `mint`
        // operation at the end of the `_handleTokenOperations` function, which would then fail when attempting to call
        // the `mint` function on address(0).
        if (_collateralToken == address(0)) {
            revert CollateralTokenNotRegistered();
        }

        // Transfer collateral token from caller to this contract, supply to Aave, and mint wTokens
        // to this contract.
        _handleTokenOperations(_collateralToken, _collateralAmount, _pool.collateralToken);

        // Add liquidity to the DIVA Protocol pool associated with the provided `_poolId`
        // using the wToken and send the position tokens to the provided recipients.
        IDIVA(_diva).addLiquidity(_poolId, _collateralAmount, _longRecipient, _shortRecipient);
    }

    /**
     * @dev See {IAaveDIVAWrapper-removeLiquidity}.
     */
    function _removeLiquidity(
        bytes32 _poolId,
        uint256 _positionTokenAmount,
        address _recipient
    ) internal returns (uint256) {
        // Query pool parameters to obtain the collateral token as well as the
        // short and long token addresses.
        IDIVA.Pool memory _pool = IDIVA(_diva).getPoolParameters(_poolId);

        // Early check that the pool's collateral token is associated with a registered collateral token.
        // This ensures an immediate and graceful revert.
        if (_wTokenToCollateralToken[_pool.collateralToken] == address(0)) {
            revert CollateralTokenNotRegistered();
        }

        IERC20Metadata _shortTokenContract = IERC20Metadata(_pool.shortToken);
        IERC20Metadata _longTokenContract = IERC20Metadata(_pool.longToken);
        IERC20Metadata _collateralTokenContract = IERC20Metadata(_pool.collateralToken);

        // Use the user's min short/long token balance if `_positionTokenAmount` equals `type(uint256).max`.
        // That corresponds to the maximum amount that the user can remove from the pool.
        uint256 _userBalanceShort = _shortTokenContract.balanceOf(msg.sender);
        uint256 _userBalanceLong = _longTokenContract.balanceOf(msg.sender);
        uint256 _positionTokenAmountToRemove = _positionTokenAmount;
        if (_positionTokenAmount == type(uint256).max) {
            _positionTokenAmountToRemove = _userBalanceShort > _userBalanceLong ? _userBalanceLong : _userBalanceShort;
        }

        // Transfer short and long tokens from user to this contract. Requires prior user approval on both tokens.
        // No need to use `safeTransferFrom` here as short and long tokens in DIVA Protocol are standard ERC20 tokens
        // using OpenZeppelin's ERC20 implementation.
        _shortTokenContract.transferFrom(msg.sender /** from */, address(this) /** to */, _positionTokenAmountToRemove);
        _longTokenContract.transferFrom(msg.sender /** from */, address(this) /** to */, _positionTokenAmountToRemove);

        // Remove liquidity on DIVA Protocol to receive wTokens, and calculate the returned wToken amount (net of DIVA fees)
        // as DIVA Protocol's removeLiquidity function does not return the amount of collateral token received.
        uint256 _wTokenBalanceBeforeRemoveLiquidity = _collateralTokenContract.balanceOf(address(this));
        IDIVA(_diva).removeLiquidity(_poolId, _positionTokenAmountToRemove);
        uint256 _wTokenAmountReturned = _collateralTokenContract.balanceOf(address(this)) -
            _wTokenBalanceBeforeRemoveLiquidity;

        // Conscious decision to omit an early zero amount check here as it will either revert inside `removeLiquidity` due to
        // zero DIVA fees (if DIVA fee pct != 0) or in the subsequent call to Aave's `withdraw` function inside `_redeemWTokenPrivate`.

        // Withdraw collateral token from Aave, burn wTokens owned by this contract and transfer collateral token to `_recipient`.
        uint256 _amountReturned = _redeemWTokenPrivate(
            _pool.collateralToken, // wToken
            _wTokenAmountReturned,
            _recipient,
            address(this)
        );

        return _amountReturned;
    }

    /**
     * @dev See {IAaveDIVAWrapper-redeemPositionToken}.
     */
    function _redeemPositionToken(
        address _positionToken,
        uint256 _positionTokenAmount,
        address _recipient
    ) internal returns (uint256) {
        // Query pool parameters to obtain the collateral token address associated with the
        // provided short or long token address (_positionToken).
        IDIVA.Pool memory _pool = IDIVA(_diva).getPoolParametersByAddress(_positionToken);

        // Early check that the pool's collateral token is associated with a registered collateral token.
        // This ensures an immediate and graceful revert.
        if (_wTokenToCollateralToken[_pool.collateralToken] == address(0)) {
            revert CollateralTokenNotRegistered();
        }

        IERC20Metadata _positionTokenContract = IERC20Metadata(_positionToken);
        IERC20Metadata _collateralTokenContract = IERC20Metadata(_pool.collateralToken);

        // Use the user's balance if `_positionTokenAmount` equals `type(uint256).max`.
        uint256 _userBalance = _positionTokenContract.balanceOf(msg.sender);
        uint256 _positionTokenAmountToRedeem = _positionTokenAmount;
        if (_positionTokenAmount == type(uint256).max) {
            _positionTokenAmountToRedeem = _userBalance;
        }

        // Transfer position token (long or short) from caller to this contract. Requires prior approval from the caller
        // to transfer the position token to this contract.
        // No need to use `safeTransferFrom` here as position tokens in DIVA Protocol are standard ERC20 tokens
        // using OpenZeppelin's ERC20 implementation.
        _positionTokenContract.transferFrom(
            msg.sender /** from */,
            address(this) /** to */,
            _positionTokenAmountToRedeem
        );

        // Redeem position token on DIVA Protocol to receive wTokens, and calculate the returned wToken amount (net of DIVA fees)
        // as DIVA Protocol's redeemPositionToken function does not return the amount of collateral token received.
        uint256 _wTokenBalanceBeforeRedeem = _collateralTokenContract.balanceOf(address(this));
        IDIVA(_diva).redeemPositionToken(_positionToken, _positionTokenAmountToRedeem);
        uint256 _wTokenAmountReturned = _collateralTokenContract.balanceOf(address(this)) - _wTokenBalanceBeforeRedeem;

        // Conscious decision to omit an early zero amount check here as it will either revert inside `redeemPositionToken` due to
        // zero DIVA fees or in the subsequent call to Aave's `withdraw` function inside `_redeemWTokenPrivate`.

        // Withdraw collateral token from Aave, burn wTokens owned by this contract and transfer collateral token to `_recipient`.
        uint256 _amountReturned = _redeemWTokenPrivate(
            _pool.collateralToken, // wToken
            _wTokenAmountReturned,
            _recipient,
            address(this)
        );

        return _amountReturned;
    }

    /**
     * @dev See {IAaveDIVAWrapper-redeemWToken}.
     */
    function _redeemWToken(address _wToken, uint256 _wTokenAmount, address _recipient) internal returns (uint256) {
        // Note: wTokens are not transferred to this contract. Instead, they are burnt from the caller's balance by this contract,
        // which has the authority to do so as the owner of the wToken. Therefore, no prior approval from the caller is needed.

        // Use the user's balance if `_wTokenAmount` equals `type(uint256).max`
        uint256 _userBalance = IERC20Metadata(_wToken).balanceOf(msg.sender);
        uint256 _wTokenAmountToRedeem = _wTokenAmount;
        if (_wTokenAmount == type(uint256).max) {
            _wTokenAmountToRedeem = _userBalance;
        }

        // Withdraw collateral token from Aave, burn wTokens and transfer collateral token to `_recipient`.
        // Reverts inside the wToken's burn function if the `_wTokenAmountToRedeem` exceeds the user's wToken balance.
        uint256 _amountReturned = _redeemWTokenPrivate(_wToken, _wTokenAmountToRedeem, _recipient, msg.sender);

        return _amountReturned;
    }

    /**
     * @dev See {IAaveDIVAWrapper-claimYield}.
     */
    function _claimYield(address _collateralToken, address _recipient) internal returns (uint256) {
        // Confirm that the collateral token is registered
        if (_collateralTokenToWToken[_collateralToken] == address(0)) {
            revert CollateralTokenNotRegistered();
        }

        if (_recipient == address(0)) revert ZeroAddress();

        // Redeem aToken for collateral token at Aave Protocol and send collateral token to recipient.
        uint256 _amountReturned = IAave(_aaveV3Pool).withdraw(
            _collateralToken, // Address of the underlying asset (e.g., USDT), not the aToken.
            _getAccruedYieldPrivate(_collateralToken), // Amount to withdraw.
            _recipient // Address that will receive the underlying asset.
        );

        emit YieldClaimed(owner(), _recipient, _collateralToken, _amountReturned);

        return _amountReturned;
    }

    /**
     * @dev See {IAaveDIVAWrapper-approveCollateralTokenForAave}.
     */
    function _approveCollateralTokenForAave(address _collateralToken) internal {
        // Ensure the collateral token is registered before setting approval.
        if (_collateralTokenToWToken[_collateralToken] == address(0)) {
            revert CollateralTokenNotRegistered();
        }
        uint256 currentAllowance = IERC20Metadata(_collateralToken).allowance(address(this), _aaveV3Pool);
        // Using OpenZeppelin's `safeIncreaseAllowance` to accommodate tokens like USDT on Ethereum that
        // require the approval to be set to zero before setting it to a non-zero value.
        IERC20Metadata(_collateralToken).safeIncreaseAllowance(_aaveV3Pool, type(uint256).max - currentAllowance);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev See {IAaveDIVAWrapper-getAccruedYield}.
     */
    function _getAccruedYield(address _collateralToken) internal view returns (uint256) {
        // Return 0 if collateral token is not registered
        if (_collateralTokenToWToken[_collateralToken] == address(0)) {
            return 0;
        }
        return _getAccruedYieldPrivate(_collateralToken);
    }

    /**
     * @dev See {IAaveDIVAWrapper-getContractDetails}.
     */
    function _getContractDetails() internal view returns (address, address, address) {
        return (_diva, _aaveV3Pool, owner());
    }

    /**
     * @dev See {IAaveDIVAWrapper-getWToken}.
     */
    function _getWToken(address _collateralToken) internal view returns (address) {
        return _collateralTokenToWToken[_collateralToken];
    }

    /**
     * @dev See {IAaveDIVAWrapper-getAToken}.
     */
    function _getAToken(address _collateralToken) internal view returns (address) {
        return IAave(_aaveV3Pool).getReserveData(_collateralToken).aTokenAddress;
    }

    /**
     * @dev See {IAaveDIVAWrapper-getCollateralToken}.
     */
    function _getCollateralToken(address _wToken) internal view returns (address) {
        return _wTokenToCollateralToken[_wToken];
    }

    /*//////////////////////////////////////////////////////////////
                        PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Transfers collateral token (e.g., USDT) from the caller to this contract, supplies it to Aave, and mints wTokens, to be used
     * as a proxy collateral token in DIVA Protocol. The amount of wTokens minted is equal to the amount of collateral token supplied (`_collateralAmount`).
     * @param _collateralToken The address of the collateral token to be transferred from the caller and supplied to Aave.
     * @param _collateralAmount The amount of the collateral token to be transferred from the caller and supplied to Aave.
     * @param _wToken The address of the wToken to be minted.
     */
    function _handleTokenOperations(address _collateralToken, uint256 _collateralAmount, address _wToken) private {
        // Transfer collateral token from the caller to this contract. Requires prior approval by the caller
        // to transfer the collateral token to the AaveDIVAWrapper contract.
        IERC20Metadata(_collateralToken).safeTransferFrom(msg.sender, address(this), _collateralAmount);

        // Supply the collateral token to Aave and receive aTokens. Approval to transfer the collateral token from this contract
        // to Aave was given when the collateral token was registered via `registerCollateralToken` or when the
        // allowance was set via `approveCollateralTokenForAave`.
        IAave(_aaveV3Pool).supply(
            _collateralToken, // Address of the asset to supply to the Aave reserve.
            _collateralAmount, // Amount of asset to be supplied.
            address(this), // Address that will receive the corresponding aTokens (`onBehalfOf`).
            0 // Referral supply is currently inactive, you can pass 0 as referralCode. This program may be activated in the future through an Aave governance proposal.
        );

        // Mint wTokens associated with the supplied asset, used as a proxy collateral token in DIVA Protocol.
        // Only this contract is authorized to mint wTokens.
        IWToken(_wToken).mint(address(this), _collateralAmount);
    }

    /**
     * @dev Handles the withdrawal of assets from Aave, burns the corresponding amount of wTokens,
     * and transfers the withdrawn assets to a specified `_recipient`.
     * @param _wToken The address of the wToken to withdraw.
     * @param _wTokenAmount The amount of wTokens to withdraw. If `type(uint256).max`, the user's balance will be used.
     * @param _recipient The address that will receive the withdrawn asset.
     * @param _burnFrom The address that the wTokens will be burned from.
     * @return _amountReturned The actual amount of the collateral token withdrawn and transferred.
     */
    function _redeemWTokenPrivate(
        address _wToken,
        uint256 _wTokenAmount,
        address _recipient,
        address _burnFrom
    ) private returns (uint256) {
        if (_recipient == address(0)) revert ZeroAddress();

        // Burn the specified amount of wTokens. Only this contract has the authority to do so.
        // Reverts if `_wTokenAmount` exceeds the user's wToken balance.
        IWToken(_wToken).burn(_burnFrom, _wTokenAmount);

        address _collateralToken = _wTokenToCollateralToken[_wToken];

        // Withdraw the collateral asset from Aave, which burns the equivalent amount of aTokens owned by this contract.
        // E.g. User has 100 aUSDC, calls withdraw() and receives 100 USDC, burning the 100 aUSDC.
        // Collateral token is transferred to `_recipient`.
        // Reverts if the collateral token is not a registered wToken (first parameter will be address(0)).
        uint256 _amountReturned = IAave(_aaveV3Pool).withdraw(
            _collateralToken, // Address of the underlying asset (e.g., USDT), not the aToken.
            _wTokenAmount, // Amount to withdraw.
            _recipient // Address that will receive the underlying asset.
        );

        emit WTokenRedeemed(_wToken, _wTokenAmount, _collateralToken, _amountReturned, _recipient);

        return _amountReturned;
    }

    function _getAccruedYieldPrivate(address _collateralToken) private view returns (uint256) {
        uint256 aTokenBalance = IERC20Metadata(IAave(_aaveV3Pool).getReserveData(_collateralToken).aTokenAddress)
            .balanceOf(address(this));
        uint256 wTokenSupply = IERC20Metadata(_collateralTokenToWToken[_collateralToken]).totalSupply();

        // Handle case where the aToken balance might be smaller than the wToken supply (e.g., due to rounding).
        // In that case, the owner should just wait until yield accrues.
        return aTokenBalance > wTokenSupply ? aTokenBalance - wTokenSupply : 0;
    }
}
