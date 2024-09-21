// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

// TODO: Implement a yield-generating strategy for the insurance fund

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title InsuranceFund
/// @author TranquilFlow
/// @notice This contract is used to manage the insurance fund for the Hyperspeed Bridge.
/// @dev Built with a similar structure to ERC4626
/// @dev Receives rewards from yield-generating strategy, bridge fees and any slashing events.
contract InsuranceFund is ReentrancyGuard {
    address public hypNativeContract;

    address public yieldStrategy;

    uint256 public totalShares;
    mapping(address => uint256) public userShares;

    bool public hypNativeContractSet;

    event Deposited(address indexed user, uint256 amount, uint256 shares);
    event Withdrawn(address indexed user, uint256 amount, uint256 shares);
    event Liquidated(address indexed recipient, uint256 amount);
    event HypNativeContractSet(address indexed hypNativeContract);

    constructor(address _yieldStrategy) {
        yieldStrategy = _yieldStrategy;
    }

    function setHypNativeContract(address _hypNativeContract) external {
        require(!hypNativeContractSet, "HypNative contract already set");
        require(_hypNativeContract != address(0), "Invalid HypNative contract address");
        
        hypNativeContract = _hypNativeContract;
        hypNativeContractSet = true;
        
        emit HypNativeContractSet(_hypNativeContract);
    }

    function deposit() external payable nonReentrant {
        require(msg.value > 0, "Deposit amount must be greater than 0");

        uint256 shares = totalShares == 0 ? msg.value : (msg.value * totalShares) / address(this).balance;
        userShares[msg.sender] += shares;
        totalShares += shares;

        // Deposit funds into yield-generating strategy
        // IYieldStrategy(yieldStrategy).deposit{value: msg.value}();

        emit Deposited(msg.sender, msg.value, shares);
    }

    function withdraw(uint256 shares) external nonReentrant {
        require(shares > 0, "Withdrawal shares must be greater than 0");
        require(userShares[msg.sender] >= shares, "Insufficient shares");

        uint256 amount = (shares * address(this).balance) / totalShares;
        userShares[msg.sender] -= shares;
        totalShares -= shares;

        // Withdraw funds from yield-generating strategy if necessary
        // IYieldStrategy(yieldStrategy).withdraw(amount);
        
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");

        emit Withdrawn(msg.sender, amount, shares);
    }

    function liquidateForReorg(uint256 amount) external {
        require(hypNativeContractSet, "HypNative contract not set");
        require(msg.sender == hypNativeContract, "Only HypNative contract can liquidate");
        require(amount <= address(this).balance, "Insufficient funds in the insurance pool");

        // Withdraw funds from yield-generating strategy if necessary
        // IYieldStrategy(yieldStrategy).withdraw(amount);
        
        (bool success, ) = payable(hypNativeContract).call{value: amount}("");
        require(success, "Transfer failed");

        emit Liquidated(hypNativeContract, amount);
    }
    function getUserShares(address user) external view returns (uint256) {
        return userShares[user];
    }

    function getTotalShares() external view returns (uint256) {
        return totalShares;
    }

    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function convertSharesToAmount(uint256 shares) public view returns (uint256) {
        if (totalShares == 0) return 0;
        return (shares * address(this).balance) / totalShares;
    }

    function convertAmountToShares(uint256 amount) public view returns (uint256) {
        if (totalShares == 0) return amount;
        return (amount * totalShares) / address(this).balance;
    }

    receive() external payable {
    }

}