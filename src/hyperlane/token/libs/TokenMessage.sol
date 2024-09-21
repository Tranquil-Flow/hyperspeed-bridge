// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity >=0.8.0;

/// @dev Hyperspeed Bridge: Edited to include an extra data field for the insurance fund amount.
library TokenMessage {
    function format(
        bytes32 _recipient,
        uint256 _amount,
        bytes memory _metadata,
        uint256 _insuranceFundAmount,
        uint256 _availableLiquidity,
        uint256 _transferId,
        uint256 _blockNumber
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(_recipient, _amount, _metadata, _insuranceFundAmount, _availableLiquidity, _transferId, _blockNumber);
    }

    function recipient(bytes calldata message) internal pure returns (bytes32) {
        return bytes32(message[0:32]);
    }

    function amount(bytes calldata message) internal pure returns (uint256) {
        return uint256(bytes32(message[32:64]));
    }

    // alias for ERC721
    function tokenId(bytes calldata message) internal pure returns (uint256) {
        return amount(message);
    }

    function metadata(bytes calldata message) internal pure returns (bytes calldata) {
        return message[64:message.length - 64];
    }

    function insuranceFundAmount(bytes calldata message) internal pure returns (uint256) {
        return uint256(bytes32(message[message.length - 64:message.length - 32]));
    }

    function availableLiquidity(bytes calldata message) internal pure returns (uint256) {
        return uint256(bytes32(message[message.length - 32:]));
    }

    function transferId(bytes calldata message) internal pure returns (uint256) {
        return uint256(bytes32(message[message.length - 96:message.length - 64]));
    }

    function blockNumber(bytes calldata message) internal pure returns (uint256) {
        return uint256(bytes32(message[message.length - 64:message.length - 32]));
    }
}
