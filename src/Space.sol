// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC4824 } from "src/interfaces/IERC4824.sol";
import { ISpace, ISpaceActions, ISpaceState, ISpaceOwnerActions } from "src/interfaces/ISpace.sol";
import {
    FinalizationStatus,
    IndexedStrategy,
    Proposal,
    ProposalStatus,
    ProposalResult,
    TallyDecryption,
    Strategy,
    UpdateSettingsCalldata,
    InitializeCalldata,
    TRUE,
    FALSE
} from "src/types.sol";
import { IVotingStrategy } from "src/interfaces/IVotingStrategy.sol";
import { IExecutionStrategy } from "src/interfaces/IExecutionStrategy.sol";
import { IProposalValidationStrategy } from "src/interfaces/IProposalValidationStrategy.sol";
import { SXUtils } from "./utils/SXUtils.sol";
import { BitPacker } from "./utils/BitPacker.sol";

// Inco imports
import { euint256, ebool, e, inco } from "@inco/lightning/src/Lib.sol";
import { DecryptionAttestation } from "@inco/lightning/src/lightning-parts/DecryptionAttester.types.sol";

/// @title Space Contract
/// @notice The core contract for Snapshot X with Inco confidential voting.
///         A proxy of this contract should be deployed with the Proxy Factory.
contract Space is ISpace, Initializable, IERC4824, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuard {
    using BitPacker for uint256;
    using SXUtils for IndexedStrategy[];
    using e for bytes;
    using e for euint256;
    using e for ebool;

    /// @dev Placeholder value to indicate the user does not want to update a string.
    /// @dev Evaluates to: `0xf2cda9b13ed04e585461605c0d6e804933ca828111bd94d4e6a96c75e8b048ba`.
    bytes32 private constant NO_UPDATE_HASH = keccak256(abi.encodePacked("No update"));

    /// @dev Placeholder value to indicate the user does not want to update an address.
    /// @dev Evaluates to: `0xf2cda9b13ed04e585461605c0d6e804933ca8281`.
    address private constant NO_UPDATE_ADDRESS = address(bytes20(keccak256(abi.encodePacked("No update"))));

    /// @dev Placeholder value to indicate the user does not want to update a uint32.
    /// @dev Evaluates to: `0xf2cda9b1`.
    uint32 private constant NO_UPDATE_UINT32 = uint32(bytes4(keccak256(abi.encodePacked("No update"))));

    /// @inheritdoc IERC4824
    string public daoURI;
    /// @inheritdoc ISpaceState
    uint32 public override maxVotingDuration;
    /// @inheritdoc ISpaceState
    uint32 public override minVotingDuration;
    /// @inheritdoc ISpaceState
    uint256 public override nextProposalId;
    /// @inheritdoc ISpaceState
    uint32 public override votingDelay;
    /// @inheritdoc ISpaceState
    uint256 public override activeVotingStrategies;
    /// @inheritdoc ISpaceState
    mapping(uint8 strategyIndex => Strategy strategy) public override votingStrategies;
    /// @inheritdoc ISpaceState
    uint8 public override nextVotingStrategyIndex;
    /// @inheritdoc ISpaceState
    Strategy public override proposalValidationStrategy;
    /// @inheritdoc ISpaceState
    mapping(address auth => uint256 allowed) public override authenticators;
    /// @inheritdoc ISpaceState
    mapping(uint256 proposalId => Proposal proposal) public override proposals;
    /// @inheritdoc ISpaceState
    mapping(uint256 proposalId => mapping(address voter => uint256 hasVoted)) public override voteRegistry;

    // Vote tallies stored as encrypted values. 0=Against, 1=For, 2=Abstain.
    // Private: no one can read running tallies.
    mapping(uint256 proposalId => mapping(uint8 choice => euint256)) private votePower;

    /// @inheritdoc ISpaceState
    mapping(uint256 proposalId => bool) public override revealed;

    /// @inheritdoc ISpaceState
    mapping(uint256 proposalId => ProposalResult) public override result;

    /// @inheritdoc ISpaceState
    mapping(uint256 proposalId => bool) public override isQuorumReached;
    /// @inheritdoc ISpaceState
    mapping(uint256 proposalId => bool) public override isSupportAchieved;

    /// @dev Allow the contract to receive ETH for Inco confidential compute fees.
    receive() external payable {}

    /// @dev Explicit funding entrypoint.
    function fund() external payable {}

    /// @dev Allows the owner to reclaim the space's Inco fee float.
    function withdraw(address payable to, uint256 amount) external onlyOwner nonReentrant {
        (bool ok, ) = to.call{ value: amount }("");
        if (!ok) revert WithdrawFailed();
    }

    /// @inheritdoc ISpaceActions
    function initialize(InitializeCalldata calldata input) external override initializer {
        if (input.votingStrategies.length == 0) revert EmptyArray();
        if (input.authenticators.length == 0) revert EmptyArray();
        if (input.votingStrategies.length != input.votingStrategyMetadataURIs.length) revert ArrayLengthMismatch();

        __Ownable_init(input.owner);
        _setDaoURI(input.daoURI);
        _setMaxVotingDuration(input.maxVotingDuration);
        _setMinVotingDuration(input.minVotingDuration);
        _setProposalValidationStrategy(input.proposalValidationStrategy);
        _setVotingDelay(input.votingDelay);
        _addVotingStrategies(input.votingStrategies);
        _addAuthenticators(input.authenticators);

        nextProposalId = 1;

        emit SpaceCreated(address(this), input);
    }

    // ------------------------------------
    // |                                  |
    // |             SETTERS              |
    // |                                  |
    // ------------------------------------

    /// @inheritdoc ISpaceOwnerActions
    // solhint-disable-next-line code-complexity
    function updateSettings(UpdateSettingsCalldata calldata input) external override onlyOwner {
        if ((input.minVotingDuration != NO_UPDATE_UINT32) && (input.maxVotingDuration != NO_UPDATE_UINT32)) {
            if (input.minVotingDuration > input.maxVotingDuration) {
                revert InvalidDuration(input.minVotingDuration, input.maxVotingDuration);
            }

            minVotingDuration = input.minVotingDuration;
            emit MinVotingDurationUpdated(input.minVotingDuration);

            maxVotingDuration = input.maxVotingDuration;
            emit MaxVotingDurationUpdated(input.maxVotingDuration);
        } else if (input.minVotingDuration != NO_UPDATE_UINT32) {
            _setMinVotingDuration(input.minVotingDuration);
            emit MinVotingDurationUpdated(input.minVotingDuration);
        } else if (input.maxVotingDuration != NO_UPDATE_UINT32) {
            _setMaxVotingDuration(input.maxVotingDuration);
            emit MaxVotingDurationUpdated(input.maxVotingDuration);
        }

        if (input.votingDelay != NO_UPDATE_UINT32) {
            _setVotingDelay(input.votingDelay);
            emit VotingDelayUpdated(input.votingDelay);
        }

        if (keccak256(abi.encodePacked(input.metadataURI)) != NO_UPDATE_HASH) {
            emit MetadataURIUpdated(input.metadataURI);
        }

        if (keccak256(abi.encodePacked(input.daoURI)) != NO_UPDATE_HASH) {
            _setDaoURI(input.daoURI);
            emit DaoURIUpdated(input.daoURI);
        }

        if (input.proposalValidationStrategy.addr != NO_UPDATE_ADDRESS) {
            _setProposalValidationStrategy(input.proposalValidationStrategy);
            emit ProposalValidationStrategyUpdated(
                input.proposalValidationStrategy,
                input.proposalValidationStrategyMetadataURI
            );
        }

        if (input.authenticatorsToAdd.length > 0) {
            _addAuthenticators(input.authenticatorsToAdd);
            emit AuthenticatorsAdded(input.authenticatorsToAdd);
        }

        if (input.authenticatorsToRemove.length > 0) {
            _removeAuthenticators(input.authenticatorsToRemove);
            emit AuthenticatorsRemoved(input.authenticatorsToRemove);
        }

        if (input.votingStrategiesToAdd.length > 0) {
            if (input.votingStrategiesToAdd.length != input.votingStrategyMetadataURIsToAdd.length) {
                revert ArrayLengthMismatch();
            }
            _addVotingStrategies(input.votingStrategiesToAdd);
            emit VotingStrategiesAdded(input.votingStrategiesToAdd, input.votingStrategyMetadataURIsToAdd);
        }

        if (input.votingStrategiesToRemove.length > 0) {
            _removeVotingStrategies(input.votingStrategiesToRemove);
            emit VotingStrategiesRemoved(input.votingStrategiesToRemove);
        }
    }

    /// @dev Gates access to whitelisted authenticators only.
    modifier onlyAuthenticator() {
        if (authenticators[msg.sender] == FALSE) revert AuthenticatorNotWhitelisted();
        _;
    }

    // ------------------------------------
    // |                                  |
    // |             GETTERS              |
    // |                                  |
    // ------------------------------------

    /// @inheritdoc ISpaceState
    function getProposalStatus(uint256 proposalId) external view override returns (ProposalStatus) {
        Proposal memory proposal = proposals[proposalId];
        _assertProposalExists(proposal);
        return
            proposal.executionStrategy.getProposalStatus(
                proposal,
                isQuorumReached[proposalId],
                isSupportAchieved[proposalId]
            );
    }

    /// @inheritdoc ISpaceState
    function getVoteTallyHandles(uint256 proposalId)
        external
        view
        override
        returns (euint256 againstHandle, euint256 forHandle, euint256 abstainHandle)
    {
        return (votePower[proposalId][0], votePower[proposalId][1], votePower[proposalId][2]);
    }

    // ------------------------------------
    // |                                  |
    // |             CORE                 |
    // |                                  |
    // ------------------------------------

    /// @inheritdoc ISpaceActions
    function propose(
        address author,
        string calldata metadataURI,
        Strategy calldata executionStrategy,
        bytes calldata userProposalValidationParams
    ) external override onlyAuthenticator {
        if (
            !IProposalValidationStrategy(proposalValidationStrategy.addr).validate(
                author,
                proposalValidationStrategy.params,
                userProposalValidationParams
            )
        ) revert FailedToPassProposalValidation();

        uint32 startBlockNumber = uint32(block.number) + votingDelay;
        uint32 minEndBlockNumber = startBlockNumber + minVotingDuration;
        uint32 maxEndBlockNumber = startBlockNumber + maxVotingDuration;

        bytes32 executionPayloadHash = keccak256(executionStrategy.params);

        Proposal memory proposal = Proposal(
            author,
            startBlockNumber,
            IExecutionStrategy(executionStrategy.addr),
            minEndBlockNumber,
            maxEndBlockNumber,
            FinalizationStatus.Pending,
            executionPayloadHash,
            activeVotingStrategies
        );

        proposals[nextProposalId] = proposal;

        // Initialize the three encrypted vote tallies to encrypted-zero so the handles always
        // exist and are revealable even if the proposal receives zero votes.
        // Trivial-encrypt (asEuint256) does not incur an Inco fee.
        for (uint8 choice = 0; choice < 3; choice++) {
            euint256 zero = e.asEuint256(0);
            zero.allowThis();
            votePower[nextProposalId][choice] = zero;
        }

        emit ProposalCreated(nextProposalId, author, proposal, metadataURI, executionStrategy.params);

        nextProposalId++;
    }

    /// @inheritdoc ISpaceActions
    function vote(
        address voter,
        uint256 proposalId,
        bytes calldata ciphertext,
        IndexedStrategy[] calldata userVotingStrategies,
        string calldata metadataURI
    ) external payable override onlyAuthenticator {
        // Voter-pays: the caller must forward at least the Inco fee that newEuint256() spends below.
        if (msg.value < inco.getFee()) revert InsufficientIncoFee();
        Proposal memory proposal = proposals[proposalId];
        _assertProposalExists(proposal);
        if (block.number >= proposal.maxEndBlockNumber) revert VotingPeriodHasEnded();
        if (block.number < proposal.startBlockNumber) revert VotingPeriodHasNotStarted();
        if (proposal.finalizationStatus != FinalizationStatus.Pending) revert ProposalFinalized();
        if (voteRegistry[proposalId][voter] != FALSE) revert UserAlreadyVoted();

        voteRegistry[proposalId][voter] = TRUE;

        uint256 votingPower = _getCumulativePower(
            voter,
            proposal.startBlockNumber,
            userVotingStrategies,
            proposal.activeVotingStrategies
        );
        if (votingPower == 0) revert UserHasNoVotingPower();

        // --- CONFIDENTIAL SECTION: accumulate encrypted tallies only ---

        // The only Inco-fee-charging op per vote: ingest the encrypted choice.
        bytes memory ciphertextMem = ciphertext;
        euint256 userChoice = ciphertextMem.newEuint256(voter);

        ebool isAgainst = userChoice.eq(uint256(0));
        ebool isFor = userChoice.eq(uint256(1));
        ebool isAbstain = userChoice.eq(uint256(2));

        euint256 encryptedPower = e.asEuint256(votingPower);

        // Against (0)
        euint256 newAgainst = isAgainst.select(votePower[proposalId][0].add(encryptedPower), votePower[proposalId][0]);
        newAgainst.allowThis();
        votePower[proposalId][0] = newAgainst;

        // For (1)
        euint256 newFor = isFor.select(votePower[proposalId][1].add(encryptedPower), votePower[proposalId][1]);
        newFor.allowThis();
        votePower[proposalId][1] = newFor;

        // Abstain (2)
        euint256 newAbstain = isAbstain.select(votePower[proposalId][2].add(encryptedPower), votePower[proposalId][2]);
        newAbstain.allowThis();
        votePower[proposalId][2] = newAbstain;

        // --- END CONFIDENTIAL SECTION ---

        if (bytes(metadataURI).length == 0) {
            emit VoteCast(proposalId, voter, votingPower);
        } else {
            emit VoteCastWithMetadata(proposalId, voter, votingPower, metadataURI);
        }
    }

    /// @inheritdoc ISpaceActions
    function requestReveal(uint256 proposalId) external override {
        Proposal storage proposal = proposals[proposalId];
        _assertProposalExists(proposal);
        if (proposal.finalizationStatus != FinalizationStatus.Pending) revert ProposalFinalized();
        if (block.number < proposal.maxEndBlockNumber) revert VotingPeriodNotEnded();
        if (revealed[proposalId]) revert AlreadyRevealed();

        // Grant the caller off-chain decryption access to the final (frozen) tallies.
        // Safe: voting has ended, so this cannot leak a running result.
        votePower[proposalId][0].allow(msg.sender);
        votePower[proposalId][1].allow(msg.sender);
        votePower[proposalId][2].allow(msg.sender);

        emit RevealRequested(proposalId, msg.sender);
    }

    /// @inheritdoc ISpaceActions
    function finalizeReveal(uint256 proposalId, TallyDecryption[3] memory tallies) external override {
        Proposal storage proposal = proposals[proposalId];
        _assertProposalExists(proposal);
        if (proposal.finalizationStatus != FinalizationStatus.Pending) revert ProposalFinalized();
        if (block.number < proposal.maxEndBlockNumber) revert VotingPeriodNotEnded();
        if (revealed[proposalId]) revert AlreadyRevealed();

        uint256 againstVotes = _verifyTally(proposalId, 0, tallies[0].attestation, tallies[0].signatures);
        uint256 forVotes = _verifyTally(proposalId, 1, tallies[1].attestation, tallies[1].signatures);
        uint256 abstainVotes = _verifyTally(proposalId, 2, tallies[2].attestation, tallies[2].signatures);

        uint256 quorumValue = proposal.executionStrategy.getQuorum();
        bool quorumReached = (forVotes + abstainVotes) >= quorumValue;
        bool supportAchieved = forVotes > againstVotes;

        isQuorumReached[proposalId] = quorumReached;
        isSupportAchieved[proposalId] = supportAchieved;

        // Let the execution strategy decide acceptance — Simple and Optimistic quorum interpret the
        // same (quorumReached, supportAchieved) flags differently. Voting has ended here, so the
        // strategy returns a final Accepted/Rejected status.
        ProposalStatus status = proposal.executionStrategy.getProposalStatus(proposal, quorumReached, supportAchieved);
        bool passed = status == ProposalStatus.Accepted || status == ProposalStatus.VotingPeriodAccepted;
        result[proposalId] = ProposalResult(againstVotes, forVotes, abstainVotes, passed);
        revealed[proposalId] = true;

        emit ProposalResultRevealed(proposalId, againstVotes, forVotes, abstainVotes, passed);
    }

    /// @inheritdoc ISpaceActions
    function execute(uint256 proposalId, bytes calldata executionPayload) external override {
        if (!revealed[proposalId]) revert NotRevealed();
        if (!result[proposalId].passed) revert ProposalNotPassed();
        _execute(proposalId, executionPayload);
    }

    /// @dev Verifies an attested decryption of a vote tally handle and returns the cleartext count.
    function _verifyTally(
        uint256 proposalId,
        uint8 choice,
        DecryptionAttestation memory attestation,
        bytes[] memory signatures
    ) internal view returns (uint256) {
        require(
            inco.incoVerifier().isValidDecryptionAttestation(attestation, signatures),
            "Invalid tally attestation"
        );
        require(
            euint256.unwrap(votePower[proposalId][choice]) == attestation.handle,
            "Tally handle mismatch"
        );
        return uint256(attestation.value);
    }

    /// @inheritdoc ISpaceOwnerActions
    function cancel(uint256 proposalId) external override onlyOwner {
        Proposal storage proposal = proposals[proposalId];
        _assertProposalExists(proposal);
        if (proposal.finalizationStatus != FinalizationStatus.Pending) revert ProposalFinalized();
        proposal.finalizationStatus = FinalizationStatus.Cancelled;
        emit ProposalCancelled(proposalId);
    }

    /// @inheritdoc ISpaceActions
    function updateProposal(
        address author,
        uint256 proposalId,
        Strategy calldata executionStrategy,
        string calldata metadataURI
    ) external override onlyAuthenticator {
        Proposal storage proposal = proposals[proposalId];
        _assertProposalExists(proposal);
        if (proposal.finalizationStatus != FinalizationStatus.Pending) revert ProposalFinalized();
        if (author != proposal.author) revert InvalidCaller();
        if (block.number >= proposal.startBlockNumber) revert VotingDelayHasPassed();

        proposal.executionPayloadHash = keccak256(executionStrategy.params);
        proposal.executionStrategy = IExecutionStrategy(executionStrategy.addr);

        emit ProposalUpdated(proposalId, executionStrategy, metadataURI);
    }

    // ------------------------------------
    // |                                  |
    // |            INTERNAL              |
    // |                                  |
    // ------------------------------------

    /// @dev Internal execution, called only after attestation verification.
    function _execute(uint256 proposalId, bytes calldata executionPayload) internal nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        _assertProposalExists(proposal);
        Proposal memory cachedProposal = proposal;
        if (cachedProposal.executionPayloadHash != keccak256(executionPayload)) revert InvalidPayload();
        if (cachedProposal.finalizationStatus != FinalizationStatus.Pending) revert ProposalFinalized();

        proposal.finalizationStatus = FinalizationStatus.Executed;

        proposal.executionStrategy.execute(
            proposalId,
            cachedProposal,
            isQuorumReached[proposalId],
            isSupportAchieved[proposalId],
            executionPayload
        );

        emit ProposalExecuted(proposalId);
    }

    /// @dev Only the Space owner can authorize an upgrade to this contract.
    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev Sets the maximum voting duration.
    function _setMaxVotingDuration(uint32 _maxVotingDuration) internal {
        if (_maxVotingDuration < minVotingDuration) revert InvalidDuration(minVotingDuration, _maxVotingDuration);
        maxVotingDuration = _maxVotingDuration;
    }

    /// @dev Sets the minimum voting duration.
    function _setMinVotingDuration(uint32 _minVotingDuration) internal {
        if (_minVotingDuration > maxVotingDuration) revert InvalidDuration(_minVotingDuration, maxVotingDuration);
        minVotingDuration = _minVotingDuration;
    }

    /// @dev Sets the proposal validation strategy.
    function _setProposalValidationStrategy(Strategy calldata _proposalValidationStrategy) internal {
        proposalValidationStrategy = _proposalValidationStrategy;
    }

    /// @dev Sets the voting delay.
    function _setVotingDelay(uint32 _votingDelay) internal {
        votingDelay = _votingDelay;
    }

    /// @dev Sets the DAO URI.
    function _setDaoURI(string calldata _daoURI) internal {
        daoURI = _daoURI;
    }

    /// @dev Adds an array of voting strategies.
    function _addVotingStrategies(Strategy[] calldata _votingStrategies) internal {
        uint256 cachedActiveVotingStrategies = activeVotingStrategies;
        uint8 cachedNextVotingStrategyIndex = nextVotingStrategyIndex;
        if (cachedNextVotingStrategyIndex >= 256 - _votingStrategies.length) revert ExceedsStrategyLimit();
        for (uint256 i = 0; i < _votingStrategies.length; i++) {
            if (_votingStrategies[i].addr == address(0)) revert ZeroAddress();
            cachedActiveVotingStrategies = cachedActiveVotingStrategies.setBit(cachedNextVotingStrategyIndex, true);
            votingStrategies[cachedNextVotingStrategyIndex] = _votingStrategies[i];
            cachedNextVotingStrategyIndex++;
        }
        activeVotingStrategies = cachedActiveVotingStrategies;
        nextVotingStrategyIndex = cachedNextVotingStrategyIndex;
    }

    /// @dev Removes an array of voting strategies, specified by their indices.
    function _removeVotingStrategies(uint8[] calldata _votingStrategyIndices) internal {
        for (uint8 i = 0; i < _votingStrategyIndices.length; i++) {
            activeVotingStrategies = activeVotingStrategies.setBit(_votingStrategyIndices[i], false);
        }
        if (activeVotingStrategies == 0) revert NoActiveVotingStrategies();
    }

    /// @dev Adds an array of authenticators.
    function _addAuthenticators(address[] calldata _authenticators) internal {
        for (uint256 i = 0; i < _authenticators.length; i++) {
            authenticators[_authenticators[i]] = TRUE;
        }
    }

    /// @dev Removes an array of authenticators.
    function _removeAuthenticators(address[] calldata _authenticators) internal {
        for (uint256 i = 0; i < _authenticators.length; i++) {
            authenticators[_authenticators[i]] = FALSE;
        }
    }

    /// @dev Reverts if a specified proposal does not exist.
    function _assertProposalExists(Proposal memory proposal) internal pure {
        if (proposal.executionPayloadHash == 0) revert InvalidProposal();
    }

    /// @dev Returns the cumulative voting power of a user over a set of voting strategies.
    function _getCumulativePower(
        address userAddress,
        uint32 blockNumber,
        IndexedStrategy[] calldata userStrategies,
        uint256 allowedStrategies
    ) internal view returns (uint256) {
        userStrategies.assertNoDuplicateIndicesCalldata();

        uint256 totalVotingPower;
        for (uint256 i = 0; i < userStrategies.length; ++i) {
            uint8 strategyIndex = userStrategies[i].index;

            if (!allowedStrategies.isBitSet(strategyIndex)) {
                revert InvalidStrategyIndex(strategyIndex);
            }

            Strategy memory strategy = votingStrategies[strategyIndex];

            totalVotingPower += IVotingStrategy(strategy.addr).getVotingPower(
                blockNumber,
                userAddress,
                strategy.params,
                userStrategies[i].params
            );
        }
        return totalVotingPower;
    }
}
