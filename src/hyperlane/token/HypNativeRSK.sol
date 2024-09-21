// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

import {TokenRouter} from "hyperspeed-bridge-fork/token/libs/TokenRouter.sol";
import {TokenMessage} from "hyperspeed-bridge-fork/token/libs/TokenMessage.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// Define a minimal interface for UmbrellaFeeds
interface IUmbrellaFeeds {
    struct PriceData {
        uint128 price;
        uint32 timestamp;
        uint24 heartbeat;
    }

    function getPriceDataByName(string calldata _name) external view returns (PriceData memory data);
}

interface IInsuranceFund {
        function liquidateForReorg(uint256 amount) external returns (bool);
    }

/**
 * @title Hyperlane Native Token Router that extends ERC20 with remote transfer functionality.
 * @author Abacus Works
 * @dev Supply on each chain is not constant but the aggregate supply across all chains is.
 * @dev Hyperspeed Bridge: This is an edited version of HypNative, allowing for:
 * - Bridging of native tokens across chains (i.e. deposit ETH on Ethereum and receive RBTC on Rootstock)
 * - Instant transfer of bridged assets, ignoring finality as long as the currently bridging amount does not exceed the insurance fund.
 * - Depositing of liquidity which is utilized by the contract for handling withdrawals and earns bridging fees.
 */
