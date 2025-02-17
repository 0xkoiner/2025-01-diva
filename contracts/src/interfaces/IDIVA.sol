// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title Shortened version of the interface including required functions only
 */
interface IDIVA {
    // Struct for `batchTransferFeeClaim` function input
    struct ArgsBatchTransferFeeClaim {
        address recipient;
        address collateralToken;
        uint256 amount;
    }

    // Settlement status
    enum Status {
        Open,
        Submitted,
        Challenged,
        Confirmed
    }

    // Collection of pool related parameters; order was optimized to reduce storage costs
    struct Pool {
        uint256 floor; // Reference asset value at or below which the long token pays out 0 and the short token 1 (max payout) (18 decimals)
        uint256 inflection; // Reference asset value at which the long token pays out `gradient` and the short token `1-gradient` (18 decimals)
        uint256 cap; // Reference asset value at or above which the long token pays out 1 (max payout) and the short token 0 (18 decimals)
        uint256 gradient; // Long token payout at inflection (value between 0 and 1) (collateral token decimals)
        uint256 collateralBalance; // Current collateral balance of pool (collateral token decimals)
        uint256 finalReferenceValue; // Reference asset value at the time of expiration (18 decimals) - set to 0 at pool creation
        uint256 capacity; // Maximum collateral that the pool can accept (collateral token decimals)
        uint256 statusTimestamp; // Timestamp of status change - set to block.timestamp at pool creation
        address shortToken; // Short position token address
        uint96 payoutShort; // Payout amount per short position token net of fees (collateral token decimals) - set to 0 at pool creation
        address longToken; // Long position token address
        uint96 payoutLong; // Payout amount per long position token net of fees (collateral token decimals) - set to 0 at pool creation
        address collateralToken; // Address of the ERC20 collateral token
        uint96 expiryTime; // Expiration time of the pool (expressed as a unix timestamp in seconds)
        address dataProvider; // Address of data provider
        uint48 indexFees; // Index pointer to the applicable fees inside the Fees struct array
        uint48 indexSettlementPeriods; // Index pointer to the applicable periods inside the SettlementPeriods struct array
        Status statusFinalReferenceValue; // Status of final reference price (0 = Open, 1 = Submitted, 2 = Challenged, 3 = Confirmed) - set to 0 at pool creation
        string referenceAsset; // Reference asset string
    }

    // Argument for `createContingentPool` function
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

    // Collection of fee related parameters
    struct Fees {
        uint256 startTime; // timestamp at which the new set of fees becomes applicable
        uint96 protocolFee; // max value: 15000000000000000 = 1.5% <= 2^56
        uint96 settlementFee; // max value: 15000000000000000 = 1.5% <= 2^56
    }

    event PoolIssued(
        bytes32 indexed poolId,
        address indexed longRecipient,
        address indexed shortRecipient,
        uint256 collateralAmount,
        address permissionedERC721Token
    ); // @audit-low: unused event

    event LiquidityAdded(
        bytes32 indexed poolId,
        address indexed longRecipient,
        address indexed shortRecipient,
        uint256 collateralAmount
    ); // @audit-low: unused event

    /**
     * @notice Function to submit the final reference value for a given pool Id.
     * @param _poolId The pool Id for which the final value is submitted.
     * @param _finalReferenceValue Proposed final value by the data provider
     * expressed as an integer with 18 decimals.
     * @param _allowChallenge Flag indicating whether the challenge functionality
     * is enabled or disabled for the submitted value. If 0, then the submitted
     * final value will be directly confirmed and position token holders can start
     * redeeming their position tokens. If 1, then position token holders can
     * challenge the submitted value. This flag was introduced to account for
     * decentralized oracle solutions like Uniswap v3 or Chainlink where a
     * dispute mechanism doesn't make sense.
     */
    function setFinalReferenceValue(bytes32 _poolId, uint256 _finalReferenceValue, bool _allowChallenge) external;

