// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice The read-only part of G2Jobs this bond needs (ERC-8183 reference layout).
interface IG2Jobs {
    enum JobStatus { Open, Funded, Submitted, Completed, Rejected, Expired }
    struct Job8183 { uint256 id; address client; address provider; address evaluator; string description; uint256 budget; uint256 expiredAt; JobStatus status; address hook; }
    function getJob(uint256 jobId) external view returns (Job8183 memory);
    function paymentToken() external view returns (IERC20);
}

/// @title G2Bond
/// @notice Reputation as collateral for agents that sell work through G2Jobs. APEX Faucet, 27 Oct 2026.
/// @dev An agent locks USDC, then COVERS jobs it takes as provider: the job's budget is reserved from its free bond, so every
///      cover is fully backed. Slashing is mechanical and only on a fact the chain proves by itself: the client escrowed the money
///      and the agent never submitted before the deadline (G2Jobs status Expired, or still Funded past expiredAt). Then the
///      reserved amount (capped at the job's budget) goes to the job's client. Nothing subjective can slash: an evaluator's reject,
///      a quality dispute or a delivery-hash argument releases the reserve, it never takes it.
///      Only the provider itself can put a job under its bond (anyone can name anyone as provider in G2Jobs; without this a
///      stranger could drain a bond with jobs the agent never accepted). No owner, no upgrade, no fee. A payout the token
///      refuses (e.g. a USDC-blacklisted client) is credited for a later withdraw, so one bad address never blocks anything.
contract G2Bond is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum CoverState { None, Open, Released, Slashed }

    struct Agent {
        uint256 bonded;      // total locked by the agent (free + committed)
        uint256 committed;   // reserved for open covers
        uint64 unlockAt;     // 0 = no withdrawal pending; else the time the free bond can leave
        uint32 covers;       // jobs ever covered
        uint32 openCovers;   // covers not yet resolved
        uint32 slashes;      // covers slashed
    }

    struct Cover {
        address provider;
        address client;
        uint256 amount;
        CoverState state;
    }

    uint256 public constant WITHDRAW_DELAY = 3 days;

    IERC20 public immutable token;
    IG2Jobs public immutable jobs;

    mapping(address => Agent) public agents;
    mapping(uint256 => Cover) public covers;
    mapping(address => uint256) public credits;
    uint256 public totalBonded;
    uint256 public totalCredits;

    event Deposited(address indexed agent, uint256 amount);
    event Covered(uint256 indexed jobId, address indexed agent, address indexed client, uint256 amount);
    event Released(uint256 indexed jobId, address indexed agent, uint256 amount);
    event Slashed(uint256 indexed jobId, address indexed agent, address indexed client, uint256 amount);
    event WithdrawRequested(address indexed agent, uint256 unlockAt);
    event WithdrawCancelled(address indexed agent);
    event Withdrawn(address indexed agent, uint256 amount);
    event Credited(address indexed account, uint256 amount);
    event CreditWithdrawn(address indexed account, uint256 amount);

    error ZeroAmount();
    error FeeOnTransferToken();
    error NotProvider();
    error JobNotCoverable();
    error AlreadyCovered();
    error NotEnoughFreeBond();
    error WithdrawPending();
    error NotCovered();
    error NotFinal();
    error NoWithdrawRequested();
    error StillLocked();
    error NothingToWithdraw();

    constructor(IG2Jobs jobs_) {
        jobs = jobs_;
        token = jobs_.paymentToken();
    }

    // ───────────────────────── bond ─────────────────────────

    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) - before != amount) revert FeeOnTransferToken();
        agents[msg.sender].bonded += amount;
        totalBonded += amount;
        emit Deposited(msg.sender, amount);
    }

    /// @notice Put a job you are the provider of under your bond. Reserves the job's current budget from your free bond.
    function cover(uint256 jobId) external nonReentrant {
        IG2Jobs.Job8183 memory j = jobs.getJob(jobId);
        if (j.provider != msg.sender || j.provider == address(0)) revert NotProvider();
        if ((j.status != IG2Jobs.JobStatus.Open && j.status != IG2Jobs.JobStatus.Funded) || block.timestamp >= j.expiredAt || j.budget == 0) revert JobNotCoverable();
        if (covers[jobId].state != CoverState.None) revert AlreadyCovered();
        Agent storage a = agents[msg.sender];
        if (a.unlockAt != 0) revert WithdrawPending();
        if (a.bonded - a.committed < j.budget) revert NotEnoughFreeBond();
        a.committed += j.budget;
        a.covers += 1;
        a.openCovers += 1;
        covers[jobId] = Cover(msg.sender, j.client, j.budget, CoverState.Open);
        emit Covered(jobId, msg.sender, j.client, j.budget);
    }

    /// @notice Anyone may resolve a covered job once its outcome is final. Missed deadline after funding: slash to the client.
    ///         Completed, rejected, or never funded before the deadline: release the reserve.
    function resolve(uint256 jobId) external nonReentrant {
        Cover storage c = covers[jobId];
        if (c.state != CoverState.Open) revert NotCovered();
        IG2Jobs.Job8183 memory j = jobs.getJob(jobId);
        Agent storage a = agents[c.provider];
        bool past = block.timestamp >= j.expiredAt;
        if (j.status == IG2Jobs.JobStatus.Expired || (j.status == IG2Jobs.JobStatus.Funded && past)) {
            uint256 amt = c.amount < j.budget ? c.amount : j.budget;
            c.state = CoverState.Slashed;
            a.committed -= c.amount;
            a.openCovers -= 1;
            a.slashes += 1;
            a.bonded -= amt;
            totalBonded -= amt;
            _send(c.client, amt);
            emit Slashed(jobId, c.provider, c.client, amt);
        } else if (j.status == IG2Jobs.JobStatus.Completed || j.status == IG2Jobs.JobStatus.Rejected
                   || (j.status == IG2Jobs.JobStatus.Open && past)) {
            c.state = CoverState.Released;
            a.committed -= c.amount;
            a.openCovers -= 1;
            emit Released(jobId, c.provider, c.amount);
        } else {
            revert NotFinal();
        }
    }

    function requestWithdraw() external {
        uint64 t = uint64(block.timestamp + WITHDRAW_DELAY);
        agents[msg.sender].unlockAt = t;
        emit WithdrawRequested(msg.sender, t);
    }

    function cancelWithdraw() external {
        if (agents[msg.sender].unlockAt == 0) revert NoWithdrawRequested();
        agents[msg.sender].unlockAt = 0;
        emit WithdrawCancelled(msg.sender);
    }

    /// @notice Take out free bond (never the part reserved for open covers) after the notice period.
    function withdraw(uint256 amount) external nonReentrant {
        Agent storage a = agents[msg.sender];
        if (a.unlockAt == 0) revert NoWithdrawRequested();
        if (block.timestamp < a.unlockAt) revert StillLocked();
        if (amount == 0) revert ZeroAmount();
        if (a.bonded - a.committed < amount) revert NotEnoughFreeBond();
        a.bonded -= amount;
        totalBonded -= amount;
        token.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function withdrawCredit() external nonReentrant {
        uint256 amount = credits[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        credits[msg.sender] = 0;
        totalCredits -= amount;
        token.safeTransfer(msg.sender, amount);
        emit CreditWithdrawn(msg.sender, amount);
    }

    // ───────────────────────── views ─────────────────────────

    function freeBond(address agent) external view returns (uint256) {
        Agent storage a = agents[agent];
        return a.bonded - a.committed;
    }

    // ───────────────────────── internal ─────────────────────────

    function _send(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (ok && (ret.length == 0 || abi.decode(ret, (bool)))) return;
        credits[to] += amount;
        totalCredits += amount;
        emit Credited(to, amount);
    }
}