contract HypNative is TokenRouter, ReentrancyGuard {
    IUmbrellaFeeds public umbrellaFeeds;
    IInsuranceFund public insuranceFund;

    struct TransferRecord {
        uint256 amount;         // The amount of USD value being bridged
        uint256 blockNumber;    // The block number this transfer was initiated
    }

    struct ReorgedTransfer {
        uint256 amount;         // The amount of USD value in the reorged transfer
        uint256 blockNumber;    // The block number this transfer was initiated & reorged on
        uint256 originalIndex;  // The original index of the transfer 
    }

    struct PendingTransfer {
        uint256 amount;         // The amount of USD value being bridged
        uint256 blockNumber;    // The block number this transfer was initiated
    }

    mapping(uint32 chainID => mapping(uint256 transferID => TransferRecord)) public transferRecords; //Stores all bridging transfers.
    mapping(uint32 => ReorgedTransfer[]) public reorgedTransfers; // Stores all reorged transfers.
    PendingTransfer[] public pendingTransfers; // Stores all pending transfers.


    uint256 public ethereumInsuranceFundAmount; // Stores the amount of USD value in the Insurance Fund on Ethereum
    uint256 public ethereumAvailableLiquidity; // Stores the amount of USD value in the available liquidity on Ethereum
    uint256 public pendingBridgeAmount; // The amount of USD value that is currently being bridged and has not reached finality.
    uint256 public constant FINALITY_PERIOD = 12; // The number of blocks required for finality on Rootstock.

    uint256 public nextTransferId; // The next transfer ID to be used

    uint256 public constant OUTBOUND_FEE_PERCENTAGE = 1; // 0.1% on outbound transfers
    uint256 public constant INBOUND_FEE_PERCENTAGE = 1; // 0.1% on inbound transfers
    uint256 public constant LIQUIDITY_PROVIDER_REWARD_SHARE = 80; // 80% of fees paid to liquidity providers
    uint256 public constant INSURANCE_FUND_REWARD_SHARE = 20; // 20% of fees paid to the Insurance Fund

    uint256 public totalLiquidityShares; // The total amount of shares, representing user liquidity deposits.
    uint256 public totalFees; // The total amount of outstanding fees collected by the bridge.
    mapping(address => uint256) public userLiquidityShares; // The amount of shares a user owns in the bridge liquidity
    mapping(address => uint256) public userFeeIndex; // The fee index for a user
    uint256 public feeIndex; // The current fee index, increases each time fees are distributed
    uint256 private constant PRECISION = 1e18;

    /**
     * @dev Emitted when native tokens are donated to the contract.
     * @param sender The address of the sender.
     * @param amount The amount of native tokens donated.
     */
    event Donation(address indexed sender, uint256 amount);
    event LiquidityDeposited(address indexed provider, uint256 assets, uint256 shares);
    event LiquidityWithdrawn(address indexed provider, uint256 assets, uint256 shares);

    constructor(address _mailbox) TokenRouter(_mailbox) {
        // Rootstock Mainnet UmbrellaFeeds: 0xDa9A63D77406faa09d265413F4E128B54b5057e0
        // Rootstock Testnet UmbrellaFeeds: 0x3F2254bc49d2d6e8422D71cB5384fB76005558A9
        umbrellaFeeds = IUmbrellaFeeds(0x3F2254bc49d2d6e8422D71cB5384fB76005558A9);
        insuranceFund = IInsuranceFund(0x0000000000000000000000000000000000000000); // TODO: Change
    }

    /**
     * @notice Initializes the Hyperlane router
     * @param _hook The post-dispatch hook contract.
       @param _interchainSecurityModule The interchain security module contract.
       @param _owner The this contract.
     */
    function initialize(
        address _hook,
        address _interchainSecurityModule,
        address _owner
    ) public initializer {
        _MailboxClient_initialize(_hook, _interchainSecurityModule, _owner);
    }

    /**
     * @inheritdoc TokenRouter
     * @dev uses (`msg.value` - `_amount`) as hook payment and `msg.sender` as refund address.
     * @dev Hyperspeed Bridge: Edited to calculate USD value of RBTC being bridged and sends this value cross chain.
     * @dev Hyperspeed Bridge: Edited to check if the amount being bridged is within the safe bridgeable amount.
     * @dev Hyperspeed Bridge: Edited to take the outbound bridging fee from the user and distribute to liquidity providers + Insurance Fund.
     */
    function transferRemote(
        uint32 _destination,
        bytes32 _recipient,
        uint256 _amount
    ) external payable virtual override returns (bytes32 messageId) {
        require(msg.value >= _amount, "Native: amount exceeds msg.value");
        uint256 _hookPayment = msg.value - _amount;

        // Take the outbound bridging fee
        uint256 fee = (_amount * OUTBOUND_FEE_PERCENTAGE) / 10000;
        uint256 amountAfterFee = _amount - fee;
        _distributeFees(fee);

        // Get the latest RBTC/USD price from Umbrella Network
        uint128 rbtcUsdPrice = getUmbrellaPriceFeedLatestAnswer();
        
        // Calculate the USD value of the RBTC being bridged
        uint256 _usdValue = (amountAfterFee * uint256(rbtcUsdPrice)) / 1e18;
        require(_usdValue <= ethereumAvailableLiquidity, "Insufficient liquidity on the destination chain");

        // Hyperspeed Bridge: Checks if any transfers have reached finality and updates the pending bridge amount accordingly.
        _processFinalizedTransfers();

        // Checks the safe amount that can be currently bridged given the Insurance Fund and the pending bridged amount awaiting finality.
        uint256 safeBridgeableAmount = getInsuranceFundAmount() - pendingBridgeAmount;
        require(_usdValue <= safeBridgeableAmount, "Exceeds safe bridgeable amount");

        // Updates the permanent transfer record
        transferRecords[_destination][nextTransferId] = TransferRecord({
            amount: _usdValue,
            blockNumber: block.number
        });

        // Add to pending transfers
        pendingTransfers.push(PendingTransfer({
            amount: _usdValue,
            blockNumber: block.number
        }));

        pendingBridgeAmount += _usdValue;
        nextTransferId++;
        return _transferRemote(_destination, _recipient, _usdValue, _hookPayment);
    }

    function balanceOf(
        address _account
    ) external view override returns (uint256) {
        return _account.balance;
    }

    /**
     * @inheritdoc TokenRouter
     * @dev No-op because native amount is transferred in `msg.value`
     * @dev Compiler will not include this in the bytecode.
     */
    function _transferFromSender(
        uint256
    ) internal pure override returns (bytes memory) {
        return bytes(""); // no metadata
    }

    /**
     * @dev Sends `_amount` of native token to `_recipient` balance.
     * @inheritdoc TokenRouter
     * @dev Hyperspeed Bridge: Edited to receive the USD value of the incoming ETH and convert it into RBTC.
     * @dev Hyperspeed Bridge: Edited to take the inbound bridging fee from the user and distribute to liquidity providers + Insurance Fund.
     */
    function _transferTo(
        address _recipient,
        uint256 _amount,
        bytes calldata // no metadata
    ) internal virtual override nonReentrant {

        // Get the latest RBTC/USD price from Umbrella Network
        uint128 rbtcUsdPrice = getUmbrellaPriceFeedLatestAnswer();

        // Calculate the amount that was received in BTC
        uint256 _rbtcValue = (_amount * uint256(rbtcUsdPrice)) / 1e18;
        
        // Take the inbound bridging fee
        uint256 fee = (_rbtcValue * INBOUND_FEE_PERCENTAGE) / 10000;
        uint256 amountAfterFee = _rbtcValue - fee;
        _distributeFees(fee);

        Address.sendValue(payable(_recipient), amountAfterFee);
    }

    /**
     * @dev Gets the latest RBTC/USD price from UmbrellaFeeds
     * @return price The latest RBTC/USD price with 8 decimals
     */
    function getUmbrellaPriceFeedLatestAnswer() public view returns (uint128) {
        // Rootstock Testnet: RBTC-USD
        IUmbrellaFeeds.PriceData memory priceData = umbrellaFeeds.getPriceDataByName("RBTC-USD");
        require(priceData.price > 0, "Invalid RBTC/USD price");
        return priceData.price;
    }

    function getInsuranceFundAmount() public view returns (uint256) {
        // Determine the amount of RBTC in the Insurance Fund
        uint256 insuranceFundRbtcAmount = address(insuranceFund).balance;
        
        // Get the latest RBTC/USD price from Umbrella Network
        uint128 rbtcUsdPrice = getUmbrellaPriceFeedLatestAnswer();

        // Determine the amount of USD value in the Insurance Fund
        uint256 insuranceFundUsdAmount = (insuranceFundRbtcAmount * uint256(rbtcUsdPrice)) / 1e18;
        return insuranceFundUsdAmount;
    }


    /// @dev Hyperspeed Bridge: Edited to send the current amount of funds in the Insurance Fund in the message.
    /// @dev Hyperspeed Bridge: Edited to send the current amount of available liquidity in the message.
    /// @dev Hyperspeed Bridge: Edited to send the transfer ID in the message.
    function _transferRemote(
        uint32 _destination,
        bytes32 _recipient,
        uint256 _amountOrId,
        uint256 _value,
        bytes memory _hookMetadata,
        address _hook
    ) internal virtual override returns (bytes32 messageId) { 
        uint128 rbtcUsdPrice = getUmbrellaPriceFeedLatestAnswer();
        uint256 _availableLiquidity = (totalLiquidity() * uint256(rbtcUsdPrice)) / 1e18;
        uint256 _insuranceFundAmount = getInsuranceFundAmount();


        bytes memory _tokenMetadata = _transferFromSender(_amountOrId);
        bytes memory _tokenMessage = TokenMessage.format(
            _recipient,
            _amountOrId,
            _tokenMetadata,
            _insuranceFundAmount,
            _availableLiquidity,
            nextTransferId,
            block.number
        );

        messageId = _Router_dispatch(
            _destination,
            _value,
            _tokenMessage,
            _hookMetadata,
            _hook
        );

        emit SentTransferRemote(_destination, _recipient, _amountOrId);
    }

    /// @dev Hyperspeed Bridge: Edited to receive and store the current amount of funds in the Insurance Fund on the outbound chain.
    function _handle(
        uint32 _origin,
        bytes32,
        bytes calldata _message
    ) internal virtual override {
        bytes32 recipient = TokenMessage.recipient(_message);
        uint256 amount = TokenMessage.amount(_message);
        bytes calldata metadata = TokenMessage.metadata(_message);
        uint256 transferId = TokenMessage.transferId(_message);
        uint256 transferBlockNumber = TokenMessage.blockNumber(_message);

        if (transferRecords[_origin][transferId].amount != 0) {
            // Reorg detected
            reorgedTransfers[_origin].push(ReorgedTransfer({
                amount: transferRecords[_origin][transferId].amount,
                blockNumber: transferRecords[_origin][transferId].blockNumber,
                originalIndex: transferId
            }));
            
            // Pull funds from insurance fund
            uint256 reorgAmountUsd = transferRecords[_origin][transferId].amount;
            uint256 reorgAmountBtc = (reorgAmountUsd * 1e18) / getUmbrellaPriceFeedLatestAnswer();
            insuranceFund.liquidateForReorg(reorgAmountBtc);
        }

        // Store the transfer record
        transferRecords[_origin][transferId] = TransferRecord({
            amount: amount,
            blockNumber: transferBlockNumber
        });

        // Update the Insurance Fund and Available Liquidity that is on the other chain
        ethereumInsuranceFundAmount = _message.insuranceFundAmount();
        ethereumAvailableLiquidity = _message.availableLiquidity();


        // Transfer the bridged asset to the recipient
        _transferTo(address(uint160(uint256(recipient))), amount, metadata);
        emit ReceivedTransferRemote(_origin, recipient, amount);
    }

    function _processFinalizedTransfers() internal {
        uint256 i = 0;
        while (i < pendingTransfers.length) {
            if (pendingTransfers[i].blockNumber + FINALITY_PERIOD <= block.number) {
                pendingBridgeAmount -= pendingTransfers[i].amount;
                
                // Remove the processed transfer from pendingTransfers
                pendingTransfers[i] = pendingTransfers[pendingTransfers.length - 1];
                pendingTransfers.pop();
            } else {
                i++;
            }
        }
    }

    function depositBridgeLiquidity() external payable {
            require(msg.value > 0, "Must deposit some liquidity");
            
            uint256 newShares;
            if (totalLiquidityShares == 0) {
                newShares = msg.value;
            } else {
                newShares = (msg.value * totalLiquidityShares) / (address(this).balance - msg.value - totalFees);
            }
            
            userLiquidityShares[msg.sender] += newShares;
            totalLiquidityShares += newShares;
            userFeeIndex[msg.sender] = feeIndex;
            
            emit LiquidityDeposited(msg.sender, msg.value, newShares);
        }

    function withdrawBridgeLiquidity(uint256 _shares) external nonReentrant {
        require(_shares > 0 && _shares <= userLiquidityShares[msg.sender], "Invalid share amount");

        _claimFees(msg.sender);

        uint256 totalAssets = address(this).balance - totalFees;
        uint256 assetAmount = (_shares * totalAssets) / totalLiquidityShares;

        userLiquidityShares[msg.sender] -= _shares;
        totalLiquidityShares -= _shares;

        require(address(this).balance >= assetAmount, "Insufficient contract balance");

        payable(msg.sender).transfer(assetAmount);
        emit LiquidityWithdrawn(msg.sender, assetAmount, _shares);
    }

    function claimFees() external {
        _claimFees(msg.sender);
    }

    function _claimFees(address _user) internal nonReentrant {
        uint256 feesClaimed = pendingFees(_user);
        if (feesClaimed > 0) {
            totalFees -= feesClaimed;
            userFeeIndex[_user] = feeIndex;
            payable(_user).transfer(feesClaimed);
        }
    }

    function _distributeFees(uint256 _fee) internal {
        
        // Determine fee split
        uint256 insuranceFundFee = (_fee * INSURANCE_FUND_REWARD_SHARE) / 100;
        uint256 liquidityProviderFee = (_fee * LIQUIDITY_PROVIDER_REWARD_SHARE) / 100;
        

        // Allocate liquidty provider fees
        totalFees += liquidityProviderFee;

        // Distribute to insurance fund
        (bool success, ) = address(insuranceFund).call{
        require(success, "Insurance Fund fee transfer failed");

        if (totalLiquidityShares > 0) {
            feeIndex += (liquidityProviderFee * PRECISION) / totalLiquidityShares;
        }
    }

    function pendingFees(address _user) public view returns (uint256) {
        return (userLiquidityShares[_user] * (feeIndex - userFeeIndex[_user])) / PRECISION;
    }

    function getUserLiquidity(address _user) public view returns (uint256) {
        uint256 totalAssets = address(this).balance - totalFees;
        return (userLiquidityShares[_user] * totalAssets) / totalLiquidityShares;
    }

    function totalLiquidity() public view returns (uint256) {
        return address(this).balance - totalFees;
    }

    receive() external payable {
        emit Donation(msg.sender, msg.value);
    }
}
