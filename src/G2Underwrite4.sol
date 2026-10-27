// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IG2Jobs} from "./G2Bond.sol";

/// @title G2Underwrite4
/// @notice Agents underwrite agents, v4. APEX Faucet, 28 Oct 2026. v3 plus the fix of its review (H1) and the limits it asked for:
///         exits are paid at FULL value (min of the value at request and now), only after every cover open at request time could
///         have resolved; the value of pending exits is reserved from capacity; 7-day horizon, 50% utilisation, minimum premium,
///         pool and per-underwriter caps; anyone can retry a credit stuck at the sink.
/// @dev Every agent has a pool; anyone deposits USDC for shares. The agent covers FUNDED G2Jobs it was hired for and pays a premium
///      into the pool (the underwriters' yield). On a chain-proven miss (funded, not submitted by the deadline) the reserved amount
///      leaves the pool to an immutable SINK (the People Pot), never to the client, who is already refunded by G2Jobs: so nobody,
///      the agent's own puppet wallets included, can profit from a failure (v2 review C1). The AGENT'S OWN shares are burned first;
///      underwriters lose only beyond them, and an agent can never commit more than LEVERAGE x its own stake nor more than
///      MAX_UTIL_BPS of the pool. Covers run at most MAX_HORIZON ahead (M3). Exits lock the shares asked for, open after
///      WITHDRAW_DELAY for a WINDOW only (M1), and pay the smaller of the value at request and now at FULL value, only after every cover open at
///      request time could have resolved (v3 review H1; this also keeps M2 closed).
///      A pool emptied to dust starts a new share epoch (L2); share math uses mulDiv. No owner, no upgrade, no fee.
contract G2Underwrite4 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum CoverState { None, Open, Released, Slashed }

    struct Pool {
        uint256 assets;
        uint256 committed;
        uint256 totalShares;
        uint64 epoch;
        uint16 premiumBps;
        uint32 covers;
        uint32 openCovers;
        uint32 slashes;
        uint32 distinctClients;   // sybil-able (a client can be any fresh wallet): context, not reputation
        uint256 premiumsPaid;
        uint256 slashedTotal;
        uint256 pendingExitValue;  // value promised to pending exits: never re-committed to covers
        uint64 maxExpiry;          // latest deadline of any cover ever opened in this epoch (only grows)
        uint32 pendingMisses;      // frozen misses not yet resolved: exits wait for them
    }

    struct Cover { address agent; address client; uint256 amount; uint48 expiredAt; bool missed; CoverState state; }
    struct Exit { uint256 shares; uint256 valueAtRequest; uint64 unlockAt; uint64 epoch; }   // unlockAt = settle time

    uint256 public constant WITHDRAW_DELAY = 3 days;
    uint256 public constant WINDOW = 2 days;
    uint256 public constant MIN_WORK_WINDOW = 15 minutes;
    uint256 public constant MAX_HORIZON = 7 days;
    uint256 public constant GRACE = 8 days;          // > G2Jobs MAX_REVIEW (7 d): every cover open at request is final by then
    uint256 public constant LEVERAGE = 2;
    uint256 public constant MAX_UTIL_BPS = 5000;
    uint16 public constant MIN_PREMIUM_BPS = 100;
    uint256 public constant POOL_CAP = 1_000e6;
    uint256 public constant UNDERWRITER_CAP = 100e6;
    uint16 public constant MAX_PREMIUM_BPS = 2000;
    uint256 public constant DUST = 1000;          // 0.001 USDC: below this after a slash the pool restarts (new share epoch)
    uint256 internal constant OFFSET = 1e6;

    IERC20 public immutable token;
    IG2Jobs public immutable jobs;
    address public immutable sink;

    mapping(address => Pool) public pools;
    mapping(address => mapping(address => uint256)) internal _shares;
    mapping(address => mapping(address => uint64)) internal _epochOf;
    mapping(address => mapping(address => Exit)) public exits;
    mapping(address => mapping(address => bool)) internal _clientSeen;
    mapping(uint256 => Cover) public covers;
    mapping(address => uint256) public credits;
    uint256 public totalAssets;
    uint256 public totalCredits;

    event PremiumSet(address indexed agent, uint16 premiumBps);
    event Underwritten(address indexed agent, address indexed underwriter, uint256 amount, uint256 sharesMinted);
    event Covered(uint256 indexed jobId, address indexed agent, address indexed client, uint256 amount, uint256 premium);
    event MissedMarked(uint256 indexed jobId, address indexed agent);
    event Released(uint256 indexed jobId, address indexed agent, uint256 amount);
    event Slashed(uint256 indexed jobId, address indexed agent, uint256 amount, uint256 fromAgentStake);
    event NewEpoch(address indexed agent, uint64 epoch, uint256 dustToSink);
    event WithdrawRequested(address indexed agent, address indexed underwriter, uint256 shares, uint256 valueAtRequest, uint64 unlockAt);
    event WithdrawCancelled(address indexed agent, address indexed underwriter);
    event Withdrawn(address indexed agent, address indexed underwriter, uint256 sharesBurned, uint256 amount);
    event Credited(address indexed account, uint256 amount);
    event CreditWithdrawn(address indexed account, uint256 amount);

    error ZeroAmount();
    error ZeroAddress();
    error FeeOnTransferToken();
    error BadPremium();
    error NotProvider();
    error SelfDealing();
    error JobNotCoverable();
    error BudgetMismatch();
    error TooLittleTime();
    error TooFarAhead();
    error AlreadyCovered();
    error OverLeverage();
    error OverUtilised();
    error NotCovered();
    error NotMissed();
    error NotFinal();
    error NotEnoughShares();
    error NoWithdrawRequested();
    error StillLocked();
    error NoticeExpired();
    error AgentHasOpenCovers();
    error PoolCapReached();
    error UnderwriterCapReached();
    error ExitPending();
    error MissPending();
    error NotEnoughFreeAssets();
    error NotExpiredYet();
    error NothingToWithdraw();

    constructor(IG2Jobs jobs_, address sink_) {
        if (sink_ == address(0)) revert ZeroAddress();
        jobs = jobs_;
        token = jobs_.paymentToken();
        sink = sink_;
    }

    // ───────────────────────── views ─────────────────────────

    function sharesOf(address agent, address who) public view returns (uint256) {
        return _epochOf[agent][who] == pools[agent].epoch ? _shares[agent][who] : 0;
    }

    function valueOf(address agent, uint256 shareAmount) public view returns (uint256) {
        Pool storage p = pools[agent];
        return Math.mulDiv(shareAmount, p.assets + 1, p.totalShares + OFFSET);
    }

    /// @notice What `shareAmount` would pay on exit right now: its share of the FREE assets only.

    function ownStake(address agent) public view returns (uint256) {
        return valueOf(agent, sharesOf(agent, agent));
    }

    function freeAssets(address agent) external view returns (uint256) {
        Pool storage p = pools[agent];
        return p.assets - p.committed;
    }

    /// @notice The largest budget this agent can cover right now.
    function capacity(address agent) public view returns (uint256) {
        Pool storage p = pools[agent];
        uint256 byLev = LEVERAGE * ownStake(agent);
        uint256 base = p.assets > p.pendingExitValue ? p.assets - p.pendingExitValue : 0;
        uint256 byUtil = (base * MAX_UTIL_BPS) / 10_000;
        uint256 cap = byLev < byUtil ? byLev : byUtil;
        return cap > p.committed ? cap - p.committed : 0;
    }

    // ───────────────────────── pool ─────────────────────────

    function setPremium(uint16 premiumBps) external {
        if (premiumBps > MAX_PREMIUM_BPS || premiumBps < MIN_PREMIUM_BPS) revert BadPremium();
        pools[msg.sender].premiumBps = premiumBps;
        emit PremiumSet(msg.sender, premiumBps);
    }

    function underwrite(address agent, uint256 amount) external nonReentrant returns (uint256 minted) {
        if (amount == 0 || agent == address(0)) revert ZeroAmount();
        Pool storage p = pools[agent];
        _sync(agent, msg.sender);
        if (p.assets + amount > POOL_CAP) revert PoolCapReached();
        if (msg.sender != agent && valueOf(agent, _shares[agent][msg.sender]) + amount > UNDERWRITER_CAP) revert UnderwriterCapReached();
        minted = Math.mulDiv(amount, p.totalShares + OFFSET, p.assets + 1);
        if (minted == 0) revert ZeroAmount();
        _pull(msg.sender, amount);
        p.assets += amount;
        p.totalShares += minted;
        _shares[agent][msg.sender] += minted;
        totalAssets += amount;
        emit Underwritten(agent, msg.sender, amount, minted);
    }

    // ───────────────────────── cover ─────────────────────────

    function cover(uint256 jobId, uint256 expectedBudget) external nonReentrant {
        IG2Jobs.Job8183 memory j = jobs.getJob(jobId);
        if (j.provider != msg.sender || msg.sender == address(0)) revert NotProvider();
        if (j.client == msg.sender) revert SelfDealing();
        if (j.status != IG2Jobs.JobStatus.Funded) revert JobNotCoverable();
        if (j.budget != expectedBudget || j.budget == 0) revert BudgetMismatch();
        if (j.expiredAt < block.timestamp + MIN_WORK_WINDOW) revert TooLittleTime();
        if (j.expiredAt > block.timestamp + MAX_HORIZON) revert TooFarAhead();
        if (covers[jobId].state != CoverState.None) revert AlreadyCovered();
        Pool storage p = pools[msg.sender];
        if (p.premiumBps < MIN_PREMIUM_BPS) revert BadPremium();
        if (p.committed + j.budget > LEVERAGE * ownStake(msg.sender)) revert OverLeverage();
        uint256 base = p.assets > p.pendingExitValue ? p.assets - p.pendingExitValue : 0;
        if ((p.committed + j.budget) * 10_000 > base * MAX_UTIL_BPS) revert OverUtilised();
        uint256 premium = (j.budget * p.premiumBps) / 10_000;
        if (premium > 0) { _pull(msg.sender, premium); p.assets += premium; p.premiumsPaid += premium; totalAssets += premium; }
        p.committed += j.budget;
        p.covers += 1;
        p.openCovers += 1;
        if (!_clientSeen[msg.sender][j.client]) { _clientSeen[msg.sender][j.client] = true; p.distinctClients += 1; }
        if (uint64(j.expiredAt) > p.maxExpiry) p.maxExpiry = uint64(j.expiredAt);
        covers[jobId] = Cover(msg.sender, j.client, j.budget, uint48(j.expiredAt), false, CoverState.Open);
        emit Covered(jobId, msg.sender, j.client, j.budget, premium);
    }

    function markMissed(uint256 jobId) external {
        Cover storage c = covers[jobId];
        if (c.state != CoverState.Open) revert NotCovered();
        IG2Jobs.Job8183 memory j = jobs.getJob(jobId);
        if (block.timestamp < c.expiredAt || j.status != IG2Jobs.JobStatus.Funded) revert NotMissed();
        if (!c.missed) pools[c.agent].pendingMisses += 1;
        c.missed = true;
        emit MissedMarked(jobId, c.agent);
    }

    function resolve(uint256 jobId) external nonReentrant {
        Cover storage c = covers[jobId];
        if (c.state != CoverState.Open) revert NotCovered();
        IG2Jobs.Job8183 memory j = jobs.getJob(jobId);
        Pool storage p = pools[c.agent];
        bool past = block.timestamp >= c.expiredAt;
        if (c.missed || j.status == IG2Jobs.JobStatus.Expired || (j.status == IG2Jobs.JobStatus.Funded && past)) {
            c.state = CoverState.Slashed;
            if (c.missed) p.pendingMisses -= 1;
            p.committed -= c.amount;
            p.openCovers -= 1;
            p.slashes += 1;
            uint256 amt = c.amount;
            // Agent first-loss: burn the agent's own shares worth `amt` (rounded up), or all of them if they are worth less.
            uint256 own = sharesOf(c.agent, c.agent);
            uint256 burn = Math.mulDiv(amt, p.totalShares + OFFSET, p.assets + 1, Math.Rounding.Ceil);
            uint256 fromAgent = amt;
            if (burn > own) { burn = own; fromAgent = valueOf(c.agent, own); }
            _shares[c.agent][c.agent] -= burn;
            p.totalShares -= burn;
            p.assets -= amt;
            p.slashedTotal += amt;
            totalAssets -= amt;
            _send(sink, amt);
            emit Slashed(jobId, c.agent, amt, fromAgent);
            if (p.assets < DUST && p.committed == 0) _restart(c.agent);
        } else if (j.status == IG2Jobs.JobStatus.Completed || j.status == IG2Jobs.JobStatus.Rejected) {
            c.state = CoverState.Released;
            // (a released cover is never `missed`: a frozen miss always slashes above)
            p.committed -= c.amount;
            p.openCovers -= 1;
            emit Released(jobId, c.agent, c.amount);
        } else {
            revert NotFinal();
        }
    }

    // ───────────────────────── exit ─────────────────────────

    /// @notice Lock `shareAmount` of your shares for exit at their FULL value now (you still bear later slashes: you get
    ///         min(value at request, value at withdraw)). Payable after WITHDRAW_DELAY and after every cover opened so far
    ///         could have resolved (latest deadline + GRACE), for WINDOW. The value is reserved: it cannot be re-committed.
    function requestWithdraw(address agent, uint256 shareAmount) external {
        _sync(agent, msg.sender);
        Pool storage p = pools[agent];
        if (exits[agent][msg.sender].shares != 0 && exits[agent][msg.sender].epoch == p.epoch) revert ExitPending();
        if (shareAmount == 0) revert ZeroAmount();
        if (_shares[agent][msg.sender] < shareAmount) revert NotEnoughShares();
        uint256 v = valueOf(agent, shareAmount);
        uint256 t = block.timestamp + WITHDRAW_DELAY;
        if (p.maxExpiry != 0 && uint256(p.maxExpiry) + GRACE > t) t = uint256(p.maxExpiry) + GRACE;
        exits[agent][msg.sender] = Exit(shareAmount, v, uint64(t), p.epoch);
        p.pendingExitValue += v;
        emit WithdrawRequested(agent, msg.sender, shareAmount, v, uint64(t));
    }

    function cancelWithdraw(address agent) external {
        Exit memory e = exits[agent][msg.sender];
        if (e.shares == 0) revert NoWithdrawRequested();
        _dropExit(agent, msg.sender, e);
        emit WithdrawCancelled(agent, msg.sender);
    }

    /// @notice Anyone may clear an exit whose window passed, so its reservation does not block the pool forever.
    function expireExit(address agent, address who) external {
        Exit memory e = exits[agent][who];
        if (e.shares == 0) revert NoWithdrawRequested();
        if (e.epoch == pools[agent].epoch && block.timestamp < uint256(e.unlockAt) + WINDOW) revert NotExpiredYet();
        _dropExit(agent, who, e);
        emit WithdrawCancelled(agent, who);
    }

    function withdraw(address agent) external nonReentrant {
        Exit memory e = exits[agent][msg.sender];
        Pool storage p = pools[agent];
        if (e.shares == 0 || e.epoch != p.epoch) revert NoWithdrawRequested();
        if (block.timestamp < e.unlockAt) revert StillLocked();
        if (block.timestamp >= uint256(e.unlockAt) + WINDOW) revert NoticeExpired();
        if (p.pendingMisses > 0) revert MissPending();
        if (msg.sender == agent && p.openCovers > 0) revert AgentHasOpenCovers();
        _sync(agent, msg.sender);
        uint256 have = _shares[agent][msg.sender];
        uint256 sh = e.shares < have ? e.shares : have;
        if (sh == 0) revert NotEnoughShares();
        uint256 nowValue = valueOf(agent, sh);
        uint256 capV = Math.mulDiv(e.valueAtRequest, sh, e.shares);
        uint256 amount = nowValue < capV ? nowValue : capV;
        if (amount > p.assets - p.committed) revert NotEnoughFreeAssets();
        delete exits[agent][msg.sender];
        p.pendingExitValue -= e.valueAtRequest;
        _shares[agent][msg.sender] = have - sh;
        p.totalShares -= sh;
        p.assets -= amount;
        totalAssets -= amount;
        token.safeTransfer(msg.sender, amount);
        emit Withdrawn(agent, msg.sender, sh, amount);
    }

    /// @notice Anyone may retry a payout that was credited because the token refused it (e.g. the sink): review v3 L1.
    function retryCredit(address to) external nonReentrant {
        uint256 amount = credits[to];
        if (amount == 0) revert NothingToWithdraw();
        credits[to] = 0;
        totalCredits -= amount;
        token.safeTransfer(to, amount);
        emit CreditWithdrawn(to, amount);
    }

    function withdrawCredit() external nonReentrant {
        uint256 amount = credits[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        credits[msg.sender] = 0;
        totalCredits -= amount;
        token.safeTransfer(msg.sender, amount);
        emit CreditWithdrawn(msg.sender, amount);
    }

    // ───────────────────────── internal ─────────────────────────

    function _sync(address agent, address who) internal {
        uint64 e = pools[agent].epoch;
        if (_epochOf[agent][who] != e) { _epochOf[agent][who] = e; _shares[agent][who] = 0; }
    }

    function _dropExit(address agent, address who, Exit memory e) internal {
        if (e.epoch == pools[agent].epoch) pools[agent].pendingExitValue -= e.valueAtRequest;
        delete exits[agent][who];
    }

    function _restart(address agent) internal {
        Pool storage p = pools[agent];
        uint256 dust = p.assets;
        p.assets = 0;
        p.totalShares = 0;
        p.pendingExitValue = 0;
        p.maxExpiry = 0;
        p.epoch += 1;
        totalAssets -= dust;
        _send(sink, dust);
        emit NewEpoch(agent, p.epoch, dust);
    }

    function _pull(address from, uint256 amount) internal {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        if (token.balanceOf(address(this)) - before != amount) revert FeeOnTransferToken();
    }

    function _send(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (ok && (ret.length == 0 || abi.decode(ret, (bool)))) return;
        credits[to] += amount;
        totalCredits += amount;
        emit Credited(to, amount);
    }
}
