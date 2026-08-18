// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import { IncoTest } from "@inco/lightning/src/test/IncoTest.sol";
import { GasSnapshot } from "forge-gas-snapshot/GasSnapshot.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Space } from "../../src/Space.sol";
import { VanillaAuthenticator } from "../../src/authenticators/VanillaAuthenticator.sol";
import { VanillaVotingStrategy } from "../../src/voting-strategies/VanillaVotingStrategy.sol";
import { VanillaExecutionStrategy } from "../../src/execution-strategies/VanillaExecutionStrategy.sol";
import {
    VanillaProposalValidationStrategy
} from "../../src/proposal-validation-strategies/VanillaProposalValidationStrategy.sol";
import { ISpaceEvents } from "../../src/interfaces/space/ISpaceEvents.sol";
import { ISpaceErrors } from "../../src/interfaces/space/ISpaceErrors.sol";
import { IExecutionStrategyErrors } from "../../src/interfaces/execution-strategies/IExecutionStrategyErrors.sol";
import { Strategy, IndexedStrategy, InitializeCalldata, TallyDecryption, TRUE, FALSE } from "../../src/types.sol";

// Inco imports for test helpers
import { euint256, inco } from "@inco/lightning/src/Lib.sol";
import { AllowanceProof } from "@inco/lightning/src/lightning-parts/AccessControl/AdvancedAccessControl.types.sol";

