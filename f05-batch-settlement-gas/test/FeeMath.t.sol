// SPDX-License-Identifier: BUSL-1.1
// Worker F — FeeMath fuzz + UFARM1-6 regression (AUM fees must dilute performance-fee base).
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {FeeMath} from "../src/contracts/libraries/FeeMath.sol";

contract FeeMathHarness {
    function aumFeeShares(uint256 supply, uint256 annualFee, uint256 elapsed) external pure returns (uint256) {
        return FeeMath.aumFeeShares(supply, annualFee, elapsed);
    }

    function performanceFeeShares(uint256 nav, uint256 supply, uint256 hwm, uint256 schedule)
        external
        pure
        returns (uint256 feeShares, uint256 sharePrice)
    {
        return FeeMath.performanceFeeShares(nav, supply, hwm, schedule);
    }

    function isValidSchedule(uint256 packed) external pure returns (bool) {
        return FeeMath.isValidPerformanceFeeSchedule(packed);
    }

    function splitCuratorFee(uint256 shares, bool zeroUFarmFee)
        external
        pure
        returns (uint256 protocolCut, uint256 curatorCut)
    {
        return FeeMath.splitCuratorFee(shares, zeroUFarmFee);
    }
}

contract FeeMathFuzzTest is Test {
    FeeMathHarness internal h;

    function setUp() public {
        h = new FeeMathHarness();
    }

    // --- aumFeeShares ---
    function testFuzz_aumFeeShares_bounds(uint256 supply, uint256 annualFee, uint256 elapsed) public view {
        supply = bound(supply, 0, 1e36);
        annualFee = bound(annualFee, 0, 1e18);
        elapsed = bound(elapsed, 0, 365 days * 10);
        uint256 shares = h.aumFeeShares(supply, annualFee, elapsed);
        if (supply == 0 || annualFee == 0 || elapsed == 0) {
            assertEq(shares, 0, "zero input must give zero fee shares");
        } else {
            // Tiny inputs can round to zero via mulDiv; the invariant is the bound.
            // periodFee capped at 0.5 WAD => shares = supply*p/(WAD-p) <= supply
            assertLe(shares, supply, "aum fee shares must never exceed supply");
        }
    }

    function testFuzz_aumFeeShares_monotoneElapsed(uint256 supply, uint256 annualFee, uint256 e1, uint256 e2)
        public
        view
    {
        supply = bound(supply, 1, 1e30);
        annualFee = bound(annualFee, 1, 1e18);
        e1 = bound(e1, 0, 365 days);
        e2 = bound(e2, 0, 365 days);
        uint256 a = h.aumFeeShares(supply, annualFee, e1);
        uint256 b = h.aumFeeShares(supply, annualFee, e2);
        if (e1 <= e2) assertLe(a, b, "fee must be monotone in elapsed");
        else assertGe(a, b, "fee must be monotone in elapsed");
    }

    // --- performanceFeeShares ---
    function testFuzz_perfFee_bounds(uint256 nav, uint256 supply, uint256 hwm, uint256 schedule) public view {
        supply = bound(supply, 0, 1e36);
        nav = bound(nav, 0, 1e36);
        hwm = bound(hwm, 1, 10e18);
        (uint256 feeShares, uint256 sharePrice) = h.performanceFeeShares(nav, supply, hwm, schedule);
        if (supply == 0) {
            assertEq(feeShares, 0);
            assertEq(sharePrice, 0);
            return;
        }
        // sharePrice = nav * WAD / supply (mulDiv rounds down)
        assertEq(sharePrice, (nav * 1e18) / supply, "share price must be nav/supply in WAD");
        // feeValue capped at nav/2 => feeShares = feeValue*supply/(nav-feeValue) <= supply
        assertLe(feeShares, supply, "perf fee shares must never exceed supply");
        if (schedule == 0 || sharePrice <= hwm) {
            assertEq(feeShares, 0, "no fee below HWM or with empty schedule");
        }
    }

    // --- UFARM1-6 regression: AUM fees dilute the performance-fee base ---
    // Concrete case: supply 1,000,000 shares, NAV $1,200,000 (price 1.20), HWM 1.00,
    // 20% perf fee above 0% threshold. With a 10% annual management fee over 1 year
    // the AUM shares must LOWER the performance fee (in USD value terms).
    function test_perfFee_aumDilution_regression() public view {
        uint256 supply = 1_000_000e18;
        uint256 nav = 1_200_000e18;
        uint256 hwm = 1e18;
        // schedule: one step, fee 2000 bps, threshold 0 bps (step = fee | threshold<<16)
        uint256 schedule = uint256(2000);
        (uint256 feeNoAum,) = h.performanceFeeShares(nav, supply, hwm, schedule);
        uint256 aumShares = h.aumFeeShares(supply, 0.1e18, 365 days);
        assertGt(aumShares, 0, "aum shares must be positive");
        (uint256 feeWithAum, uint256 priceWithAum) =
            h.performanceFeeShares(nav, supply + aumShares, hwm, schedule);
        (, uint256 priceNoAum) = h.performanceFeeShares(nav, supply, hwm, schedule);
        assertLt(priceWithAum, priceNoAum, "AUM dilution must lower the perf-fee share price");
        // fee VALUE (not shares): feeShares * price / WAD must not grow with dilution
        uint256 valueNoAum = (feeNoAum * priceNoAum) / 1e18;
        uint256 valueWithAum = (feeWithAum * priceWithAum) / 1e18;
        assertLe(valueWithAum, valueNoAum, "AUM fees must not increase performance-fee value");
    }

    function testFuzz_perfFee_aumDilution(uint256 supply, uint256 nav, uint256 hwm, uint256 feeBps) public view {
        supply = bound(supply, 1e18, 1e30);
        // nav above HWM*supply so there is profit; cap nav at 2x for sane prices
        hwm = bound(hwm, 1e17, 1e18);
        nav = bound(nav, (supply * hwm) / 1e18 + 1, ((supply * hwm) / 1e18) * 2);
        feeBps = bound(feeBps, 1, 5000);
        uint256 schedule = feeBps; // single step, 0% threshold
        uint256 aumShares = h.aumFeeShares(supply, 0.05e18, 365 days);
        (uint256 feeNoAum, uint256 priceNoAum) = h.performanceFeeShares(nav, supply, hwm, schedule);
        (uint256 feeWithAum, uint256 priceWithAum) =
            h.performanceFeeShares(nav, supply + aumShares, hwm, schedule);
        assertLt(priceWithAum, priceNoAum, "dilution must lower share price");
        uint256 valueNoAum = (feeNoAum * priceNoAum) / 1e18;
        uint256 valueWithAum = (feeWithAum * priceWithAum) / 1e18;
        assertLe(valueWithAum, valueNoAum, "AUM dilution must not increase perf-fee value");
    }

    // --- UFARM1-6 residual cross-check (worker D FINDING-01) ---
    // My original invariant (fee value with AUM dilution <= without) is TRUE but
    // too weak: it does not test the CORRECT benchmark. The code charges the
    // performance fee on the enlarged supply S1 = S0 + A, i.e. fee = rate x
    // (NAV - HWM*S1); the net-of-AUM-fee benchmark is rate x (p1 - HWM) x S0.
    // The excess is rate x (p1 - HWM) x A. This test independently reproduces
    // worker D's numbers (S0=1000, NAV=2000, HWM=1, 10% mgmt, 20% perf fee):
    // code ~177.778 vs correct 160.
    function test_perfFee_aumResidual_overcharge_workerD_crosscheck() public view {
        uint256 supply = 1000e18;
        uint256 nav = 2000e18;
        uint256 hwm = 1e18;
        uint256 schedule = uint256(2000) | (uint256(0xffff) << 16); // 20% fee, MAX threshold
        uint256 aumShares = h.aumFeeShares(supply, 0.1e18, 365 days);
        uint256 supplyAfterAum = supply + aumShares;
        (uint256 feeShares, uint256 price) = h.performanceFeeShares(nav, supplyAfterAum, hwm, schedule);
        // feeValue recovered from feeShares: feeShares = feeValue*supply/(nav-feeValue)
        uint256 feeValueCode = (feeShares * nav) / (supplyAfterAum + feeShares);
        uint256 feeValueCorrect = ((price - hwm) * supply * 2000) / 1e18 / 10_000;
        assertGt(feeValueCode, feeValueCorrect, "code must overcharge vs net-of-AUM benchmark");
        uint256 excess = feeValueCode - feeValueCorrect;
        // excess == rate * (p1 - HWM) * AUM (within rounding: AUM has 1-wei rounding)
        uint256 expectedExcess = ((price - hwm) * aumShares * 2000) / 1e18 / 10_000;
        assertApproxEqAbs(excess, expectedExcess, 1e12, "excess must equal rate*(p1-HWM)*AUM");
        // worker D's headline numbers: code ~177.778, correct 160 (1e18 units)
        assertApproxEqAbs(feeValueCode, 177_777_777_777_777_777_777, 1e12, "code fee value ~177.778");
        assertApproxEqAbs(feeValueCorrect, 160e18, 1e12, "correct fee value 160");
    }

    // --- schedule validation ---
    function testFuzz_scheduleValidation(uint256 packed) public view {
        bool valid = h.isValidSchedule(packed);
        if (!valid) return; // invalid is fine; only check valid ones are well-formed
        uint256 schedule = uint256(uint128(packed));
        if (schedule == 0) return; // empty schedule is valid (no performance fee)
        uint256 prev = 0;
        uint256 steps;
        for (uint256 i = 0; i < 4; ++i) {
            uint256 step = (schedule >> (i * 32)) & 0xffffffff;
            if (step == 0) break;
            uint256 feeBps = step & 0xffff;
            uint256 thresholdBps = (step >> 16) & 0xffff;
            assertLe(feeBps, 5000, "valid schedule feeBps <= 5000");
            assertGt(thresholdBps, prev, "valid schedule thresholds strictly increasing");
            prev = thresholdBps;
            steps++;
            if (thresholdBps == type(uint16).max) break;
        }
        assertGt(steps, 0, "valid non-zero schedule must have >= 1 step");
    }

    // --- splitCuratorFee ---
    function testFuzz_splitCuratorFee(uint256 shares, bool zeroUFarmFee) public view {
        shares = bound(shares, 0, 1e36);
        (uint256 protocolCut, uint256 curatorCut) = h.splitCuratorFee(shares, zeroUFarmFee);
        assertEq(protocolCut + curatorCut, shares, "split must sum to shares");
        if (zeroUFarmFee) {
            assertEq(protocolCut, 0);
            assertEq(curatorCut, shares);
        } else {
            // 20% to protocol (mulDiv rounding: within 1 wei); avoid underflow at shares=0
            assertGe(protocolCut + 1, (shares * 2) / 10);
            assertLe(protocolCut, (shares * 2) / 10 + 1);
        }
    }
}