    /**
     * @notice Function to transfer fee claim from entitled address
     * to another address
     * @param _recipient Address of fee claim recipient
     * @param _collateralToken Collateral token address
     * @param _amount Amount (expressed as an integer with collateral token
     * decimals) to transfer to recipient
     */
    function transferFeeClaim(address _recipient, address _collateralToken, uint256 _amount) external;

    /**
     * @notice Batch version of `transferFeeClaim`
     * @param _argsBatchTransferFeeClaim List containing collateral tokens,
     * recipient addresses and amounts (expressed as an integer with collateral
     * token decimals)
     */
    function batchTransferFeeClaim(ArgsBatchTransferFeeClaim[] calldata _argsBatchTransferFeeClaim) external;

    /**
     * @notice Function to claim allocated fee
     * @dev List of collateral token addresses has to be obtained off-chain
     * (e.g., from TheGraph)
     * @param _collateralToken Collateral token address
     * @param _recipient Fee recipient address
     */
    function claimFee(address _collateralToken, address _recipient) external;

    /**
     * @notice Function to issue long and short position tokens to
     * `longRecipient` and `shortRecipient` upon collateral deposit by `msg.sender`. 
     * Provided collateral is kept inside the contract until position tokens are 
     * redeemed by calling `redeemPositionToken` or `removeLiquidity`.
     * @dev Position token supply equals `collateralAmount` (minimum 1e6).
     * Position tokens have the same number of decimals as the collateral token.
     * Only ERC20 tokens with 6 <= decimals <= 18 are accepted as collateral.
     * Tokens with flexible supply like Ampleforth should not be used. When
     * interest/yield bearing tokens are considered, only use tokens with a
     * constant balance mechanism such as Compound's cToken or the wrapped
     * version of Lido's staked ETH (wstETH).
     * ETH is not supported as collateral in v1. It has to be wrapped into WETH
       before deposit.
     * @param _poolParams Struct containing the pool specification:
     * - referenceAsset: The name of the reference asset (e.g., Tesla-USD or
         ETHGasPrice-GWEI).
     * - expiryTime: Expiration time of the position tokens expressed as a unix
         timestamp in seconds.
     * - floor: Value of underlying at or below which the short token will pay
         out the max amount and the long token zero. Expressed as an integer with
         18 decimals.
     * - inflection: Value of underlying at which the long token will payout
         out `gradient` and the short token `1-gradient`. Expressed as an
         integer with 18 decimals.
     * - cap: Value of underlying at or above which the long token will pay
         out the max amount and short token zero. Expressed as an integer with
         18 decimals.
     * - gradient: Long token payout at inflection. The short token payout at
         inflection is `1-gradient`. Expressed as an integer with collateral token
         decimals.
     * - collateralAmount: Collateral amount to be deposited into the pool to
         back the position tokens. Expressed as an integer with collateral token
         decimals.
     * - collateralToken: ERC20 collateral token address.
     * - dataProvider: Address that is supposed to report the final value of
         the reference asset.
     * - capacity: The maximum collateral amount that the pool can accept. Expressed
         as an integer with collateral token decimals.
     * - longRecipient: Address that shall receive the long position tokens. 
     *   Zero address is a valid input to enable conditional burn use cases.
     * - shortRecipient: Address that shall receive the short position tokens.
     *   Zero address is a valid input to enable conditional burn use cases.
     * - permissionedERC721Token: Address of ERC721 token that is allowed to transfer the
     *   position token. Zero address if position token is supposed to be permissionless.
     * @return poolId
     */
    function createContingentPool(PoolParams memory _poolParams) external returns (bytes32);

    /**
     * @notice Returns the pool parameters for a given pool Id. To
     * obtain the fees and settlement periods applicable for the pool,
     * use the `getFees` and `getSettlementPeriods` functions
     * respectively, passing in the returned `indexFees` and
     * `indexSettlementPeriods` as arguments.
     * @param _poolId Id of the pool.
     * @return Pool struct.
     */
    function getPoolParameters(bytes32 _poolId) external view returns (Pool memory);

