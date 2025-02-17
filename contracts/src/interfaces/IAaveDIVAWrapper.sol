// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title IAaveDIVAWrapper
 * @author Wladimir Weinbender, Co-Founder of DIVA Protocol
 * @notice AaveDIVAWrapper is a smart contract that acts as a connector between DIVA Protocol and Aave V3,
 * allowing assets deposited into DIVA Protocol pools to generate yield by supplying them on Aave V3.
 * The generated yield is claimable by the owner of the AaveDIVAWrapper contract.
 * @dev Interface for the AaveDIVAWrapper contract.
 *
 * Note: The AaveDIVAWrapper contract integrates with Aave V3.2 and DIVA Protocol v1.
 * While Aave V3 is upgradeable, this contract's reliance on only core functions
 * (`supply()`, `withdraw()`, and `getReserveData()`) minimizes the risk of being affected by future protocol upgrades.
 *
 * References:
 * - Aave V3.2: https://github.com/aave-dao/aave-v3-origin/tree/v3.2.0
 * - DIVA Protocol v1: https://github.com/divaprotocol/diva-protocol-v1/tree/main
 * - Aave V3 changelogs: https://github.com/bgd-labs/aave-v3-origin/tree/v3.3.0/docs
 */
interface IAaveDIVAWrapper {
    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    // Argument for `createContingentPool` function (same as in DIVA Protocol, see `IDIVA.sol`).
    struct PoolParams {
        string referenceAsset;
        uint96 expiryTime;
        uint256 floor;
        uint256 inflection;
        uint256 cap;
        uint256 gradient;
        uint256 collateralAmount;
        address collateralToken;
        address dataProvider;
        uint256 capacity;
        address longRecipient;
        address shortRecipient;
        address permissionedERC721Token;
    }

    // Struct defining an element in the array argument for `batchAddLiquidity` function.
    struct AddLiquidityArgs {
        bytes32 poolId;
        uint256 collateralAmount;
        address longRecipient;
        address shortRecipient;
    }

    // Struct defining an element in the array argument for `batchRemoveLiquidity` function.
    struct RemoveLiquidityArgs {
        bytes32 poolId;
        uint256 positionTokenAmount;
        address recipient;
    }

    // Struct defining an element in the array argument for `batchRedeemPositionToken` function.
    struct RedeemPositionTokenArgs {
        address positionToken;
        uint256 positionTokenAmount;
        address recipient;
    }

    // Struct defining an element in the array argument for `batchRedeemWToken` function.
    struct RedeemWTokenArgs {
        address wToken;
        uint256 wTokenAmount;
        address recipient;
    }

    // Struct defining an element in the array argument for `batchClaimYield` function.
    struct ClaimYieldArgs {
        address collateralToken;
        address recipient;
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    // Emitted when a new contingent pool is created via `createContingentPool`.
    // Added to allow identification of pools created via the AaveDIVAWrapper contract.
    event PoolIssued(bytes32 indexed poolId); 

    // Emitted when owner claims the accrued yield via `claimYield`.
    event YieldClaimed(
        address indexed _claimer,
        address indexed _recipient,
        address indexed _collateralToken,
        uint256 _amount
    );

    // Emitted when a new collateral token is registered via `registerCollateralToken`.
    event CollateralTokenRegistered(address indexed _collateralToken, address indexed _wToken);

    // Emitted when wToken is redeemed via `redeemWToken`, `removeLiquidity` or `redeemPositionToken`.
    event WTokenRedeemed(
        address indexed _wToken, // Address of the wToken that was redeemed.
        uint256 _wTokenAmount, // Amount of wToken redeemed.
        address indexed _collateralToken, // Address of the asset token (e.g., USDT) that was withdrawn from Aave.
        uint256 _collateralAmountReturned, // Amount of the asset token returned to the recipient.
        address indexed _recipient // Address that the asset token was transferred to.
    );

    /*//////////////////////////////////////////////////////////////
                        ERRORS
    //////////////////////////////////////////////////////////////*/

    // Thrown in the constructor if any of the initialization addresses are zero.
    error ZeroAddress();
    // Thrown in `registerCollateralToken` if the collateral token is not supported by Aave V3.
    error UnsupportedCollateralToken();
    // Thrown in `registerCollateralToken` if the collateral token is already registered.
    error CollateralTokenAlreadyRegistered();
    // Thrown in `approveCollateralTokenForAave`, `createContingentPool`, `addLiquidity`, `removeLiquidity`,
    // and `redeemPositionToken` if the collateral token to be approved/supplied/withdrawn is not registered inside AaveDIVAWrapper contract.
    error CollateralTokenNotRegistered();

