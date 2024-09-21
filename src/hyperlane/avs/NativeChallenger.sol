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

import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";

import {IMailbox} from "hyperspeed-bridge-fork/interfaces/IMailbox.sol";
import {INativeChallenger} from "./INativeChallenger.sol";
import {TREE_DEPTH} from "hyperspeed-bridge-fork/libs/Merkle.sol";
import {CheckpointLib, Checkpoint} from "hyperspeed-bridge-fork/libs/CheckpointLib.sol";
import "hyperspeed-bridge-fork/AttributeCheckpointFraud.sol";

/**
 * @dev Contract on the origin chain, which verifies and attributes fraud to a specific ECDSA checkpoint signer.
 */
contract NativeChallenger is AttributeCheckpointFraud, INativeChallenger {
    using CheckpointLib for Checkpoint;

    /// @notice Mailbox to use to send the challenge to Ethereum L1 (Sepolia)
    IMailbox public mailbox;

    /// @notice Address of the RemoteChallenger on Ethereum L1 (Sepolia)
    address public remoteChallenger;

    /// @notice Destination domain of the Ethereum L1 (Sepolia)
    uint32 public constant destinationDomain = 11155111;

    // Mapping to store if a root has been re-orged
    mapping(bytes32 => bool) internal hasBeenReOrged;

    /* ============ ADMIN FUNCTIONS ============ */

    /// @notice Set address of the Mailbox of the L2
    function setMailbox(IMailbox _mailbox) external onlyOwner {
        mailbox = _mailbox;
    }

    /// @notice Set address of the RemoteChallenger on Ethereum L1 (Sepolia)
    function setRemoteChallenger(address _remoteChallenger) external onlyOwner {
        remoteChallenger = _remoteChallenger;
    }

    /// @notice Whitelist a Merkle root which has been re-orged
    /// @dev Should not slash a validator for a re-orged root
    function whitelistReOrgedRoot(bytes32 root) external onlyOwner {
        hasBeenReOrged[root] = true;
    }

    /* ============ EXTERNAL FUNCTIONS ============ */

    /// @notice A Watcher can challenge the authenticity of an Operator's Checkpoint signature
    function challengeWhitelist(
        address operator,
        Checkpoint calldata checkpoint,
        bytes calldata signature
    )
        external
        onlyIfOperatorIsSigner(operator, checkpoint, signature)
        onlyNonReorgedRoot(checkpoint.root)
    {
        attributeWhitelist(checkpoint, signature);
        Attribution memory attribution = attributions(checkpoint, signature);
        _postChallenge(attribution);
    }

    /// @notice A Watcher can challenge the authenticity of an Operator's Checkpoint signature
    function challengePremature(
        address operator,
        Checkpoint calldata checkpoint,
        bytes calldata signature
    )
        external
        onlyIfOperatorIsSigner(operator, checkpoint, signature)
        onlyNonReorgedRoot(checkpoint.root)
    {
        attributePremature(checkpoint, signature);
        Attribution memory attribution = attributions(checkpoint, signature);
        _postChallenge(attribution);
    }

    /// @notice A Watcher can challenge the authenticity of an Operator's Checkpoint signature
    function challengeMessageId(
        address operator,
        Checkpoint calldata checkpoint,
        bytes32[TREE_DEPTH] calldata proof,
        bytes32 actualMessageId,
        bytes calldata signature
    )
        external
        onlyIfOperatorIsSigner(operator, checkpoint, signature)
        onlyNonReorgedRoot(checkpoint.root)
    {
        attributeMessageId(checkpoint, proof, actualMessageId, signature);
        Attribution memory attribution = attributions(checkpoint, signature);
        _postChallenge(attribution);
    }

    /// @notice A Watcher can challenge the authenticity of an Operator's Checkpoint signature
    function challengeRoot(
        address operator,
        Checkpoint calldata checkpoint,
        bytes32[TREE_DEPTH] calldata proof,
        bytes calldata signature
    )
        external
        onlyIfOperatorIsSigner(operator, checkpoint, signature)
        onlyNonReorgedRoot(checkpoint.root)
    {
        attributeRoot(checkpoint, proof, signature);
        Attribution memory attribution = attributions(checkpoint, signature);
        _postChallenge(attribution);
    }

    /* ============ PRIVATE FUNCTIONS ============ */

    function _getCheckpointSigner(
        Checkpoint calldata checkpoint,
        bytes calldata signature
    ) internal pure returns (address signer) {
        bytes32 digest = checkpoint.digest();
        signer = ECDSA.recover(digest, signature);
    }

    function _postChallenge(Attribution memory attribution) internal {
        require(remoteChallenger != address(0), "RemoteChallenger not set");
        require(mailbox != IMailbox(address(0)), "Mailbox not set");

        // Structure to represent the challenge data
        bytes memory body = abi.encode(
            attribution.signer,
            attribution.timestamp,
            uint8(attribution.fraudType)
        );

        // Get the quote for the dispatch
        uint256 quote = mailbox.quoteDispatch(
            destinationDomain,
            bytes32(uint256(uint160(remoteChallenger))),
            body
        );

        // Dispatch the message
        mailbox.dispatch{value: quote}(
            destinationDomain,
            bytes32(uint256(uint160(remoteChallenger))),
            body
        );
    }

    /* ============ MODIFIERS ============ */

    modifier onlyNonReorgedRoot(bytes32 root) {
        require(
            !hasBeenReOrged[root],
            "Root has been re-orged, don't slash validator"
        );
        _;
    }

    modifier onlyIfOperatorIsSigner(
        address operator,
        Checkpoint calldata checkpoint,
        bytes calldata signature
    ) {
        require(
            _getCheckpointSigner(checkpoint, signature) == operator,
            "Operator is not the checkpoint signer"
        );
        _;
    }
}
