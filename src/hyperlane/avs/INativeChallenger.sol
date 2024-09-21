// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity >=0.8.0;

/*@@@@@@@       @@@@@@@@@
 @@@@@@@@@       @@@@@@@@@
  @@@@@@@@@       @@@@@@@@@
   @@@@@@@@@       @@@@@@@@@
    @@@@@@@@@@@@@@@@@@@@@@@@@
     @@@@@  HYPERLANE  @@@@@@@
    @@@@@@@@@@@@@@@@@@@@@@@@@
   @@@@@@@@@       @@@@@@@@@
  @@@@@@@@@       @@@@@@@@@
 @@@@@@@@@       @@@@@@@@@
@@@@@@@@@       @@@@@@@@*/

import {IMailbox} from "hyperspeed-bridge-fork/interfaces/IMailbox.sol";
import {Checkpoint} from "hyperspeed-bridge-fork/libs/CheckpointLib.sol";
import {TREE_DEPTH} from "hyperspeed-bridge-fork/libs/Merkle.sol";

interface INativeChallenger {
    /// @notice Set address of the Mailbox of the L2
    function setMailbox(IMailbox _mailbox) external;

    /// @notice Set address of the RemoteChallenger on Ethereum L1 (Sepolia)
    function setRemoteChallenger(address _remoteChallenger) external;

    /// @notice Whitelist a Merkle root which has been re-orged
    /// @dev Should not slash a validator for a re-orged root
    function whitelistReOrgedRoot(bytes32 root) external;

    /// @notice A Watcher can challenge the authenticity of an Operator's Checkpoint signature
    function challengeWhitelist(
        address operator,
        Checkpoint calldata checkpoint,
        bytes calldata signature
    ) external;

    /// @notice A Watcher can challenge the authenticity of an Operator's Checkpoint signature
    function challengePremature(
        address operator,
        Checkpoint calldata checkpoint,
        bytes calldata signature
    ) external;

    /// @notice A Watcher can challenge the authenticity of an Operator's Checkpoint signature
    function challengeMessageId(
        address operator,
        Checkpoint calldata checkpoint,
        bytes32[TREE_DEPTH] calldata proof,
        bytes32 actualMessageId,
        bytes calldata signature
    ) external;

    /// @notice A Watcher can challenge the authenticity of an Operator's Checkpoint signature
    function challengeRoot(
        address operator,
        Checkpoint calldata checkpoint,
        bytes32[TREE_DEPTH] calldata proof,
        bytes calldata signature
    ) external;
}