    /*//////////////////////////////////////////////////////////////
                        STATE MODIFYING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Registers a new `_collateralToken` and returns the address of the corresponding wToken. Only callable by the owner.
     * @dev Deploys a wrapped token (wToken) associated with the collateral token, and sets up necessary approvals for DIVA
     * Protocol and Aave V3. The wToken is used as proxy collateral token in DIVA Protocol.
     * @param _collateralToken The address of the collateral token to register.
     * @return The address of the newly created wToken.
     */
    function registerCollateralToken(address _collateralToken) external returns (address);

    /**
     * @notice Creates a new contingent pool in DIVA Protocol using the provided parameters.
     * Long tokens are sent to `PoolParams.longRecipient` and short tokens to `PoolParams.shortRecipient`.
     * @dev After transferring collateral tokens from the caller, an equal amount of wTokens is minted and used as proxy collateral
     * for the DIVA Protocol pool. The aTokens returned from supplying the collateral token to Aave are
     * received and held by AaveDIVAWrapper. The caller must approve AaveDIVAWrapper to transfer the collateral token before
     * calling this function.
     * @param _poolParams Struct containing the pool specification. It's the same struct as used in DIVA Protocol's
     * `createContingentPool` function.
     * - referenceAsset: The metric or event whose outcome will determine the payout for long and short tokens.
     * - expiryTime: Expiration time of the pool expressed as a unix timestamp in seconds (UTC).
     * - floor: Value of the reference asset at or below which the long token pays out 0 and the short token 1 (max payout),
     *   gross of fees. Input expects an integer with 18 decimals.
     * - inflection: Value of the reference asset at which the long token pays out `gradient` and the short token `1-gradient`,
     *   gross of fees. Input expects an integer with 18 decimals.
     * - cap: Value of the reference asset at or above which the long token pays out 1 (max payout) and the short token 0,
     *   gross of fees. Input expects an integer with 18 decimals.
     * - gradient: A value between 0 and 1 which specifies the payout per long token if the outcome is equal to `inflection`.
     *   Input expects an integer with collateral token decimals.
     * - collateralAmount: Amount to be deposited into AaveDIVAWrapper, which is wrapped 1:1 into the wToken and
     *   deposited as collateral into the pool. Input expects an integer with collateral token decimals.
     * - collateralToken: Address of the ERC20 collateral token (e.g., USDT).
     * - dataProvider: Ethereum account (EOA or smart contract) that is supposed to report the final reference asset value
     *   following pool expiration.
     * - capacity: Maximum collateral amount that a contingent pool can accept. Choose a large number (e.g., `2**256 - 1`)
     *   for unlimited size. Input expects an integer with collateral token decimals.
     * - longRecipient: Address that shall receive the long token.
     *   Any burn address except for the zero address is a valid recipient to enable conditional burn use cases.
     * - shortRecipient: Address that shall receive the short token. Any burn address except for the zero address is a valid
     *   recipient to enable conditional burn use cases.
     * - permissionedERC721Token: Address of the ERC721 token that transfers are restricted to. Use zero address to render the
     *   long and short tokens permissionless.
     * @return The unique pool Id generated by DIVA Protocol for the newly created pool.
     */
    function createContingentPool(PoolParams calldata _poolParams) external returns (bytes32);

    /**
     * @notice Adds `_collateralAmount` of liquidity to an existing DIVA Protocol pool identified by the provided `_poolId`.
     * Long tokens are sent to `_longRecipient` and short tokens to `_shortRecipient`.
     * @dev After transferring collateral tokens from the caller, an equal amount of wTokens is minted and
     * added as proxy collateral to the pool. The aTokens returned from supplying the collateral token to Aave are
     * received and held by AaveDIVAWrapper. The caller must approve AaveDIVAWrapper to transfer the collateral token before
     * calling this function.
     * @param _poolId The Id of the DIVA Protocol pool to add liquidity to.
     * @param _collateralAmount The amount of collateral token to add as liquidity.
     * @param _longRecipient The recipient of the long tokens.
     * @param _shortRecipient The recipient of the short tokens.
     */
    function addLiquidity(
        bytes32 _poolId,
        uint256 _collateralAmount,
        address _longRecipient,
        address _shortRecipient
    ) external;

