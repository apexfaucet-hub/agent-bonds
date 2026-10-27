// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title G2Jobs
/// @notice ERC-8183-readable job escrow that protects the agent who does the work. APEX Faucet, 2026-10-13.
/// @dev Same function names, arguments and events as ERC-8183 (Agentic Commerce, draft), so 8183 tools can read every job.
///      Stricter in four places (see hackathon/g2-jobs/DESIGN.md):
///       1. No owner, no upgrade: token, fee and fee recipient are immutable.
///       2. Review window: after submit, the evaluator has `reviewSeconds` to complete or reject; if it stays silent,
///          anyone may `settle` and the provider is paid. A submitted job is never refunded by expiry.
///       3. Kill fee: a rejection AFTER submission pays `killFeeBps` (max 25%) of the budget to the provider, for ANY rejected
///          submission; the client gets the rest. A client that is its own evaluator cannot reject a funded job before
///          submission; it recovers its money with claimRefund at the deadline.
///       4. A pointer to the work: `submitWithUri` emits a link next to the deliverable hash.
///      No hooks in v1 (createJob with a non-zero hook reverts), so refunds and settlement can never be blocked by external code.
///      Payouts are pushed; a payout the token refuses (e.g. a USDC-blacklisted address) is credited instead and withdrawn later,
///      so one bad address can never lock another party's money.
contract G2Jobs is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum JobStatus { Open, Funded, Submitted, Completed, Rejected, Expired }

    struct Job {
        address client;
        JobStatus status;
        address provider;
        uint48 expiredAt;
        address evaluator;
        uint48 submittedAt;
        uint32 reviewSeconds;
        uint16 killFeeBps;
        uint256 budget;
        string description;
    }

    uint32 public constant MIN_REVIEW = 1 hours;
    uint32 public constant MAX_REVIEW = 7 days;
    uint32 public constant DEFAULT_REVIEW = 1 days;
    uint16 public constant MAX_KILL_FEE_BPS = 2500;   // review 13 Oct: 50% let a provider earn by submitting junk
    uint256 public constant MAX_JOB_LIFETIME = 365 days;
    /// @notice The reason recorded when a job is paid by `settle` (the evaluator did not decide).
    bytes32 public constant TIMEOUT_SETTLE = bytes32("G2:TIMEOUT_SETTLE");
    uint16 public constant MAX_PLATFORM_FEE_BPS = 1000;
    uint256 public constant MAX_DESCRIPTION_BYTES = 4000;
    uint256 public constant MAX_URI_BYTES = 512;

    IERC20 public immutable paymentToken;
    uint16 public immutable platformFeeBP;
    address public immutable feeRecipient;

    uint256 public jobCounter;
    uint256 public totalEscrowed;
    mapping(uint256 => Job) internal _jobs;
    /// @notice Payouts the token refused to deliver (e.g. a blacklisted address), withdrawable by their owner.
    mapping(address => uint256) public credits;
    uint256 public totalCredits;

    // ERC-8183 events
    event JobCreated(uint256 indexed jobId, address indexed client, address indexed provider, address evaluator, uint256 expiredAt, address hook);
    event ProviderSet(uint256 indexed jobId, address indexed provider);
    event BudgetSet(uint256 indexed jobId, uint256 amount);
    event JobFunded(uint256 indexed jobId, address indexed client, uint256 amount);
    event JobSubmitted(uint256 indexed jobId, address indexed provider, bytes32 deliverable);
    event JobCompleted(uint256 indexed jobId, address indexed evaluator, bytes32 reason);
    event JobRejected(uint256 indexed jobId, address indexed rejector, bytes32 reason);
    event JobExpired(uint256 indexed jobId);
    event PaymentReleased(uint256 indexed jobId, address indexed provider, uint256 amount);
    event Refunded(uint256 indexed jobId, address indexed client, uint256 amount);
    // G2 Jobs additions
    event JobTerms(uint256 indexed jobId, uint32 reviewSeconds, uint16 killFeeBps);
    event DeliverableUri(uint256 indexed jobId, string uri);
    event JobSettled(uint256 indexed jobId, address indexed caller);
    event KillFeePaid(uint256 indexed jobId, address indexed provider, uint256 amount);
    event PlatformFeePaid(uint256 indexed jobId, address indexed recipient, uint256 amount);
    event Credited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);

    error InvalidJob();
    error WrongStatus();
    error Unauthorized();
    error ZeroAddress();
    error ExpiryTooShort();
    error ZeroBudget();
    error ProviderNotSet();
    error BudgetMismatch();
    error HooksNotSupported();
    error BadTerms();
    error TooLong();
    error Expired_();
    error ReviewWindowOpen();
    error ReviewWindowOver();
    error NotExpiredYet();
    error FeeOnTransferToken();
    error NothingToWithdraw();
    error EvaluatorIsProvider();
    error ClientEvaluatorMustWait();

    constructor(address token_, uint16 platformFeeBP_, address feeRecipient_) {
        if (token_ == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();
        if (platformFeeBP_ > MAX_PLATFORM_FEE_BPS) revert BadTerms();
        paymentToken = IERC20(token_);
        platformFeeBP = platformFeeBP_;
        feeRecipient = feeRecipient_;
    }

    // ───────────────────────── create ─────────────────────────

    /// @notice ERC-8183 createJob. Uses the default terms: a 1-day review window and no kill fee.
    function createJob(address provider, address evaluator, uint256 expiredAt, string calldata description, address hook)
        external nonReentrant returns (uint256)
    {
        if (hook != address(0)) revert HooksNotSupported();
        return _create(provider, evaluator, expiredAt, description, DEFAULT_REVIEW, 0);
    }

    /// @notice createJob with explicit terms: review window (1 h - 7 days) and kill fee (0 - 50%).
    function createJobWithTerms(address provider, address evaluator, uint256 expiredAt, string calldata description,
        uint32 reviewSeconds, uint16 killFeeBps) external nonReentrant returns (uint256)
    {
        if (reviewSeconds < MIN_REVIEW || reviewSeconds > MAX_REVIEW || killFeeBps > MAX_KILL_FEE_BPS) revert BadTerms();
        return _create(provider, evaluator, expiredAt, description, reviewSeconds, killFeeBps);
    }

    function _create(address provider, address evaluator, uint256 expiredAt, string calldata description,
        uint32 reviewSeconds, uint16 killFeeBps) internal returns (uint256 jobId)
    {
        if (evaluator == address(0)) revert ZeroAddress();
        if (provider != address(0) && provider == evaluator) revert EvaluatorIsProvider();
        if (expiredAt <= block.timestamp + 5 minutes || expiredAt > block.timestamp + MAX_JOB_LIFETIME) revert ExpiryTooShort();
        if (bytes(description).length > MAX_DESCRIPTION_BYTES) revert TooLong();
        jobId = ++jobCounter;
        Job storage j = _jobs[jobId];
        j.client = msg.sender;
        j.provider = provider;
        j.evaluator = evaluator;
        j.expiredAt = uint48(expiredAt);
        j.reviewSeconds = reviewSeconds;
        j.killFeeBps = killFeeBps;
        j.description = description;
        emit JobCreated(jobId, msg.sender, provider, evaluator, expiredAt, address(0));
        emit JobTerms(jobId, reviewSeconds, killFeeBps);
        if (provider != address(0)) emit ProviderSet(jobId, provider);
    }

    // ───────────────────────── negotiate ─────────────────────────

    function setProvider(uint256 jobId, address provider) external nonReentrant {
        Job storage j = _job(jobId);
        if (j.status != JobStatus.Open) revert WrongStatus();
        if (msg.sender != j.client) revert Unauthorized();
        if (j.provider != address(0)) revert WrongStatus();
        if (provider == address(0)) revert ZeroAddress();
        if (provider == j.evaluator) revert EvaluatorIsProvider();
        j.provider = provider;
        emit ProviderSet(jobId, provider);
    }

    /// @notice Client or provider sets the price while the job is Open. `optParams` is ignored (no hooks).
    function setBudget(uint256 jobId, uint256 amount, bytes calldata) external nonReentrant {
        Job storage j = _job(jobId);
        if (j.status != JobStatus.Open) revert WrongStatus();
        if (msg.sender != j.client && msg.sender != j.provider) revert Unauthorized();
        j.budget = amount;
        emit BudgetSet(jobId, amount);
    }

    // ───────────────────────── escrow ─────────────────────────

    /// @notice Client escrows the budget. Reverts unless the budget equals `expectedBudget` (front-running guard).
    function fund(uint256 jobId, uint256 expectedBudget, bytes calldata) external nonReentrant {
        Job storage j = _job(jobId);
        if (j.status != JobStatus.Open) revert WrongStatus();
        if (msg.sender != j.client) revert Unauthorized();
        if (j.provider == address(0)) revert ProviderNotSet();
        if (j.budget == 0) revert ZeroBudget();
        if (j.budget != expectedBudget) revert BudgetMismatch();
        if (block.timestamp >= j.expiredAt) revert Expired_();
        j.status = JobStatus.Funded;
        totalEscrowed += j.budget;
        uint256 before = paymentToken.balanceOf(address(this));
        paymentToken.safeTransferFrom(msg.sender, address(this), j.budget);
        if (paymentToken.balanceOf(address(this)) - before != j.budget) revert FeeOnTransferToken();
        emit JobFunded(jobId, msg.sender, j.budget);
    }

    // ───────────────────────── deliver ─────────────────────────

    function submit(uint256 jobId, bytes32 deliverable, bytes calldata) external nonReentrant {
        _submit(jobId, deliverable);
    }

    /// @notice submit plus a link (https or ipfs) to the work, emitted next to the hash.
    function submitWithUri(uint256 jobId, bytes32 deliverable, string calldata uri) external nonReentrant {
        if (bytes(uri).length > MAX_URI_BYTES) revert TooLong();
        _submit(jobId, deliverable);
        emit DeliverableUri(jobId, uri);
    }

    function _submit(uint256 jobId, bytes32 deliverable) internal {
        Job storage j = _job(jobId);
        if (j.status != JobStatus.Funded) revert WrongStatus();
        if (msg.sender != j.provider) revert Unauthorized();
        if (block.timestamp >= j.expiredAt) revert Expired_();
        j.status = JobStatus.Submitted;
        j.submittedAt = uint48(block.timestamp);
        emit JobSubmitted(jobId, msg.sender, deliverable);
    }

    // ───────────────────────── decide ─────────────────────────

    /// @notice Evaluator approves the submitted work: the provider is paid, minus the platform fee.
    function complete(uint256 jobId, bytes32 reason, bytes calldata) external nonReentrant {
        Job storage j = _job(jobId);
        if (j.status != JobStatus.Submitted) revert WrongStatus();
        if (msg.sender != j.evaluator) revert Unauthorized();
        _pay(jobId, j);
        emit JobCompleted(jobId, msg.sender, reason);
    }

    /// @notice After the review window, anyone may settle a submitted job the evaluator left unanswered: the provider is paid.
    function settle(uint256 jobId) external nonReentrant {
        Job storage j = _job(jobId);
        if (j.status != JobStatus.Submitted) revert WrongStatus();
        if (block.timestamp < uint256(j.submittedAt) + j.reviewSeconds) revert ReviewWindowOpen();
        _pay(jobId, j);
        emit JobSettled(jobId, msg.sender);
        emit JobCompleted(jobId, j.evaluator, TIMEOUT_SETTLE);   // marked: the evaluator did not approve, the window ran out
    }

    /// @notice Client rejects while Open; evaluator rejects while Funded (full refund) or Submitted within the review window
    ///         (kill fee to the provider, the rest refunded to the client).
    function reject(uint256 jobId, bytes32 reason, bytes calldata) external nonReentrant {
        Job storage j = _job(jobId);
        JobStatus s = j.status;
        if (s == JobStatus.Open) {
            if (msg.sender != j.client) revert Unauthorized();
            j.status = JobStatus.Rejected;
        } else if (s == JobStatus.Funded) {
            if (msg.sender != j.evaluator) revert Unauthorized();
            // review 13 Oct: a client judging its own job could reject just before the work lands and skip the kill fee.
            // Such a client recovers its money with claimRefund at the deadline instead; a neutral evaluator may still reject.
            if (j.evaluator == j.client) revert ClientEvaluatorMustWait();
            j.status = JobStatus.Rejected;
            totalEscrowed -= j.budget;
            _send(j.client, j.budget);
            emit Refunded(jobId, j.client, j.budget);
        } else if (s == JobStatus.Submitted) {
            if (msg.sender != j.evaluator) revert Unauthorized();
            if (block.timestamp >= uint256(j.submittedAt) + j.reviewSeconds) revert ReviewWindowOver();
            j.status = JobStatus.Rejected;
            totalEscrowed -= j.budget;
            uint256 kill = (j.budget * j.killFeeBps) / 10_000;
            uint256 back = j.budget - kill;
            if (kill > 0) { _send(j.provider, kill); emit KillFeePaid(jobId, j.provider, kill); }
            if (back > 0) { _send(j.client, back); emit Refunded(jobId, j.client, back); }
        } else {
            revert WrongStatus();
        }
        emit JobRejected(jobId, msg.sender, reason);
    }

    /// @notice After the deadline, anyone may refund a job that was funded but never submitted.
    function claimRefund(uint256 jobId) external nonReentrant {
        Job storage j = _job(jobId);
        if (j.status != JobStatus.Funded) revert WrongStatus();
        if (block.timestamp < j.expiredAt) revert NotExpiredYet();
        j.status = JobStatus.Expired;
        totalEscrowed -= j.budget;
        _send(j.client, j.budget);
        emit Refunded(jobId, j.client, j.budget);
        emit JobExpired(jobId);
    }

    /// @notice Withdraw a payout the token refused to deliver earlier.
    function withdraw() external nonReentrant {
        uint256 amount = credits[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        credits[msg.sender] = 0;
        totalCredits -= amount;
        paymentToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ───────────────────────── internal ─────────────────────────

    function _pay(uint256 jobId, Job storage j) internal {
        j.status = JobStatus.Completed;
        totalEscrowed -= j.budget;
        uint256 fee = (j.budget * platformFeeBP) / 10_000;
        uint256 net = j.budget - fee;
        if (fee > 0) { _send(feeRecipient, fee); emit PlatformFeePaid(jobId, feeRecipient, fee); }
        _send(j.provider, net);
        emit PaymentReleased(jobId, j.provider, net);
    }

    /// @dev Push the payout; if the token refuses (reverts or returns false), credit it for a later withdraw instead.
    function _send(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, bytes memory ret) = address(paymentToken).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (ok && (ret.length == 0 || abi.decode(ret, (bool)))) return;
        credits[to] += amount;
        totalCredits += amount;
        emit Credited(to, amount);
    }

    function _job(uint256 jobId) internal view returns (Job storage j) {
        j = _jobs[jobId];
        if (j.client == address(0)) revert InvalidJob();
    }

    // ───────────────────────── views ─────────────────────────

    /// @notice A job in the ERC-8183 reference layout, so 8183 tools decode it unchanged. Our extra terms: getTerms().
    struct Job8183 {
        uint256 id;
        address client;
        address provider;
        address evaluator;
        string description;
        uint256 budget;
        uint256 expiredAt;
        JobStatus status;
        address hook;
    }

    function getJob(uint256 jobId) public view returns (Job8183 memory) {
        Job storage j = _jobs[jobId];
        if (j.client == address(0)) return Job8183(0, address(0), address(0), address(0), "", 0, 0, JobStatus.Open, address(0));
        return Job8183(jobId, j.client, j.provider, j.evaluator, j.description, j.budget, j.expiredAt, j.status, address(0));
    }

    /// @notice ERC-8183 reference getter (the reference contract exposes `jobs` as a public mapping).
    function jobs(uint256 jobId) external view returns (uint256 id, address client, address provider, address evaluator, string memory description,
        uint256 budget, uint256 expiredAt, JobStatus status, address hook)
    {
        Job8183 memory j = getJob(jobId);
        return (j.id, j.client, j.provider, j.evaluator, j.description, j.budget, j.expiredAt, j.status, j.hook);
    }

    /// @notice G2 Jobs' own terms of a job: review window, kill fee and when it was submitted (0 if not yet).
    function getTerms(uint256 jobId) external view returns (uint32 reviewSeconds, uint16 killFeeBps, uint256 submittedAt) {
        Job storage j = _jobs[jobId];
        return (j.reviewSeconds, j.killFeeBps, j.submittedAt);
    }

    /// @notice ERC-8183 reference names: the fee recipient, and the evaluator fee (none here).
    function platformTreasury() external view returns (address) { return feeRecipient; }
    function evaluatorFeeBP() external pure returns (uint256) { return 0; }

    /// @notice When a submitted job can be settled by anyone (0 if not submitted).
    function settleableAt(uint256 jobId) external view returns (uint256) {
        Job storage j = _jobs[jobId];
        return j.status == JobStatus.Submitted ? uint256(j.submittedAt) + j.reviewSeconds : 0;
    }
}
