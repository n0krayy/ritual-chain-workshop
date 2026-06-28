// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

/// @title BountyJudge — Privacy-preserving commit-reveal AI bounty judge
/// @notice Extends the workshop AIJudge pattern with a commit-reveal submission
///         flow so late participants cannot copy earlier answers before judging.
/// @dev    During the submission phase, participants submit only a keccak256
///         commitment of (answer, salt, msg.sender, bountyId). The plaintext
///         answer is revealed only after the submission deadline has passed
///         and before the reveal deadline. Only revealed submissions are
///         eligible for AI judging. Ritual-native (TEE/encrypted) judging is
///         an advanced-track design (see docs/ADVANCED_TRACK.md).
contract BountyJudge is PrecompileConsumer {
    uint256 public constant MAX_SUBMISSIONS = 10;
    uint256 public constant MAX_ANSWER_LENGTH = 2_000;

    uint256 public nextBountyId = 1;

    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    enum Phase {
        NotStarted,
        Submission,
        Reveal,
        Judging,
        Finalized
    }

    struct Submission {
        address submitter;
        bytes32 commitment;
        string answer;            // populated only after reveal
        bytes32 salt;             // populated only after reveal
        bool revealed;
        bool eligibleForJudging;  // true if reveal() passed hash check
    }

    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 submissionDeadline;
        uint256 revealDeadline;
        bool judged;
        bool finalized;
        address winner;
        bytes aiReview;
        bytes32 rankingHash;          // hash of AI ranking output
        string revealedAnswersRef;    // off-chain pointer to revealed bundle
        bytes32 revealedAnswersHash;  // hash of revealed answers bundle
        uint256 winnerClaimed;
    }

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    mapping(uint256 => Bounty) public bounties;
    mapping(uint256 => Submission[]) private _submissions;
    mapping(uint256 => mapping(address => uint256)) private _submitterToIndex;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string title,
        uint256 reward,
        uint256 submissionDeadline,
        uint256 revealDeadline
    );

    event CommitmentSubmitted(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter,
        bytes32 commitment
    );

    event AnswerRevealed(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter
    );

    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview, bytes32 rankingHash);

    event WinnerFinalized(
        uint256 indexed bountyId,
        address indexed winner,
        uint256 reward,
        string revealedAnswersRef,
        bytes32 revealedAnswersHash
    );

    event RewardClaimed(uint256 indexed bountyId, address indexed winner, uint256 amount);

    // ------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------

    modifier bountyExists(uint256 bountyId) {
        require(bounties[bountyId].owner != address(0), "bounty not found");
        _;
    }

    modifier onlyOwner(uint256 bountyId) {
        require(msg.sender == bounties[bountyId].owner, "not bounty owner");
        _;
    }

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error RewardRequired();
    error InvalidDeadline();
    error BountyNotFound();
    error PhaseWrong(uint256 currentPhase);
    error AlreadySubmitted();
    error TooManySubmissions();
    error CommitmentMismatch();
    error NotWinner();
    error AlreadyFinalized();
    error NothingToClaim();
    error JudgingFailed(string reason);
    error InvalidWinnerIndex();

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function getBounty(
        uint256 bountyId
    )
        external
        view
        bountyExists(bountyId)
        returns (BountyView memory)
    {
        Bounty storage b = bounties[bountyId];
        return BountyView({
            owner: b.owner,
            title: b.title,
            rubric: b.rubric,
            reward: b.reward,
            submissionDeadline: b.submissionDeadline,
            revealDeadline: b.revealDeadline,
            judged: b.judged,
            finalized: b.finalized,
            winner: b.winner,
            aiReview: b.aiReview,
            rankingHash: b.rankingHash,
            revealedAnswersRef: b.revealedAnswersRef,
            revealedAnswersHash: b.revealedAnswersHash,
            submissionCount: _submissions[bountyId].length
        });
    }

    struct BountyView {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 submissionDeadline;
        uint256 revealDeadline;
        bool judged;
        bool finalized;
        address winner;
        bytes aiReview;
        bytes32 rankingHash;
        string revealedAnswersRef;
        bytes32 revealedAnswersHash;
        uint256 submissionCount;
    }

    /// @notice Returns a submission. The plaintext answer is empty until revealed.
    function getSubmission(
        uint256 bountyId,
        uint256 index
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address submitter,
            bytes32 commitment,
            string memory answer,
            bytes32 salt,
            bool revealed,
            bool eligibleForJudging
        )
    {
        Submission storage s = _submissions[bountyId][index];
        return (
            s.submitter,
            s.commitment,
            s.answer,
            s.salt,
            s.revealed,
            s.eligibleForJudging
        );
    }

    function submissionCount(uint256 bountyId) external view returns (uint256) {
        return _submissions[bountyId].length;
    }

    /// @notice Returns the current lifecycle phase of a bounty.
    function phase(uint256 bountyId) public view bountyExists(bountyId) returns (Phase) {
        Bounty storage b = bounties[bountyId];
        if (b.finalized) return Phase.Finalized;
        if (b.judged) return Phase.Judging;
        if (block.timestamp >= b.revealDeadline) return Phase.Judging;
        if (block.timestamp >= b.submissionDeadline) return Phase.Reveal;
        return Phase.Submission;
    }

    // ------------------------------------------------------------------
    // Lifecycle
    // ------------------------------------------------------------------

    /// @notice Create a new bounty. The reward must be > 0 and submission deadline
    ///         must be in the future and before the reveal deadline.
    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 submissionDeadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        if (msg.value == 0) revert RewardRequired();
        if (submissionDeadline <= block.timestamp) revert InvalidDeadline();
        if (revealDeadline <= submissionDeadline) revert InvalidDeadline();

        bountyId = nextBountyId++;

        Bounty storage bounty = bounties[bountyId];
        bounty.owner = msg.sender;
        bounty.title = title;
        bounty.rubric = rubric;
        bounty.reward = msg.value;
        bounty.submissionDeadline = submissionDeadline;
        bounty.revealDeadline = revealDeadline;

        emit BountyCreated(
            bountyId,
            msg.sender,
            title,
            msg.value,
            submissionDeadline,
            revealDeadline
        );
    }

    /// @notice Submit a keccak256 commitment of (answer, salt, msg.sender, bountyId)
    ///         during the submission phase. Each address can submit at most one
    ///         commitment per bounty.
    /// @dev    Commitment formula mirrors the homework spec so off-chain clients
    ///         can compute it deterministically:
    ///             commitment = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
    function submitCommitment(
        uint256 bountyId,
        bytes32 commitment
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];
        if (block.timestamp >= bounty.submissionDeadline) revert PhaseWrong(uint(phase(bountyId)));
        if (_submitterToIndex[bountyId][msg.sender] != 0) revert AlreadySubmitted();
        if (_submissions[bountyId].length >= MAX_SUBMISSIONS) revert TooManySubmissions();

        _submissions[bountyId].push(
            Submission({
                submitter: msg.sender,
                commitment: commitment,
                answer: "",
                salt: bytes32(0),
                revealed: false,
                eligibleForJudging: false
            })
        );

        // 0 is reserved as the "not present" sentinel; real indices start at 1.
        _submitterToIndex[bountyId][msg.sender] = _submissions[bountyId].length;

        emit CommitmentSubmitted(bountyId, _submissions[bountyId].length - 1, msg.sender, commitment);
    }

    /// @notice Reveal an answer and salt. The contract recomputes the commitment
    ///         hash and confirms it matches what was submitted. Only valid reveals
    ///         are eligible for AI judging.
    function revealAnswer(
        uint256 bountyId,
        string calldata answer,
        bytes32 salt
    ) external bountyExists(bountyId) {
        Phase p = phase(bountyId);
        if (p != Phase.Reveal) revert PhaseWrong(uint(p));
        if (bytes(answer).length > MAX_ANSWER_LENGTH) revert InvalidWinnerIndex();

        uint256 idx = _submitterToIndex[bountyId][msg.sender];
        if (idx == 0) revert BountyNotFound();

        Submission storage s = _submissions[bountyId][idx - 1];
        if (s.revealed) revert AlreadySubmitted();

        bytes32 expected = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId));
        if (expected != s.commitment) revert CommitmentMismatch();

        s.answer = answer;
        s.salt = salt;
        s.revealed = true;
        s.eligibleForJudging = true;

        emit AnswerRevealed(bountyId, idx - 1, msg.sender);
    }

    /// @notice Run batched AI judging over all eligible revealed submissions.
    ///         Only the bounty owner can call this, and only after the reveal
    ///         deadline has passed. The LLM input is built off-chain and passed
    ///         here; the contract only stores the completion bytes and a hash
    ///         of the parsed ranking so the caller can verify determinism.
    /// @param  bountyId  Target bounty.
    /// @param  llmInput  ABI-encoded prompt for the Ritual LLM precompile.
    /// @param  rankingHash  keccak256 of the parsed ranking JSON (or other
    ///         canonical encoding). Stored on-chain so the off-chain reveal
    ///         bundle can be cross-checked.
    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput,
        bytes32 rankingHash
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];
        if (bounty.judged) revert AlreadyFinalized();
        if (block.timestamp < bounty.revealDeadline) revert PhaseWrong(uint(phase(bountyId)));

        bytes memory output = _executePrecompile(LLM_INFERENCE_PRECOMPILE, llmInput);

        // The Ritual LLM precompile returns
        // abi.encode(hasError, completionData, simmedInput, errorMessage, convoHistory).
        // We only care about hasError, errorMessage, and completionData.
        (bool hasError, bytes memory completionData, , string memory errorMessage) =
            abi.decode(output, (bool, bytes, bytes, string));

        if (hasError) revert JudgingFailed(errorMessage);

        bounty.judged = true;
        bounty.aiReview = completionData;
        bounty.rankingHash = rankingHash;
    }

    /// @notice Finalize the bounty by selecting a winner and publishing the
    ///         revealed-answers bundle reference + hash. Uses pull-pattern
    ///         payout: the winner must call claimReward() afterwards.
    /// @param  winnerIndex  Index into the bounty submissions array.
    /// @param  revealedAnswersRef  Off-chain pointer (ipfs://, ar://, https://...).
    /// @param  revealedAnswersHash  keccak256 of the canonical revealed bundle.
    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex,
        string calldata revealedAnswersRef,
        bytes32 revealedAnswersHash
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];
        if (!bounty.judged) revert PhaseWrong(uint(phase(bountyId)));
        if (bounty.finalized) revert AlreadyFinalized();
        if (winnerIndex >= _submissions[bountyId].length) revert InvalidWinnerIndex();
        if (!_submissions[bountyId][winnerIndex].eligibleForJudging) revert CommitmentMismatch();

        bounty.finalized = true;
        bounty.winner = _submissions[bountyId][winnerIndex].submitter;
        bounty.revealedAnswersRef = revealedAnswersRef;
        bounty.revealedAnswersHash = revealedAnswersHash;

        emit WinnerFinalized(
            bountyId,
            bounty.winner,
            bounty.reward,
            revealedAnswersRef,
            revealedAnswersHash
        );
    }

    /// @notice Winner pulls their reward. Pull-pattern is safer than push in
    ///         finalizeWinner() because it avoids re-entrancy concerns and
    ///         lets the winner pay gas only when they choose.
    function claimReward(uint256 bountyId) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];
        if (!bounty.finalized) revert PhaseWrong(uint(phase(bountyId)));
        if (msg.sender != bounty.winner) revert NotWinner();
        if (bounty.winnerClaimed == bounty.reward) revert NothingToClaim();

        uint256 amount = bounty.reward;
        bounty.winnerClaimed = amount;
        bounty.reward = 0;

        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "payment failed");

        emit RewardClaimed(bountyId, msg.sender, amount);
    }

    // ------------------------------------------------------------------
    // Off-chain helper (pure, exposed for clients/tests)
    // ------------------------------------------------------------------

    /// @notice Compute the keccak256 commitment off-chain (or call from tests).
    /// @param  answer     Plaintext answer.
    /// @param  salt       Caller-chosen random salt (32 bytes).
    /// @param  submitter  Address that will submit the commitment.
    /// @param  bountyId   Bounty identifier.
    function computeCommitment(
        string calldata answer,
        bytes32 salt,
        address submitter,
        uint256 bountyId
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, submitter, bountyId));
    }

    receive() external payable {}
}