    /**
     * @notice Same as `getPoolParameters`, but the pool parameters are
     * retrieved based on a provided position token address instead of a `poolId`.
     * @dev If the provided position token address does not match any pool, the
     * function will return the default `Pool` struct with zero values. This
     * default struct can be identified by properties such as
     * `collateralToken = 0x0000000000000000000000000000000000000000` or
     * `dataProvider = 0x0000000000000000000000000000000000000000`, for example.
     * @param _positionToken Position token address.
     * @return Pool struct.
     */
    function getPoolParametersByAddress(address _positionToken) external view returns (Pool memory);

    /**
     * @notice Returns the claims by collateral tokens for a given account.
     * @param _recipient Recipient address.
     * @param _collateralToken Collateral token address.
     * @return Fee claim amount.
     */
    function getClaim(address _collateralToken, address _recipient) external view returns (uint256);

    /**
     * @notice Function to add collateral to an existing pool. Mints new
     * long and short position tokens with supply equal to collateral
     * amount added and sends them to `_longRecipient` and `_shortRecipient`,
     * respectively.
     * @dev Requires prior ERC20 approval. The transaction will fail if the
     * underlying collateral token charges a fee on transfers.
     * @param _poolId Id of the pool to add collateral to.
     * @param _collateralAmountIncr Incremental collateral amount that `msg.sender`
     * is going to add to the pool expressed as an integer with collateral token decimals.
     * @param _longRecipient: Address that shall receive the long position tokens.
     * Any burn address except for the zero address is a valid recipient to enable conditional
     * burn use cases.
     * @param _shortRecipient: Address that shall receive the short position tokens.
     * Any burn address except for the zero address is a valid recipient to enable conditional
     * burn use cases.
     */
    function addLiquidity(
        bytes32 _poolId,
        uint256 _collateralAmountIncr,
        address _longRecipient,
        address _shortRecipient
    ) external;

    /**
     * @notice Function to remove collateral from an existing pool.
     * @dev Requires `msg.sender` to return an equal amount of long and short
     * position tokens which are burnt. Collateral amount returned to the user
     * is net of fees. Protocol and settlement fees for DIVA treasury and
     * data provider, respectively, are retained within the contract and can
     * be claimed via `claimFee` function.
     * @param _poolId Id of the pool that a user wants to remove collateral
     * from.
     * @param _amount Number of position tokens to return (1:1 to collateral
     * amount).
     */
    function removeLiquidity(bytes32 _poolId, uint256 _amount) external;

    /**
     * @notice Function to redeem position tokens. Position tokens are burnt
     * during that process.
     * @dev If the submission period expired without a challenge or a review
     * period expired without another input from the data provider, the
     * previously submitted final value is confirmed inside the function at
     * first user redemption.
     * @param _positionToken address of the position token to be redeemed.
     * @param _amount number of position tokens to be redeemed..
     */
    function redeemPositionToken(address _positionToken, uint256 _amount) external;

    /**
     * @notice Returns the protocol and settlement fees applicable for
     * a given `_indexFees`.
     * @param _indexFees The index of fees.
     * @return Fees struct.
     */
    function getFees(uint48 _indexFees) external view returns (Fees memory);

    /**
     * @notice Function to return the owner stored in ownership contract.
     * @return owner_ The address of the owner.
     */
    function getOwner() external view returns (address owner_);

    /**
     * @notice Returns the latest update of the treasury address, including
     * the activation time and the previous treasury address. Only the
     * previous data address is stored for historical reference.
     * @return previousTreasury Previous treasury address.
     * @return treasury Latest update of the treasury address.
     * @return startTimeTreasury Timestamp in seconds since epoch at which
     * `treasury` is activated.
     */
    function getTreasuryInfo()
        external
        view
        returns (address previousTreasury, address treasury, uint256 startTimeTreasury);
}
