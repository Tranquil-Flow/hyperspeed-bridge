// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

import {TokenRouter} from "./libs/TokenRouter.sol";
import {TokenMessage} from "./libs/TokenMessage.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

interface IUmbrellaFeeds {
    /// @notice method will revert if data for `_key` not exists.
    /// @param _key hash of feed name
    /// @return price
    function getPrice(bytes32 _key) external view returns (uint128 price);
}

// TODO: Determine the UmbrellaFeeds key for WRBTC-rUSDT & RBTC-USD (Fix getUmbrellaPriceFeedLatestAnswer)
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
    IUmbrellaFeeds public umbrellaFeeds;

    uint256 public ethereumInsuranceFundAmount; // Stores the amount of USD value in the Insurance Fund on Ethereum

    /**
     * @dev Emitted when native tokens are donated to the contract.
     * @param sender The address of the sender.
     * @param amount The amount of native tokens donated.
     */
    event Donation(address indexed sender, uint256 amount);

    constructor(address _mailbox) TokenRouter(_mailbox) {
        // Rootstock Mainnet UmbrellaFeeds: 0xDa9A63D77406faa09d265413F4E128B54b5057e0
        // Rootstock Testnet UmbrellaFeeds: 0x3F2254bc49d2d6e8422D71cB5384fB76005558A9
        umbrellaFeeds = IUmbrellaFeeds(0x3F2254bc49d2d6e8422D71cB5384fB76005558A9);
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
     */
    function transferRemote(
        uint32 _destination,
        bytes32 _recipient,
        uint256 _amount
    ) external payable virtual override returns (bytes32 messageId) {
        require(msg.value >= _amount, "Native: amount exceeds msg.value");
        uint256 _hookPayment = msg.value - _amount;

        // Get the latest RBTC/USD price from Umbrella Network
        uint128 rbtcUsdPrice = getUmbrellaPriceFeedLatestAnswer();
        
        // Calculate the USD value of the RBTC being bridged
        uint256 _usdValue = (_amount * uint256(rbtcUsdPrice)) / 1e18;

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
     */
    function _transferTo(
        address _recipient,
        uint256 _amount,
        bytes calldata // no metadata
    ) internal virtual override {

        // Get the latest RBTC/USD price from Umbrella Network
        uint128 rbtcUsdPrice = getUmbrellaPriceFeedLatestAnswer();

        // Calculate the amount that was received in BTC
        uint256 _rbtcValue = (_amount * uint256(rbtcUsdPrice)) / 1e18;
        
        Address.sendValue(payable(_recipient), _rbtcValue);
    }

    /**
     * @dev Gets the latest RBTC/USD price from UmbrellaFeeds
     * @return price The latest RBTC/USD price with 8 decimals
     */
    function getUmbrellaPriceFeedLatestAnswer() public view returns (uint128) {
        // Rootstock Mainnet WRBTC-rUSDT key: 0x0000000000000000000000000000000000000000000000000000000000000000
        // Rootstock Testnet RBTC-USD key: 0x0000000000000000000000000000000000000000000000000000000000000000
        uint128 answer = umbrellaFeeds.getPrice(0x0000000000000000000000000000000000000000000000000000000000000000);
        require(answer > 0, "Invalid RBTC/USD price");
        return answer;
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
        ethereumInsuranceFundAmount = _.message.insuranceFundAmount();
        _transferTo(recipient.bytes32ToAddress(), amount, metadata);
        emit ReceivedTransferRemote(_origin, recipient, amount);

    }

    receive() external payable {
        emit Donation(msg.sender, msg.value);
    }
}
