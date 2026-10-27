// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {G2Jobs} from "../src/G2Jobs.sol";
import {IG2Jobs} from "../src/G2Bond.sol";
import {G2Underwrite4} from "../src/G2Underwrite4.sol";

contract U4USDC is ERC20 {
    mapping(address => bool) public blacklisted;
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 a) external { _mint(to, a); }
    function setBlacklist(address a, bool b) external { blacklisted[a] = b; }
    function _update(address from, address to, uint256 v) internal override {
        require(!blacklisted[from] && !blacklisted[to], "blacklisted");
        super._update(from, to, v);
    }
}
contract U4FeeTok is ERC20 {
    constructor() ERC20("Fee", "FEE") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
    function _update(address from, address to, uint256 v) internal override {
        if (from != address(0) && to != address(0)) { super._update(from, address(0xdead), v / 100); v -= v / 100; }
        super._update(from, to, v);
    }
}

contract G2Underwrite4Test is Test {
    U4USDC usdc; G2Jobs g; G2Underwrite4 u;
    address CLIENT = address(0xC1); address AGENT = address(0xA6); address EVAL = address(0xE7); address PUPPET = address(0xBAD); address PEVAL = address(0xBAE);
    address UW1 = address(0x01); address UW2 = address(0x02); address SINK = address(0x5111);

    function setUp() public {
        usdc = new U4USDC();
        g = new G2Jobs(address(usdc), 0, address(0xFEE));
        u = new G2Underwrite4(IG2Jobs(address(g)), SINK);
        address[5] memory who = [CLIENT, AGENT, UW1, UW2, PUPPET];
        for (uint256 i; i < 5; i++) {
            usdc.mint(who[i], 10_000e6);
            vm.prank(who[i]); usdc.approve(address(u), type(uint256).max);
            vm.prank(who[i]); usdc.approve(address(g), type(uint256).max);
        }
        vm.prank(AGENT); u.setPremium(100);
    }
    function _jobBy(address client, address evaluator, uint256 budget, uint256 life) internal returns (uint256 id) {
        vm.prank(client); id = g.createJob(AGENT, evaluator, vm.getBlockTimestamp() + life, "work", address(0));
        vm.prank(client); g.setBudget(id, budget, "");
        vm.prank(client); g.fund(id, budget, "");
    }
    function _job(uint256 budget, uint256 life) internal returns (uint256) { return _jobBy(CLIENT, EVAL, budget, life); }
    function _uw(address who, uint256 amt) internal { vm.prank(who); u.underwrite(AGENT, amt); }
    function _val(address who) internal view returns (uint256) { return u.valueOf(AGENT, u.sharesOf(AGENT, who)); }
    function _exitAll(address who) internal { uint256 s = u.sharesOf(AGENT, who); vm.prank(who); u.requestWithdraw(AGENT, s); }
    function _warp(uint256 d) internal { vm.warp(vm.getBlockTimestamp() + d); }

    // ───────── v3 review H1 regressions: no squeeze through utilisation ─────────
    function test_H1_utilisationSqueezeNoLongerPays() public {
        _uw(AGENT, 40e6); _uw(UW1, 60e6);
        uint256 id = _jobBy(PUPPET, PEVAL, 50e6, 7 days);          // puppet job at the 50% cap
        vm.prank(AGENT); u.cover(id, 50e6);
        uint256 fair = _val(UW1);
        _exitAll(UW1);
        vm.prank(PEVAL); g.reject(id, "free release", ""); u.resolve(id);
        _warp(15 days + 1);                                           // max expiry + GRACE
        vm.prank(UW1); u.withdraw(AGENT);
        assertApproxEqAbs(usdc.balanceOf(UW1) - (10_000e6 - 60e6), fair, 2);   // full value, not the free share
    }
    function test_H1_coverAfterRequestCannotUseLeavingMoney() public {
        _uw(AGENT, 40e6); _uw(UW1, 60e6);
        _exitAll(UW1);                                               // 60 reserved
        uint256 id = _jobBy(PUPPET, PEVAL, 50e6, 7 days);
        vm.prank(AGENT); vm.expectRevert(G2Underwrite4.OverUtilised.selector); u.cover(id, 50e6);
        uint256 small = _jobBy(PUPPET, PEVAL, 20e6, 7 days);         // (100-60)*50% = 20 is all that is left
        vm.prank(AGENT); u.cover(small, 20e6);
        _warp(3 days);
        vm.prank(UW1); u.withdraw(AGENT);                            // paid in full while the cover is still open
        assertApproxEqAbs(usdc.balanceOf(UW1), 10_000e6, 2);
    }
    function test_H1_honestLeaverGetsFullShare() public {
        _uw(AGENT, 50e6); _uw(UW1, 50e6); uint256 id = _job(50e6, 1 days);
        vm.prank(AGENT); u.cover(id, 50e6);
        uint256 fair = _val(UW1);
        _exitAll(UW1);
        vm.prank(AGENT); g.submit(id, keccak256("x"), ""); vm.prank(EVAL); g.complete(id, "ok", ""); u.resolve(id);
        _warp(9 days + 1);
        vm.prank(UW1); u.withdraw(AGENT);
        assertApproxEqAbs(usdc.balanceOf(UW1) - (10_000e6 - 50e6), fair, 2);
    }
    // ───────── M2 stays closed: a leaver still bears a slash that was coming ─────────
    function test_M2_leaverBearsCertainSlash() public {
        _uw(AGENT, 50e6); _uw(UW1, 100e6); _uw(UW2, 100e6);
        uint256 id = _job(100e6, 1 days);
        vm.prank(AGENT); u.cover(id, 100e6);
        _exitAll(UW1);
        _warp(1 days);
        vm.prank(UW1); vm.expectRevert(G2Underwrite4.StillLocked.selector); u.withdraw(AGENT);
        u.resolve(id);                                               // 100: agent 50 first, then 50 pro rata
        _warp(9 days);
        vm.prank(UW1); u.withdraw(AGENT);
        uint256 got = usdc.balanceOf(UW1) - (10_000e6 - 100e6);
        assertApproxEqAbs(got, _val(UW2), 3);                        // same loss as the stayer
        assertLt(got, 100e6);
    }
    function test_missPendingBlocksExit() public {
        _uw(AGENT, 50e6); _uw(UW1, 50e6); uint256 id = _job(20e6, 1 days);
        vm.prank(AGENT); u.cover(id, 20e6);
        _exitAll(UW1);
        _warp(1 days); u.markMissed(id);
        _warp(8 days + 1);
        vm.prank(UW1); vm.expectRevert(G2Underwrite4.MissPending.selector); u.withdraw(AGENT);
        u.resolve(id);
        vm.prank(UW1); u.withdraw(AGENT);
    }
    // ───────── C1 stays closed ─────────
    function test_C1_puppetDrainIsALoss() public {
        _uw(AGENT, 50e6); _uw(UW1, 100e6); _uw(UW2, 100e6);
        uint256 start = usdc.balanceOf(AGENT) + usdc.balanceOf(PUPPET);
        uint256 id = _jobBy(PUPPET, PEVAL, 100e6, 20 minutes);
        vm.prank(AGENT); u.cover(id, 100e6);
        _warp(20 minutes); u.resolve(id); g.claimRefund(id);
        assertLt(usdc.balanceOf(AGENT) + usdc.balanceOf(PUPPET), start);   // agent side lost (premium; stake still in pool but burned)
        assertEq(u.sharesOf(AGENT, AGENT), 0);
        assertEq(usdc.balanceOf(SINK), 100e6);
    }
    // ───────── limits ─────────
    function test_caps() public {
        _uw(UW1, 100e6);
        vm.prank(UW1); vm.expectRevert(G2Underwrite4.UnderwriterCapReached.selector); u.underwrite(AGENT, 1);
        _uw(AGENT, 900e6);
        vm.prank(UW2); vm.expectRevert(G2Underwrite4.PoolCapReached.selector); u.underwrite(AGENT, 1);
    }
    function test_minPremiumAndHorizonAndUtil() public {
        vm.prank(AGENT); vm.expectRevert(G2Underwrite4.BadPremium.selector); u.setPremium(99);
        _uw(AGENT, 100e6);
        uint256 far = _job(10e6, 8 days);
        vm.prank(AGENT); vm.expectRevert(G2Underwrite4.TooFarAhead.selector); u.cover(far, 10e6);
        uint256 big = _job(51e6, 1 days);
        vm.prank(AGENT); vm.expectRevert(G2Underwrite4.OverUtilised.selector); u.cover(big, 51e6);
        uint256 ok = _job(50e6, 1 days);
        vm.prank(AGENT); u.cover(ok, 50e6);
    }
    function test_noPremiumSetNoCover() public {
        G2Underwrite4 u2 = new G2Underwrite4(IG2Jobs(address(g)), SINK);
        vm.prank(AGENT); usdc.approve(address(u2), type(uint256).max);
        vm.prank(AGENT); u2.underwrite(AGENT, 50e6);
        uint256 id = _job(10e6, 1 days);
        vm.prank(AGENT); vm.expectRevert(G2Underwrite4.BadPremium.selector); u2.cover(id, 10e6);
    }
    function test_leverageCap() public {
        _uw(AGENT, 20e6); _uw(UW1, 100e6);
        uint256 id = _job(41e6, 1 days);
        vm.prank(AGENT); vm.expectRevert(G2Underwrite4.OverLeverage.selector); u.cover(id, 41e6);
        uint256 id2 = _job(40e6, 1 days);
        vm.prank(AGENT); u.cover(id2, 40e6);
    }
    // ───────── exits ─────────
    function test_onePendingExitAndExpireReleasesReservation() public {
        _uw(AGENT, 50e6); _uw(UW1, 50e6);
        _exitAll(UW1);
        vm.prank(UW1); vm.expectRevert(G2Underwrite4.ExitPending.selector); u.requestWithdraw(AGENT, 1);
        vm.expectRevert(G2Underwrite4.NotExpiredYet.selector); u.expireExit(AGENT, UW1);
        _warp(5 days + 1);
        vm.prank(UW1); vm.expectRevert(G2Underwrite4.NoticeExpired.selector); u.withdraw(AGENT);
        u.expireExit(AGENT, UW1);                                    // anyone
        uint256 id = _job(50e6, 1 days);
        vm.prank(AGENT); u.cover(id, 50e6);                          // capacity is back
    }
    function test_cancelReleasesReservation() public {
        _uw(AGENT, 50e6); _uw(UW1, 50e6);
        _exitAll(UW1);
        vm.prank(UW1); u.cancelWithdraw(AGENT);
        uint256 id = _job(50e6, 1 days);
        vm.prank(AGENT); u.cover(id, 50e6);
    }
    function test_noticeNeedsSharesAndOnlyOwn() public {
        vm.prank(UW2); vm.expectRevert(G2Underwrite4.NotEnoughShares.selector); u.requestWithdraw(AGENT, 1);
        _uw(UW1, 20e6); _exitAll(UW1);
        _warp(3 days);
        vm.prank(UW2); vm.expectRevert(G2Underwrite4.NoWithdrawRequested.selector); u.withdraw(AGENT);
        vm.prank(UW1); u.withdraw(AGENT);
        assertApproxEqAbs(usdc.balanceOf(UW1), 10_000e6, 2);
    }
    function test_agentCannotExitWithOpenCovers() public {
        _uw(AGENT, 50e6); _exitAll(AGENT);
        uint256 id = _job(10e6, 1 days);                              // (50-50)*50% = 0: own pending exit is reserved too
        vm.prank(AGENT); vm.expectRevert(G2Underwrite4.OverUtilised.selector); u.cover(id, 10e6);
        vm.prank(AGENT); u.cancelWithdraw(AGENT);
        vm.prank(AGENT); u.cover(id, 10e6);
        _exitAll(AGENT); _warp(9 days);
        vm.prank(AGENT); vm.expectRevert(G2Underwrite4.AgentHasOpenCovers.selector); u.withdraw(AGENT);
    }
    function test_premiumIsYield() public {
        vm.prank(AGENT); u.setPremium(1000);
        _uw(AGENT, 50e6); _uw(UW1, 50e6); uint256 id = _job(40e6, 1 days);
        vm.prank(AGENT); u.cover(id, 40e6);
        vm.prank(AGENT); g.submit(id, keccak256("x"), ""); vm.prank(EVAL); g.complete(id, "ok", ""); u.resolve(id);
        assertApproxEqAbs(_val(UW1), 52e6, 3);
    }
    // ───────── carried over ─────────
    function test_onlyFundedExactBudgetTimeProviderNoSelf() public {
        _uw(AGENT, 50e6);
        vm.prank(CLIENT); uint256 open = g.createJob(AGENT, EVAL, vm.getBlockTimestamp() + 1 days, "w", address(0));
        vm.prank(CLIENT); g.setBudget(open, 10e6, "");
        vm.prank(AGENT); vm.expectRevert(G2Underwrite4.JobNotCoverable.selector); u.cover(open, 10e6);
        uint256 id = _job(10e6, 1 days);
        vm.prank(AGENT); vm.expectRevert(G2Underwrite4.BudgetMismatch.selector); u.cover(id, 10e6 + 1);
        vm.prank(UW1); vm.expectRevert(G2Underwrite4.NotProvider.selector); u.cover(id, 10e6);
        uint256 late = _job(10e6, 10 minutes);
        vm.prank(AGENT); vm.expectRevert(G2Underwrite4.TooLittleTime.selector); u.cover(late, 10e6);
        vm.prank(AGENT); uint256 self = g.createJob(AGENT, EVAL, vm.getBlockTimestamp() + 1 days, "s", address(0));
        vm.prank(AGENT); g.setBudget(self, 1e6, ""); vm.prank(AGENT); g.fund(self, 1e6, "");
        vm.prank(AGENT); vm.expectRevert(G2Underwrite4.SelfDealing.selector); u.cover(self, 1e6);
    }
    function test_frozenMissSurvivesLateRejectAndDoubleResolve() public {
        _uw(AGENT, 50e6); uint256 id = _job(10e6, 1 days);
        vm.prank(AGENT); u.cover(id, 10e6);
        vm.expectRevert(G2Underwrite4.NotFinal.selector); u.resolve(id);
        _warp(1 days); u.markMissed(id);
        vm.prank(EVAL); g.reject(id, "late", "");
        u.resolve(id); assertEq(usdc.balanceOf(SINK), 10e6);
        vm.expectRevert(G2Underwrite4.NotCovered.selector); u.resolve(id);
    }
    function test_retryCreditToSink() public {
        _uw(AGENT, 50e6); uint256 id = _job(10e6, 1 days);
        vm.prank(AGENT); u.cover(id, 10e6);
        _warp(1 days); usdc.setBlacklist(SINK, true);
        u.resolve(id); assertEq(u.credits(SINK), 10e6);
        usdc.setBlacklist(SINK, false);
        u.retryCredit(SINK);                                          // anyone
        assertEq(usdc.balanceOf(SINK), 10e6); assertEq(u.credits(SINK), 0);
    }
    function test_dustRestart() public {
        _uw(AGENT, 4000);
        vm.prank(AGENT); u.setPremium(100);
        uint256 id = _job(2000, 1 days);                              // 50% of 4000
        vm.prank(AGENT); u.cover(id, 2000);
        _warp(1 days); u.resolve(id);
        (uint256 a,,,,,,,,,,,,,) = u.pools(AGENT);
        assertGt(a, 0);                                               // 2000 + premium left: above dust
    }
    function test_zeroSinkRejected() public {
        vm.expectRevert(G2Underwrite4.ZeroAddress.selector); new G2Underwrite4(IG2Jobs(address(g)), address(0));
    }
    function test_feeOnTransferRejected() public {
        U4FeeTok f = new U4FeeTok(); G2Jobs g2 = new G2Jobs(address(f), 0, address(0xFEE));
        G2Underwrite4 u2 = new G2Underwrite4(IG2Jobs(address(g2)), SINK);
        f.mint(UW1, 100e6); vm.prank(UW1); f.approve(address(u2), type(uint256).max);
        vm.prank(UW1); vm.expectRevert(G2Underwrite4.FeeOnTransferToken.selector); u2.underwrite(AGENT, 10e6);
    }
    function testFuzz_accounting(uint96 a0, uint96 a1, uint96 a2, uint8 outcome) public {
        uint256 own = bound(uint256(a0), 5e6, 500e6); uint256 x = bound(uint256(a1), 1e6, 100e6); uint256 y = bound(uint256(a2), 1e6, 100e6);
        _uw(AGENT, own); _uw(UW1, x); _uw(UW2, y);
        uint256 budget = u.capacity(AGENT);
        if (budget > 50e6) budget = 50e6;
        if (budget < 1e6) return;
        uint256 id = _job(budget, 1 days);
        vm.prank(AGENT); u.cover(id, budget);
        _exitAll(UW2);                                                // settles at deadline + GRACE
        uint8 o = outcome % 3;
        if (o == 0) { _warp(1 days); }
        else if (o == 1) { vm.prank(AGENT); g.submit(id, keccak256("x"), ""); vm.prank(EVAL); g.complete(id, "ok", ""); }
        else { _warp(1 days); usdc.setBlacklist(SINK, true); }
        u.resolve(id);
        _warp(9 days + 1);
        vm.prank(UW2); u.withdraw(AGENT);
        assertEq(usdc.balanceOf(address(u)), u.totalAssets() + u.totalCredits());
        assertLe(_val(UW1) + u.ownStake(AGENT), u.totalAssets());
    }
}