    /**
     * @notice Removes liquidity from the pool associated with `_poolId` by burning an equal amount (`_positionTokenAmount`) of valid long
     * and short tokens, and then transferring the corresponding collateral tokens (e.g., USDC) to the specified `_recipient`.
     * @dev The returned collateral token amount is net of DIVA fees. The fee is denominated in the collateral token
     * (wToken for pools created through AaveDIVAWrapper) and is withheld within DIVA Protocol, where it can be
     * claimed by the respective owner. The caller must approve AaveDIVAWrapper to transfer both long and short
     * tokens before calling this function.
     * @param _poolId The pool Id to remove liquidity from.
     * @param _positionTokenAmount Amount of liquidity to remove (type(uint256).max = min short/long balance).
     * @param _recipient The address of the recipient to receive the collateral tokens.
     * @return The amount of collateral tokens transferred to `_recipient`, net of DIVA fees.
     */
    function removeLiquidity(
        bytes32 _poolId,
        uint256 _positionTokenAmount,
        address _recipient
    ) external returns (uint256);

    /**
     * @notice Redeems `_positionTokenAmount` of `_positionToken` (short or long token) for the collateral token (e.g., USDC) and sends it to
     * the specified `_recipient`.
     * @dev The returned collateral token amount is net of DIVA fees. The fee is denominated in the proxy collateral token
     * (wToken for pools created through the AaveDIVAWrapper contract) and is withheld within DIVA Protocol, where it can be
     * claimed by the respective owner and redeemed for the original collateral token via `redeemWToken`.
     * The caller must approve AaveDIVAWrapper to transfer the position tokens before calling this function.
     * @param _positionToken The address of the position token to redeem.
     * @param _positionTokenAmount Amount to redeem (type(uint256).max = caller's balance).
     * @param _recipient The recipient of the returned collateral tokens.
     * @return The amount of collateral tokens transferred to `_recipient`, net of DIVA fees.
     */
    function redeemPositionToken(
        address _positionToken,
        uint256 _positionTokenAmount,
        address _recipient
    ) external returns (uint256);

    /**
     * @notice Converts the provided `_wTokenAmount` of `_wToken` into the underlying collateral token and transfers it to the specified `_recipient`.
     * Users that received wTokens, e.g., by redeeming their position tokens directly from DIVA Protocol or other
     * direct interactions, can use this function to convert them into collateral tokens (e.g., USDC).
     * @dev No prior approval from the caller is required for this operation as the AaveDIVAWrapper contract
     * has the authority to burn wTokens directly from the caller's balance.
     * @param _wToken The address of the wToken to convert.
     * @param _wTokenAmount Amount to convert (type(uint256).max = caller's balance).
     * @param _recipient The address of the recipient to receive the collateral tokens.
     * @return The amount of collateral tokens withdrawn from Aave and transferred to `_recipient`.
     */
    function redeemWToken(address _wToken, uint256 _wTokenAmount, address _recipient) external returns (uint256);

    /**
     * @notice Transfers the yield accrued in the provided `_collateralToken` to the specified `_recipient`.
     * @dev This function can only be called by the owner of the contract. Partial yield claims are not supported.
     * @param _collateralToken The address of the collateral token to claim yield for.
     * @param _recipient The address of the recipient to whom the accrued yield will be transferred.
     * @return The collateral token amount sent to `_recipient`.
     */
    function claimYield(address _collateralToken, address _recipient) external returns (uint256);

    /**
     * @notice Resets the allowance of the provided `_collateralToken` for the Aave V3 contract to unlimited,
     * should it ever be depleted.
     * @dev Can be triggered by anyone. Throws if the provided `_collateralToken` is not registered.
     * Using OpenZeppelin's `safeIncreaseAllowance` to accommodate tokens like USDT on Ethereum that
     * require the approval to be set to zero before setting it to a non-zero value.
     * @param _collateralToken The address of the collateral token to approve.
     */
    function approveCollateralTokenForAave(address _collateralToken) external;

    /*//////////////////////////////////////////////////////////////
                            BATCH FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Batch version of `registerCollateralToken` function.
     * @param _collateralTokens Array of collateral token addresses to register.
     * @return Array of wToken addresses created for each collateral token.
     */
    function batchRegisterCollateralToken(address[] calldata _collateralTokens) external returns (address[] memory);

