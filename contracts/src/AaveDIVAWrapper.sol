// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AaveDIVAWrapperCore} from "./AaveDIVAWrapperCore.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract AaveDIVAWrapper is AaveDIVAWrapperCore, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _aaveV3Pool, address _diva, address _owner) AaveDIVAWrapperCore(_aaveV3Pool, _diva, _owner) {}

    /*//////////////////////////////////////////////////////////////
                        STATE MODIFYING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev See {IAaveDIVAWrapper-registerCollateralToken}.
     */
    function registerCollateralToken(
        address _collateralToken
    ) external override onlyOwner nonReentrant returns (address) {
        return _registerCollateralToken(_collateralToken);
    }

    /**
     * @dev See {IAaveDIVAWrapper-createContingentPool}.
     */
     // @audit-case: Check if i can call many times same function with same args.
    function createContingentPool(PoolParams calldata _poolParams) external override nonReentrant returns (bytes32) {
        return _createContingentPool(_poolParams);
    }

    /**
     * @dev See {IAaveDIVAWrapper-addLiquidity}.
     */
    function addLiquidity(
        bytes32 _poolId,
        uint256 _collateralAmount,
        address _longRecipient,
        address _shortRecipient
    ) external override nonReentrant {
        _addLiquidity(_poolId, _collateralAmount, _longRecipient, _shortRecipient);
    }

    /**
     * @dev See {IAaveDIVAWrapper-removeLiquidity}.
     */
    function removeLiquidity(
        bytes32 _poolId,
        uint256 _positionTokenAmount,
        address _recipient
    ) external override nonReentrant returns (uint256) {
        return _removeLiquidity(_poolId, _positionTokenAmount, _recipient);
    }

    /**
     * @dev See {IAaveDIVAWrapper-redeemPositionToken}.
     */
    function redeemPositionToken(
        address _positionToken,
        uint256 _positionTokenAmount,
        address _recipient
    ) external override nonReentrant returns (uint256) {
        return _redeemPositionToken(_positionToken, _positionTokenAmount, _recipient);
    }

    /**
     * @dev See {IAaveDIVAWrapper-redeemWToken}.
     */
    function redeemWToken(
        address _wToken,
        uint256 _wTokenAmount,
        address _recipient
    ) external override nonReentrant returns (uint256) {
        return _redeemWToken(_wToken, _wTokenAmount, _recipient);
    }

    /**
     * @dev See {IAaveDIVAWrapper-claimYield}.
     */
    function claimYield(
        address _collateralToken,
        address _recipient
    ) external override onlyOwner nonReentrant returns (uint256) {
        return _claimYield(_collateralToken, _recipient);
    }

    /**
     * @dev See {IAaveDIVAWrapper-approveCollateralTokenForAave}.
     */
    function approveCollateralTokenForAave(address _collateralToken) external override {
        _approveCollateralTokenForAave(_collateralToken);
    }

    /*//////////////////////////////////////////////////////////////
                            BATCH FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function batchRegisterCollateralToken(
        address[] calldata _collateralTokens
    ) external override onlyOwner nonReentrant returns (address[] memory) {
        uint256 _length = _collateralTokens.length;
        address[] memory _wTokens = new address[](_length);

        for (uint256 i = 0; i < _length; i++) {
            _wTokens[i] = _registerCollateralToken(_collateralTokens[i]);
        }

        return _wTokens;
    }

    function batchCreateContingentPool(
        PoolParams[] calldata _poolParams
    ) external override nonReentrant returns (bytes32[] memory) {
        uint256 _length = _poolParams.length;
        bytes32[] memory _poolIds = new bytes32[](_length);

        for (uint256 i = 0; i < _length; i++) {
            _poolIds[i] = _createContingentPool(_poolParams[i]);
        }

        return _poolIds;
    }

    function batchAddLiquidity(AddLiquidityArgs[] calldata _addLiquidityArgs) external override nonReentrant {
        uint256 _length = _addLiquidityArgs.length;
        for (uint256 i = 0; i < _length; i++) {
            _addLiquidity(
                _addLiquidityArgs[i].poolId,
                _addLiquidityArgs[i].collateralAmount,
                _addLiquidityArgs[i].longRecipient,
                _addLiquidityArgs[i].shortRecipient
            );
        }
    }

    function batchRemoveLiquidity(
        RemoveLiquidityArgs[] calldata _removeLiquidityArgs
    ) external override nonReentrant returns (uint256[] memory) {
        uint256 _length = _removeLiquidityArgs.length;
        uint256[] memory _amountsReturned = new uint256[](_length);

        for (uint256 i = 0; i < _length; i++) {
            _amountsReturned[i] = _removeLiquidity(
                _removeLiquidityArgs[i].poolId,
                _removeLiquidityArgs[i].positionTokenAmount,
                _removeLiquidityArgs[i].recipient
            );
        }

        return _amountsReturned;
    }

    function batchRedeemPositionToken(
        RedeemPositionTokenArgs[] calldata _redeemPositionTokenArgs
    ) external override nonReentrant returns (uint256[] memory) {
        uint256 _length = _redeemPositionTokenArgs.length;
        uint256[] memory _amountsReturned = new uint256[](_length);

        for (uint256 i = 0; i < _length; i++) {
            _amountsReturned[i] = _redeemPositionToken(
                _redeemPositionTokenArgs[i].positionToken,
                _redeemPositionTokenArgs[i].positionTokenAmount,
                _redeemPositionTokenArgs[i].recipient
            );
        }

        return _amountsReturned;
    }

    function batchRedeemWToken(
        RedeemWTokenArgs[] calldata _redeemWTokenArgs
    ) external override nonReentrant returns (uint256[] memory) {
        uint256 _length = _redeemWTokenArgs.length;
        uint256[] memory _amountsReturned = new uint256[](_length);

        for (uint256 i = 0; i < _length; i++) {
            _amountsReturned[i] = _redeemWToken(
                _redeemWTokenArgs[i].wToken,
                _redeemWTokenArgs[i].wTokenAmount,
                _redeemWTokenArgs[i].recipient
            );
        }

        return _amountsReturned;
    }

    function batchClaimYield(
        ClaimYieldArgs[] calldata _claimYieldArgs
    ) external override onlyOwner nonReentrant returns (uint256[] memory) {
        uint256 _length = _claimYieldArgs.length;
        uint256[] memory _amountsClaimed = new uint256[](_length);

        for (uint256 i = 0; i < _length; i++) {
            _amountsClaimed[i] = _claimYield(_claimYieldArgs[i].collateralToken, _claimYieldArgs[i].recipient);
        }

        return _amountsClaimed;
    }

    function batchApproveCollateralTokenForAave(address[] calldata _collateralTokens) external override {
        uint256 _length = _collateralTokens.length;
        for (uint256 i = 0; i < _length; i++) {
            _approveCollateralTokenForAave(_collateralTokens[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev See {IAaveDIVAWrapper-getAccruedYield}.
     */
    function getAccruedYield(address _collateralToken) external view override returns (uint256) {
        return _getAccruedYield(_collateralToken);
    }

    /**
     * @dev See {IAaveDIVAWrapper-getContractDetails}.
     */
    function getContractDetails() external view override returns (address, address, address) {
        return _getContractDetails();
    }

    /**
     * @dev See {IAaveDIVAWrapper-getWToken}.
     */
    function getWToken(address _collateralToken) external view override returns (address) {
        return _getWToken(_collateralToken);
    }

    /**
     * @dev See {IAaveDIVAWrapper-getAToken}.
     */
    function getAToken(address _collateralToken) external view override returns (address) {
        return _getAToken(_collateralToken);
    }

    /**
     * @dev See {IAaveDIVAWrapper-getCollateralToken}.
     */
    function getCollateralToken(address _wToken) external view override returns (address) {
        return _getCollateralToken(_wToken);
    }
}