// solhint-disable-next-line max-states-count
abstract contract SpaceTest is IncoTest, GasSnapshot, ISpaceEvents, ISpaceErrors, IExecutionStrategyErrors {
    bytes4 internal constant PROPOSE_SELECTOR = bytes4(keccak256("propose(address,string,(address,bytes),bytes)"));
    bytes4 internal constant VOTE_SELECTOR = bytes4(keccak256("vote(address,uint256,bytes,(uint8,bytes)[],string)"));
    bytes4 internal constant UPDATE_PROPOSAL_SELECTOR =
        bytes4(keccak256("updateProposal(address,uint256,(address,bytes),string)"));
    bytes4 internal constant OWNABLE_UNAUTHORIZED_ACCOUNT_SELECTOR =
        bytes4(keccak256("OwnableUnauthorizedAccount(address)"));
    bytes4 internal constant OWNABLE_INVALID_OWNER_SELECTOR = bytes4(keccak256("OwnableInvalidOwner(address)"));
    bytes4 internal constant INVALID_INITIALIZATION_SELECTOR = bytes4(keccak256("InvalidInitialization()"));

    Space internal masterSpace;
    Space internal space;
    VanillaVotingStrategy internal vanillaVotingStrategy;
    VanillaAuthenticator internal vanillaAuthenticator;
    VanillaExecutionStrategy internal vanillaExecutionStrategy;
    VanillaProposalValidationStrategy internal vanillaProposalValidationStrategy;

    uint256 public constant AUTHOR_KEY = 1234;
    uint256 public constant VOTER_KEY = 5678;
    uint256 public constant UNAUTHORIZED_KEY = 4321;

    string internal voteMetadataURI = "Hi";

    // Address of the meta transaction relayer (mana)
    address public relayer = address(this);
    // Space owner — must be address(this) so the test contract can call onlyOwner functions directly
    address public spaceOwner = address(this);
    address public author = vm.addr(AUTHOR_KEY);
    address public voter = vm.addr(VOTER_KEY);
    address public unauthorized = vm.addr(UNAUTHORIZED_KEY);

    // Initial whitelisted modules set in the space
    Strategy[] internal votingStrategies;
    Strategy internal proposalValidationStrategy;
    address[] internal authenticators;
    Strategy[] internal executionStrategies;

    // Empty array used to edit settings
    Strategy[] internal NO_UPDATE_STRATEGIES;
    address[] internal NO_UPDATE_ADDRESSES;
    string[] internal NO_UPDATE_STRINGS;
    uint8[] internal NO_UPDATE_UINT8S;

    // Vanity address
    address internal NO_UPDATE_ADDRESS = address(bytes20(keccak256(abi.encodePacked("No update"))));
    Strategy internal NO_UPDATE_STRATEGY = Strategy(NO_UPDATE_ADDRESS, new bytes(0));
    uint32 internal NO_UPDATE_UINT32 = uint32(bytes4(keccak256(abi.encodePacked("No update"))));
    string internal NO_UPDATE_STRING = "No update";

    // Initial space parameters
    uint32 public votingDelay;
    uint32 public minVotingDuration;
    uint32 public maxVotingDuration;
    uint32 public quorum;

    // Default voting and execution strategy setups
    IndexedStrategy[] public userVotingStrategies;
    Strategy public executionStrategy;

    // Dummy metadata URIs
    string public daoURI = "SOC Test DAO";
    string public spaceMetadataURI = "SOC Test Space";
    string public proposalMetadataURI = "SOC Test Proposal";
    string[] public votingStrategyMetadataURIs;
    string public proposalValidationStrategyMetadataURI;

    // Empty proof for decryption attestation requests
    AllowanceProof internal emptyProof;
    // Cached Inco fee (per vote), forwarded with each vote under the voter-pays model.
    uint256 internal incoFee;

    function setUp() public virtual override {
        super.setUp(); // REQUIRED: deploys mocked Inco infra
        vm.stopPrank(); // IncoTest.setUp() leaves a startPrank active
        incoFee = inco.getFee();

        masterSpace = new Space();

        quorum = 1;

        vanillaVotingStrategy = new VanillaVotingStrategy();
        vanillaAuthenticator = new VanillaAuthenticator();
        vanillaExecutionStrategy = new VanillaExecutionStrategy(spaceOwner, quorum);
        vanillaProposalValidationStrategy = new VanillaProposalValidationStrategy();

        votingDelay = 0;
        minVotingDuration = 0;
        maxVotingDuration = 1000;
        votingStrategies.push(Strategy(address(vanillaVotingStrategy), new bytes(0)));
        votingStrategyMetadataURIs.push("VanillaVotingStrategy");
        authenticators.push(address(vanillaAuthenticator));
        executionStrategies.push(Strategy(address(vanillaExecutionStrategy), new bytes(0)));
        userVotingStrategies.push(IndexedStrategy(0, new bytes(0)));
        executionStrategy = Strategy(address(vanillaExecutionStrategy), new bytes(0));
        proposalValidationStrategy = Strategy(address(vanillaProposalValidationStrategy), new bytes(0));
        space = Space(
            payable(
                address(
                    new ERC1967Proxy(
                        address(masterSpace),
                        abi.encodeWithSelector(
                            Space.initialize.selector,
                            InitializeCalldata(
                                spaceOwner,
                                votingDelay,
                                minVotingDuration,
                                maxVotingDuration,
                                proposalValidationStrategy,
                                proposalValidationStrategyMetadataURI,
                                daoURI,
                                spaceMetadataURI,
                                votingStrategies,
                                votingStrategyMetadataURIs,
                                authenticators
                            )
                        )
                    )
                )
            )
        );

        // Fund the space (used by withdraw tests) and the relayer/sponsor (which forwards the
        // per-vote Inco fee when submitting signature-authenticated votes under the voter-pays model).
        vm.deal(address(space), 10 ether);
        vm.deal(address(this), 100 ether);
        // Discard setup logs; tests should process only logs emitted during test actions.
        vm.recordLogs();
    }

    /// @dev Process only newly-emitted Inco operations by resetting the log recorder after each flush.
    function _processAllOperations() internal {
        processAllOperations();
        vm.recordLogs();
    }

    function _createProposal(
        address _author,
        string memory _metadataURI,
        Strategy memory _executionStrategy,
        bytes memory userProposalValidationParams
    ) internal returns (uint256) {
        vanillaAuthenticator.authenticate(
            address(space),
            PROPOSE_SELECTOR,
            abi.encode(_author, _metadataURI, _executionStrategy, userProposalValidationParams)
        );

        return space.nextProposalId() - 1;
    }

    /// @dev Casts an encrypted vote. choiceValue: 0=Against, 1=For, 2=Abstain.
    ///      Forwards incoFee with the call so Space.vote()'s msg.value >= getFee() check passes (voter-pays model).
    function _vote(
        address _voter,
        uint256 _proposalId,
        uint256 _choiceValue,
        IndexedStrategy[] memory _userVotingStrategies,
        string memory _voteMetadataURI
    ) internal {
        bytes memory ciphertext = fakePrepareEuint256Ciphertext(
            _choiceValue,
            _voter,
            address(space)
        );
        vm.deal(_voter, _voter.balance + incoFee);
        vm.prank(_voter);
        vanillaAuthenticator.authenticate{ value: incoFee }(
            address(space),
            VOTE_SELECTOR,
            abi.encode(_voter, _proposalId, ciphertext, _userVotingStrategies, _voteMetadataURI)
        );
        _processAllOperations();
    }

    /// @dev Requests reveal and submits attested decryptions of all three tallies.
    ///      Assumes the caller has already rolled past maxEndBlockNumber.
    function _reveal(uint256 _proposalId) internal {
        _rollPastMaxEnd(_proposalId); // reveal is only valid after the voting period ends
        _processAllOperations(); // ensure tallies are computed in the mock KV
        space.requestReveal(_proposalId);
        space.finalizeReveal(_proposalId, _prepareTallies(_proposalId));
    }

    /// @dev Reveals while asserting the ProposalResultRevealed event (expectEmit anchored to finalizeReveal,
    ///      after requestReveal has already emitted RevealRequested).
    function _revealExpectingResult(
        uint256 _proposalId,
        uint256 _against,
        uint256 _for,
        uint256 _abstain,
        bool _passed
    ) internal {
        _processAllOperations();
        space.requestReveal(_proposalId);
        TallyDecryption[3] memory tallies = _prepareTallies(_proposalId);
        vm.expectEmit(true, true, true, true);
        emit ProposalResultRevealed(_proposalId, _against, _for, _abstain, _passed);
        space.finalizeReveal(_proposalId, tallies);
    }

    /// @dev Builds attested decryptions for a proposal's three tally handles (requester = address(this)).
    ///      Indexed 0=Against, 1=For, 2=Abstain to match the contract.
    function _prepareTallies(uint256 _proposalId) internal returns (TallyDecryption[3] memory tallies) {
        (euint256 againstH, euint256 forH, euint256 abstainH) = space.getVoteTallyHandles(_proposalId);
        tallies[0] = _attest(againstH);
        tallies[1] = _attest(forH);
        tallies[2] = _attest(abstainH);
    }

    /// @dev Produces an attested decryption for a single tally handle (requester = address(this)).
    function _attest(euint256 _handle) internal returns (TallyDecryption memory td) {
        (td.attestation, td.signatures) = getDecryptionAttestation(
            address(this), HandleWithProof({ handle: euint256.unwrap(_handle), proof: emptyProof })
        );
    }

    /// @dev Re-prepares attestations and asserts a second finalizeReveal reverts AlreadyRevealed.
    function _finalizeRevealAgainExpectAlreadyRevealed(uint256 _proposalId) internal {
        TallyDecryption[3] memory tallies = _prepareTallies(_proposalId);
        vm.expectRevert(AlreadyRevealed.selector);
        space.finalizeReveal(_proposalId, tallies);
    }

    /// @dev Builds the array with For/Against swapped (mismatched handles) to assert the handle check.
    function _finalizeRevealSwappedExpectMismatch(uint256 _proposalId) internal {
        (euint256 againstH, euint256 forH, euint256 abstainH) = space.getVoteTallyHandles(_proposalId);
        TallyDecryption[3] memory tallies;
        tallies[0] = _attest(forH); // For's attestation placed in the Against slot -> mismatch
        tallies[1] = _attest(againstH);
        tallies[2] = _attest(abstainH);
        vm.expectRevert("Tally handle mismatch");
        space.finalizeReveal(_proposalId, tallies);
    }

    /// @dev Submits a finalizeReveal with empty (zero-initialized) attestations for pre-voting-end gate tests.
    function _finalizeRevealEmpty(uint256 _proposalId) internal {
        TallyDecryption[3] memory tallies;
        space.finalizeReveal(_proposalId, tallies);
    }

    /// @dev Legacy helper: reveals then executes iff the proposal passed (mirrors old tryExecute semantics).
    ///      Assumes the caller has already rolled past maxEndBlockNumber.
    /// @dev Rolls to just past a proposal's maxEndBlockNumber if not already there (no-op if already past).
    function _rollPastMaxEnd(uint256 _proposalId) internal {
        (, , , , uint32 maxEnd, , , ) = space.proposals(_proposalId);
        if (block.number < maxEnd) vm.roll(uint256(maxEnd) + 1);
    }

    function _tryExecute(uint256 _proposalId, bytes memory _payload) internal {
        _reveal(_proposalId);
        (, , , bool passed) = space.result(_proposalId);
        if (passed) space.execute(_proposalId, _payload);
    }

    /// @dev Legacy helper: reveals, then expects execute() to revert with the given data.
    ///      Assumes the caller has already rolled past maxEndBlockNumber and the proposal passed.
    function _tryExecuteExpectRevert(uint256 _proposalId, bytes memory _payload, bytes memory _revertData) internal {
        _reveal(_proposalId);
        vm.expectRevert(_revertData);
        space.execute(_proposalId, _payload);
    }

    /// @dev Legacy helper: reveals, then expects execute() to revert for any reason.
    function _tryExecuteExpectAnyRevert(uint256 _proposalId, bytes memory _payload) internal {
        _reveal(_proposalId);
        vm.expectRevert();
        space.execute(_proposalId, _payload);
    }

    function _expectOnlyOwnerRevert(address caller) internal {
        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTHORIZED_ACCOUNT_SELECTOR, caller));
    }

    function _expectInvalidOwnerRevert() internal {
        vm.expectRevert(abi.encodeWithSelector(OWNABLE_INVALID_OWNER_SELECTOR, address(0)));
    }

    function _expectInvalidInitializationRevert() internal {
        vm.expectRevert(INVALID_INITIALIZATION_SELECTOR);
    }
}
