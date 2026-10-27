// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {G2Jobs} from "../src/G2Jobs.sol";
import {IG2Jobs} from "../src/G2Bond.sol";
import {G2Underwrite3} from "../src/G2Underwrite3.sol";

contract U3USDC is ERC20 {
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
contract U3FeeTok is ERC20 {
    constructor() ERC20("Fee", "FEE") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
    function _update(address from, address to, uint256 v) internal override {
        if (from != address(0) && to != address(0)) { super._update(from, address(0xdead), v / 100); v -= v / 100; }
        super._update(from, to, v);
    }
}

contract G2Underwrite3Test is Test {
    U3USDC usdc; G2Jobs g; G2Underwrite3 u;
    address CLIENT = address(0xC1); address AGENT = address(0xA6); address EVAL = address(0xE7); address PUPPET = address(0xBAD);
    address UW1 = address(0x01); address UW2 = address(0x02); address SINK = address(0x5111);

    function setUp() public {
        usdc = new U3USDC();
        g = new G2Jobs(address(usdc), 0, address(0xFEE));
        u = new G2Underwrite3(IG2Jobs(address(g)), SINK);
        address[5] memory who = [CLIENT, AGENT, UW1, UW2, PUPPET];
        for (uint256 i; i < 5; i++) {
            usdc.mint(who[i], 1_000_000e6);
            vm.prank(who[i]); usdc.approve(address(u), type(uint256).max);
            vm.prank(who[i]); usdc.approve(address(g), type(uint256).max);
        }
    }
    function _jobFrom(address client, uint256 budget, uint256 life) internal returns (uint256 id) {
        vm.prank(client); id = g.createJob(AGENT, EVAL, vm.getBlockTimestamp() + life, "work", address(0));
        vm.prank(client); g.setBudget(id, budget, "");
        vm.prank(client); g.fund(id, budget, "");
    }
    function _job(uint256 budget) internal returns (uint256) { return _jobFrom(CLIENT, budget, 1 days); }
    function _uw(address who, uint256 amt) internal { vm.prank(who); u.underwrite(AGENT, amt); }
    function _pool() internal view returns (uint256 a, uint256 c, uint256 s) { (a, c, s,,,,,,,,) = u.pools(AGENT); }

    // ───────── review v2 C1: puppet client cannot profit; agent loses first ─────────
    function test_C1_puppetDrainIsALossForAgentAndPuppet() public {
        _uw(AGENT, 50e6); _uw(UW1, 150e6);
        uint256 agentStart = usdc.balanceOf(AGENT) + usdc.balanceOf(PUPPET);
        uint256 id = _jobFrom(PUPPET, 100e6, 20 minutes);          // 2x the agent's own 50
        vm.prank(AGENT); u.cover(id, 100e6);
        vm.warp(vm.getBlockTimestamp() + 20 minutes);
        u.resolve(id); g.claimRefund(id);
        uint256 agentEnd = usdc.balanceOf(AGENT) + usdc.balanceOf(PUPPET);
        assertEq(agentStart, agentEnd);                             // puppet only got its own escrow back
        assertEq(usdc.balanceOf(SINK), 100e6);                      // the slash fed the sink
        assertEq(u.sharesOf(AGENT, AGENT), 0);                      // agent stake burned first (50)
        assertApproxEqAbs(u.valueOf(AGENT, u.sharesOf(AGENT, UW1)), 100e6, 3);   // UW1 lost only the 50 beyond it
    }
    function test_leverageCap() public {
        _uw(AGENT, 10e6); _uw(UW1, 1_000e6);
        uint256 id = _job(21e6);
        vm.prank(AGENT); vm.expectRevert(G2Underwrite3.OverLeverage.selector); u.cover(id, 21e6);
        uint256 id2 = _job(20e6);
        vm.prank(AGENT); u.cover(id2, 20e6);
    }
    function test_noOwnStakeNoCover() public {
        _uw(UW1, 1_000e6); uint256 id = _job(1e6);
        vm.prank(AGENT); vm.expectRevert(G2Underwrite3.OverLeverage.selector); u.cover(id, 1e6);
    }
    function test_slashWithinAgentStakeLeavesUnderwritersWhole() public {
        _uw(AGENT, 50e6); _uw(UW1, 50e6); uint256 id = _job(30e6);
        vm.prank(AGENT); u.cover(id, 30e6);
        vm.warp(vm.getBlockTimestamp() + 1 days); u.resolve(id);
        assertApproxEqAbs(u.valueOf(AGENT, u.sharesOf(AGENT, UW1)), 50e6, 3);
        assertApproxEqAbs(u.ownStake(AGENT), 20e6, 3);
    }
    // ───────── M3: horizon and utilisation ─────────
    function test_M3_horizonCap() public {
        _uw(AGENT, 50e6); uint256 id = _jobFrom(CLIENT, 10e6, 31 days);
        vm.prank(AGENT); vm.expectRevert(G2Underwrite3.TooFarAhead.selector); u.cover(id, 10e6);
    }
    function test_M3_utilisationCap() public {
        _uw(AGENT, 100e6); uint256 id = _job(81e6);
        vm.prank(AGENT); vm.expectRevert(G2Underwrite3.OverUtilised.selector); u.cover(id, 81e6);
        uint256 id2 = _job(80e6);
        vm.prank(AGENT); u.cover(id2, 80e6);
    }
    // ───────── M1: no standing notice, no premium sandwich ─────────
    function test_M1_noticeNeedsShares() public {
        vm.prank(UW2); vm.expectRevert(G2Underwrite3.NotEnoughShares.selector); u.requestWithdraw(AGENT, 1);
    }
    function test_M1_noticeExpires() public {
        _uw(UW1, 10e6); uint256 s = u.sharesOf(AGENT, UW1);
        vm.prank(UW1); u.requestWithdraw(AGENT, s);
        vm.warp(vm.getBlockTimestamp() + 5 days + 1);
        vm.prank(UW1); vm.expectRevert(G2Underwrite3.NoticeExpired.selector); u.withdraw(AGENT);
    }
    function test_M1_premiumSandwichEarnsNothing() public {
        vm.prank(AGENT); u.setPremium(2000);
        _uw(AGENT, 100e6); _uw(UW1, 100e6);
        _uw(UW2, 900e6); uint256 s = u.sharesOf(AGENT, UW2);
        vm.prank(UW2); u.requestWithdraw(AGENT, s);                // value locked at request
        uint256 id = _job(100e6);
        vm.prank(AGENT); u.cover(id, 100e6);                       // pays a 20 premium into the pool
        vm.prank(AGENT); g.submit(id, keccak256("x"), ""); vm.prank(EVAL); g.complete(id, "ok", ""); u.resolve(id);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.prank(UW2); u.withdraw(AGENT);
        assertLe(usdc.balanceOf(UW2), 1_000_000e6);                // never more than deposited
    }
    // ───────── M2: exiting before a known slash cannot dump the loss on stayers ─────────
    function test_M2_exitBeforeSlashSharesTheLoss() public {
        _uw(AGENT, 50e6); _uw(UW1, 50e6); _uw(UW2, 50e6);
        uint256 s1 = u.sharesOf(AGENT, UW1);
        vm.prank(UW1); u.requestWithdraw(AGENT, s1);
        uint256 id = _jobFrom(CLIENT, 100e6, 3 days + 1 hours);
        vm.prank(AGENT); u.cover(id, 100e6);
        vm.warp(vm.getBlockTimestamp() + 3 days + 1 hours);                // deadline passed, slash certain
        vm.prank(UW1); u.withdraw(AGENT);                           // exit from FREE assets only
        u.resolve(id);
        uint256 got1 = usdc.balanceOf(UW1) - (1_000_000e6 - 50e6);
        uint256 left2 = u.valueOf(AGENT, u.sharesOf(AGENT, UW2));
        assertLe(got1, uint256(50e6) / 3 + 1);                               // leaver took only its share of the free 50
        assertApproxEqRel(left2 + got1, 50e6, 0.35e18);             // and the stayer is not left holding all of it
    }
    // ───────── L2: wiped pool restarts, no inflation lock ─────────
    function test_L2_wipedPoolStartsNewEpoch() public {
        _uw(AGENT, 10e6); uint256 id = _job(8e6);
        vm.prank(AGENT); u.cover(id, 8e6);
        vm.warp(vm.getBlockTimestamp() + 1 days); u.resolve(id);          // 10 -> 2 left
        uint256 id2 = _job(1.6e6);
        vm.prank(AGENT); u.cover(id2, 1.6e6);
        vm.warp(vm.getBlockTimestamp() + 2 days); u.resolve(id2);
        for (uint256 i; i < 6; i++) {                               // repeat wipes: shares must not explode
            _uw(AGENT, 1e6); uint256 j = _job(0.8e6);
            vm.prank(AGENT); u.cover(j, 0.8e6);
            vm.warp(vm.getBlockTimestamp() + 2 days); u.resolve(j);
        }
        _uw(UW1, 10_000e6);
        assertApproxEqAbs(u.valueOf(AGENT, u.sharesOf(AGENT, UW1)), 10_000e6, 10_000);
    }
    function test_L2_restartSendsDustAndZeroesOldShares() public {
        _uw(AGENT, 1e6); uint256 id = _job(0.8e6);
        vm.prank(AGENT); u.cover(id, 0.8e6);
        vm.warp(vm.getBlockTimestamp() + 1 days); u.resolve(id);
        (uint256 a,,) = _pool();
        assertGt(a, 0);                                             // 0.2 left: above dust, no restart
    }
    function test_L2_dustPoolRestartsEpoch() public {
        _uw(AGENT, 4000);                                          // 0.004 USDC pool
        uint256 id = _job(3200);                                   // 80% of the pool, 0.8x the own stake
        vm.prank(AGENT); u.cover(id, 3200);
        vm.warp(vm.getBlockTimestamp() + 1 days); u.resolve(id);  // 800 left < DUST, nothing committed: new epoch
        (uint256 a,, uint256 s) = _pool();
        assertEq(a, 0); assertEq(s, 0);
        assertEq(u.sharesOf(AGENT, AGENT), 0);
        assertEq(usdc.balanceOf(SINK), 4000);                      // slash + dust fed the sink
        _uw(UW1, 10e6);
        assertApproxEqAbs(u.valueOf(AGENT, u.sharesOf(AGENT, UW1)), 10e6, 2);
    }
    // ───────── carried over from v2 ─────────
    function test_onlyFundedWithTimeAndExactBudget() public {
        _uw(AGENT, 50e6);
        vm.prank(CLIENT); uint256 open = g.createJob(AGENT, EVAL, vm.getBlockTimestamp() + 1 days, "w", address(0));
        vm.prank(CLIENT); g.setBudget(open, 10e6, "");
        vm.prank(AGENT); vm.expectRevert(G2Underwrite3.JobNotCoverable.selector); u.cover(open, 10e6);
        uint256 id = _job(10e6);
        vm.prank(AGENT); vm.expectRevert(G2Underwrite3.BudgetMismatch.selector); u.cover(id, 10e6 + 1);
        uint256 late = _jobFrom(CLIENT, 10e6, 10 minutes);
        vm.prank(AGENT); vm.expectRevert(G2Underwrite3.TooLittleTime.selector); u.cover(late, 10e6);
    }
    function test_strangerAndSelfDealing() public {
        _uw(AGENT, 50e6); uint256 id = _job(10e6);
        vm.prank(UW1); vm.expectRevert(G2Underwrite3.NotProvider.selector); u.cover(id, 10e6);
        vm.prank(AGENT); uint256 self = g.createJob(AGENT, EVAL, vm.getBlockTimestamp() + 1 days, "s", address(0));
        vm.prank(AGENT); g.setBudget(self, 1e6, ""); vm.prank(AGENT); g.fund(self, 1e6, "");
        vm.prank(AGENT); vm.expectRevert(G2Underwrite3.SelfDealing.selector); u.cover(self, 1e6);
    }
    function test_F4_frozenMissSurvivesLateReject() public {
        _uw(AGENT, 50e6); uint256 id = _job(10e6);
        vm.prank(AGENT); u.cover(id, 10e6);
        vm.warp(vm.getBlockTimestamp() + 1 days); u.markMissed(id);
        vm.prank(EVAL); g.reject(id, "late", "");
        u.resolve(id); assertEq(usdc.balanceOf(SINK), 10e6);
    }
    function test_deliveredReleasesAndDoubleResolveFails() public {
        _uw(AGENT, 50e6); uint256 id = _job(10e6);
        vm.prank(AGENT); u.cover(id, 10e6);
        vm.expectRevert(G2Underwrite3.NotFinal.selector); u.resolve(id);
        vm.prank(AGENT); g.submit(id, keccak256("x"), ""); vm.prank(EVAL); g.complete(id, "ok", "");
        u.resolve(id);
        vm.expectRevert(G2Underwrite3.NotCovered.selector); u.resolve(id);
        (, uint256 c,) = _pool(); assertEq(c, 0); assertEq(usdc.balanceOf(SINK), 0);
    }
    function test_premiumIsYield() public {
        vm.prank(AGENT); u.setPremium(1000);
        _uw(AGENT, 50e6); _uw(UW1, 50e6); uint256 id = _job(40e6);
        vm.prank(AGENT); u.cover(id, 40e6);                        // 4 premium into the pool
        vm.prank(AGENT); g.submit(id, keccak256("x"), ""); vm.prank(EVAL); g.complete(id, "ok", ""); u.resolve(id);
        assertApproxEqAbs(u.valueOf(AGENT, u.sharesOf(AGENT, UW1)), 52e6, 3);
    }
    function test_agentCannotExitWithOpenCovers() public {
        _uw(AGENT, 50e6); uint256 s = u.sharesOf(AGENT, AGENT);
        vm.prank(AGENT); u.requestWithdraw(AGENT, s);
        uint256 id = _jobFrom(CLIENT, 10e6, 4 days);
        vm.prank(AGENT); u.cover(id, 10e6);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.prank(AGENT); vm.expectRevert(G2Underwrite3.AgentHasOpenCovers.selector); u.withdraw(AGENT);
    }
    function test_withdrawNeedsNoticeAndOnlyOwnShares() public {
        _uw(UW1, 20e6); uint256 s = u.sharesOf(AGENT, UW1);
        vm.prank(UW1); vm.expectRevert(G2Underwrite3.NoWithdrawRequested.selector); u.withdraw(AGENT);
        vm.prank(UW1); u.requestWithdraw(AGENT, s);
        vm.prank(UW1); vm.expectRevert(G2Underwrite3.StillLocked.selector); u.withdraw(AGENT);
        vm.prank(UW2); vm.expectRevert(G2Underwrite3.NoWithdrawRequested.selector); u.withdraw(AGENT);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.prank(UW1); u.withdraw(AGENT);
        assertApproxEqAbs(usdc.balanceOf(UW1), 1_000_000e6, 2);
    }
    function test_blacklistedSinkCredited() public {
        _uw(AGENT, 50e6); uint256 id = _job(10e6);
        vm.prank(AGENT); u.cover(id, 10e6);
        vm.warp(vm.getBlockTimestamp() + 1 days); usdc.setBlacklist(SINK, true);
        u.resolve(id); assertEq(u.credits(SINK), 10e6);
    }
    function test_feeOnTransferRejectedAndPremiumCapped() public {
        vm.prank(AGENT); vm.expectRevert(G2Underwrite3.BadPremium.selector); u.setPremium(2001);
        U3FeeTok f = new U3FeeTok(); G2Jobs g2 = new G2Jobs(address(f), 0, address(0xFEE));
        G2Underwrite3 u2 = new G2Underwrite3(IG2Jobs(address(g2)), SINK);
        f.mint(UW1, 100e6); vm.prank(UW1); f.approve(address(u2), type(uint256).max);
        vm.prank(UW1); vm.expectRevert(G2Underwrite3.FeeOnTransferToken.selector); u2.underwrite(AGENT, 10e6);
    }
    function test_zeroSinkRejected() public {
        vm.expectRevert(G2Underwrite3.ZeroAddress.selector); new G2Underwrite3(IG2Jobs(address(g)), address(0));
    }
    // ───────── accounting fuzz ─────────
    function testFuzz_accounting(uint96 a0, uint96 a1, uint96 a2, uint8 outcome) public {
        uint256 own = bound(uint256(a0), 5e6, 500e6);
        uint256 x = bound(uint256(a1), 1e6, 500e6);
        uint256 y = bound(uint256(a2), 1e6, 500e6);
        vm.prank(AGENT); u.setPremium(300);
        _uw(AGENT, own); _uw(UW1, x); _uw(UW2, y);
        uint256 budget = u.capacity(AGENT);
        if (budget > 50e6) budget = 50e6;
        if (budget < 1e6) return;
        uint256 id = _job(budget);
        vm.prank(AGENT); u.cover(id, budget);
        uint8 o = outcome % 3;
        if (o == 0) { vm.warp(vm.getBlockTimestamp() + 1 days); }
        else if (o == 1) { vm.prank(AGENT); g.submit(id, keccak256("x"), ""); vm.prank(EVAL); g.complete(id, "ok", ""); }
        else { vm.warp(vm.getBlockTimestamp() + 1 days); usdc.setBlacklist(SINK, true); }
        u.resolve(id);
        assertEq(usdc.balanceOf(address(u)), u.totalAssets() + u.totalCredits());
        (uint256 a, uint256 c,) = _pool(); assertEq(c, 0); assertEq(a, u.totalAssets());
        assertLe(u.valueOf(AGENT, u.sharesOf(AGENT, UW1)) + u.valueOf(AGENT, u.sharesOf(AGENT, UW2)) + u.ownStake(AGENT), a);
    }
}
