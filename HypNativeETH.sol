// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

import {TokenRouter} from "./libs/TokenRouter.sol";
import {TokenMessage} from "./libs/TokenMessage.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

// TODO: Track the amount of funds that can be currently bridged, given the amount in the Insuarance Fund and the amount awaiting finality.
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


    receive() external payable {
        emit Donation(msg.sender, msg.value);
    }
}