    /**
     * @notice Batch version of `createContingentPool` function.
     * @param _poolParams Array of pool parameters for each contingent pool to create.
     * @return Array of pool IDs for the created contingent pools.
     */
    function batchCreateContingentPool(PoolParams[] calldata _poolParams) external returns (bytes32[] memory);

    /**
     * @notice Batch version of `addLiquidity` function.
     * @param _addLiquidityArgs Array of arguments containing poolId, collateralAmount, and recipient addresses for each liquidity addition.
     */
    function batchAddLiquidity(AddLiquidityArgs[] calldata _addLiquidityArgs) external;

    /**
     * @notice Batch version of `removeLiquidity` function.
     * @param _removeLiquidityArgs Array of arguments containing poolId, positionTokenAmount and recipient for each liquidity removal.
     * @return Array of collateral token amounts returned for each liquidity removal.
     */
    function batchRemoveLiquidity(
        RemoveLiquidityArgs[] calldata _removeLiquidityArgs
    ) external returns (uint256[] memory);

    /**
     * @notice Batch version of `redeemPositionToken` function.
     * @param _redeemPositionTokenArgs Array of arguments containing positionToken address, amount and recipient for each redemption.
     * @return Array of collateral token amounts returned for each redemption.
     */
    function batchRedeemPositionToken(
        RedeemPositionTokenArgs[] calldata _redeemPositionTokenArgs
    ) external returns (uint256[] memory);

    /**
     * @notice Batch version of `redeemWToken` function.
     * @param _redeemWTokenArgs Array of arguments containing wToken address, amount and recipient for each redemption.
     * @return Array of collateral token amounts returned for each redemption.
     */
    function batchRedeemWToken(RedeemWTokenArgs[] calldata _redeemWTokenArgs) external returns (uint256[] memory);

    /**
     * @notice Batch version of `claimYield` function.
     * @param _claimYieldArgs Array of arguments containing collateral token address and recipient for each yield claim.
     * @return Array of yield amounts claimed for each collateral token.
     */
    function batchClaimYield(ClaimYieldArgs[] calldata _claimYieldArgs) external returns (uint256[] memory);

    /**
     * @notice Batch version of `approveCollateralTokenForAave` function.
     * @param _collateralTokens Array of collateral token addresses to approve.
     */
    function batchApproveCollateralTokenForAave(address[] calldata _collateralTokens) external;

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the total yield accrued in AaveDIVAWrapper contract in the provided `_collateralToken`
     * and claimable by the owner.
     * @dev Accrued yield is the difference between AaveDIVAWrapper contract's aToken balance and the
     * total supply of the associated wToken.
     * @param _collateralToken The address of the collateral token to claim yield for.
     * @return The total amount of accrued yield measured in collateral token units. Returns zero if
     * `_collateralToken` is not registered or if the aToken balance is smaller than the wToken supply
     * (e.g., due to rounding).
     */
    function getAccruedYield(address _collateralToken) external view returns (uint256);

    /**
     * @notice Returns the DIVA Protocol and Aave V3 addresses the AaveDIVAWrapper contract is linked to
     * as well as the owner of the contract.
     * @dev Returns multiple contract-related addresses in a single call.
     * @return Address of the DIVA contract.
     * @return Address of the Aave V3 contract.
     * @return Address of the owner of the AaveDIVAWrapper contract.
     */
    function getContractDetails() external view returns (address, address, address);

    /**
     * @notice Returns the addresses of the wToken associated with the provided `_collateralToken`.
     * @param _collateralToken The address of the collateral token.
     * @return The address of the wToken associated with the provided `_collateralToken`. Returns `address(0)`
     * if the provided `_collateralToken` is not registered.
     */
    function getWToken(address _collateralToken) external view returns (address);

    /**
     * @notice Returns the address of Aave V3's aToken associated with the provided `_collateralToken`.
     * @param _collateralToken The address of the collateral token.
     * @return The address of the aToken associated with the provided `_collateralToken`. Returns `address(0)`
     * if the provided `_collateralToken` is not supported by Aave V3.
     */
    function getAToken(address _collateralToken) external view returns (address);

    /**
     * @notice Returns the address of the collateral token associated with the provided `_wToken`.
     * @param _wToken The address of the wToken.
     * @return The address of the collateral token associated with the provided `_wToken`. Returns `address(0)`
     * if the provided `_wToken` is not registered.
     */
    function getCollateralToken(address _wToken) external view returns (address);
}
