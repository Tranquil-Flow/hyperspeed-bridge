// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

import {TokenRouter} from "./libs/TokenRouter.sol";
import {TokenMessage} from "./libs/TokenMessage.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

// TODO: Take bridging fees to fund the Insurance Fund & reward users who provide liquidity for bridging.

/**
 * @title Hyperlane Native Token Router that extends ERC20 with remote transfer functionality.
 * @author Abacus Works
 * @dev Supply on each chain is not constant but the aggregate supply across all chains is.
 * @dev Hyperspeed Bridge: This is an edited version of HypNative, allowing for:
 * - Bridging of native tokens across chains (i.e. deposit ETH on Ethereum and receive RBTC on Rootstock)
 * - Instant transfer of bridged assets, ignoring finality as long as the currently bridging amount does not exceed the insurance fund.
 * - Depositing of liquidity which is utilized by the contract for handling withdrawals and earns bridging fees.
 */
contract HypNative is TokenRouter {
    AggregatorV3Interface internal dataFeed;

    uint256 public rootstockInsuranceFundAmount; // Stores the amount of USD value in the Insurance Fund on Rootstock
    uint256 public pendingBridgeAmount; // The amount of USD value that is currently being bridged and has not reached finality.
    uint256 public constant FINALITY_PERIOD = 12; // The number of blocks required for finality on Ethereum.

    mapping(uint256 => PendingTransfer) public pendingTransfers; // Maps transfer IDs to their corresponding struct
    uint256 public nextTransferId; // The next transfer ID to be used

    /**
     * @dev Emitted when native tokens are donated to the contract.
     * @param sender The address of the sender.
     * @param amount The amount of native tokens donated.
     */
    event Donation(address indexed sender, uint256 amount);

    /**
     * @dev Constructor for the HypNative contract.
     * @param _mailbox The address of the mailbox contract.
     * @param _dataFeed The address of the Chainlink data feed for the depositing asset.
     */
    constructor(address _mailbox) TokenRouter(_mailbox) {
        // Ethereum Mainnet Chainlink Data Feed: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
        // Ethereum Sepolia Chainlink Data Feed: 0x694AA1769357215DE4FAC081bf1f309aDC325306
        dataFeed = AggregatorV3Interface(0x694AA1769357215DE4FAC081bf1f309aDC325306);
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
     * @dev Hyperspeed Bridge: Edited to calculate USD value of ETH being bridged and sends this value cross chain.
     * @dev Hyperspeed Bridge: Edited to check if the amount being bridged is within the safe bridgeable amount.
     */
    function transferRemote(
        uint32 _destination,
        bytes32 _recipient,
        uint256 _amount
    ) external payable virtual override returns (bytes32 messageId) {
        require(msg.value >= _amount, "Native: amount exceeds msg.value");
        uint256 _hookPayment = msg.value - _amount;

        // Get the latest ETH/USD price from Chainlink
        int256 ethUsdPrice = getChainlinkDataFeedLatestAnswer();
        
        // Calculate the USD value of the ETH being bridged
        uint256 _usdValue = (_amount * uint256(ethUsdPrice)) / 1e18;

        // Hyperspeed Bridge: Checks if any transfers have reached finality and updates the pending bridge amount accordingly.
        _processFinalizedTransfers();

        // Checks the safe amount that can be currently bridged given the Insurance Fund and the pending bridged amount awaiting finality.
        uint256 safeBridgeableAmount = getInsuranceFundAmount() - pendingBridgeAmount;
        require(_usdValue <= safeBridgeableAmount, "Exceeds safe bridgeable amount");

        // Updates the pending bridge amount and stores the transfer details.
        pendingBridgeAmount += _usdValue;
        pendingTransfers[nextTransferId] = PendingTransfer({
            amount: _usdValue,
            expirationBlock: block.number + FINALITY_PERIOD
        });
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
     * @dev Hyperspeed Bridge: Edited to receive the USD value of the incoming RBTC and convert it into ETH.
     */
    function _transferTo(
        address _recipient,
        uint256 _amount,
        bytes calldata // no metadata
    ) internal virtual override {

        // Get the latest ETH/USD price from Chainlink
        int256 ethUsdPrice = getChainlinkDataFeedLatestAnswer();

        // Calculate the amount that was received in ETH
        uint256 _ethValue = (_amount * uint256(ethUsdPrice)) / 1e18;

        Address.sendValue(payable(_recipient), _ethValue);
    }

    function getChainlinkDataFeedLatestAnswer() public view returns (int) {
        (
            /* uint80 roundID */,
            int answer,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = dataFeed.latestRoundData();
        require(answer > 0, "Invalid ETH/USD price");
        return answer;
    }

    function getInsuranceFundAmount() public view returns (uint256) {
        // Determine the amount of ETH in the Insurance Fund
        uint256 insuranceFundEthAmount = address(insuranceFund).balance;
        
        // Get the latest ETH/USD price from Chainlink
        int256 ethUsdPrice = getChainlinkDataFeedLatestAnswer();

        // Determine the amount of USD value in the Insurance Fund
        uint256 insuranceFundUsdAmount = (insuranceFundEthAmount * uint256(ethUsdPrice)) / 1e18;
        return insuranceFundUsdAmount;
    }


    /// @dev Hyperspeed Bridge: Edited to send the current amount of funds in the Insurance Fund in the message.
    function _transferRemote(
        uint32 _destination,
        bytes32 _recipient,
        uint256 _amountOrId,
        uint256 _value,
        bytes memory _hookMetadata,
        address _hook
    ) internal virtual override returns (bytes32 messageId) {
        uint256 _insuranceFundAmount = getInsuranceFundAmount();
        bytes memory _tokenMetadata = _transferFromSender(_amountOrId);
        bytes memory _tokenMessage = TokenMessage.format(
            _recipient,
            _amountOrId,
            _tokenMetadata,
            _insuranceFundAmount
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
        bytes32 recipient = _message.recipient();
        uint256 amount = _message.amount();
        bytes calldata metadata = _message.metadata();
        rootstockInsuranceFundAmount = _.message.insuranceFundAmount();
        _transferTo(recipient.bytes32ToAddress(), amount, metadata);
        emit ReceivedTransferRemote(_origin, recipient, amount);
    }

    function _processFinalizedTransfers() internal {
        uint256 i = nextTransferId - pendingTransfers.length;
        while (i < nextTransferId && pendingTransfers[i].expirationBlock <= block.number) {
            pendingBridgeAmount -= pendingTransfers[i].amount;
            delete pendingTransfers[i];
            i++;
        }
    }

    receive() external payable {
        emit Donation(msg.sender, msg.value);
    }
}
