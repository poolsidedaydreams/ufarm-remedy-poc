// SPDX-License-Identifier: BUSL-1.1
// Worker F — CrossChainCodec round-trip + CrossChainReducer state-machine fuzz.
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {CrossChainCodec} from "../src/contracts/libraries/CrossChainCodec.sol";
import {CrossChainReducer} from "../src/contracts/libraries/CrossChainReducer.sol";
import {CrossChainTypes} from "../src/contracts/libraries/CrossChainTypes.sol";

contract CodecReducerHarness {
    function encodeMsg(CrossChainTypes.CrossChainMessage memory m) external pure returns (bytes memory) {
        return CrossChainCodec.encode(m);
    }

    function decodeMsg(bytes memory raw)
        external
        pure
        returns (bool ok, CrossChainTypes.CrossChainMessage memory m)
    {
        return CrossChainCodec.decode(raw);
    }

    function accounting(CrossChainTypes.CrossChainMessage memory m, CrossChainTypes.CrossChainState memory s, uint64 a)
        external
        pure
        returns (CrossChainTypes.CrossChainAction)
    {
        return CrossChainReducer.accountingAction(m, s, a);
    }

    function satellite(CrossChainTypes.CrossChainMessage memory m, CrossChainTypes.CrossChainState memory s, uint64 l)
        external
        pure
        returns (CrossChainTypes.CrossChainAction)
    {
        return CrossChainReducer.satelliteAction(m, s, l);
    }
}

contract CodecReducerFuzzTest is Test {
    CodecReducerHarness internal h;

    function setUp() public {
        h = new CodecReducerHarness();
    }

    function _msg(uint256 seed) internal pure returns (CrossChainTypes.CrossChainMessage memory m) {
        m.version = CrossChainTypes.VERSION;
        m.messageType = CrossChainTypes.CrossChainMessageType(seed % 5);
        m.sourceChainId = uint64((seed >> 8) % 100000 + 1);
        m.destinationChainId = uint64((seed >> 24) % 100000 + 1);
        m.sessionNonce = uint64(seed >> 40);
        m.amount = (seed % 1e18) * 7919; // keep bounded: seed * 7919 would overflow for huge seeds
    }

    function _state(uint256 seed) internal pure returns (CrossChainTypes.CrossChainState memory s) {
        s.state = CrossChainTypes.CrossChainSessionState(seed % 4);
        s.sourceChainId = uint64((seed >> 8) % 100000 + 1);
        s.destinationChainId = uint64((seed >> 24) % 100000 + 1);
        s.sessionNonce = uint64(seed >> 40);
        s.outbox.exists = (seed & 1) == 1;
        s.outbox.message = _msg(seed ^ 0xdead);
        s.outbox.nextState = CrossChainTypes.CrossChainSessionState((seed >> 4) % 4);
        s.outbox.targetChainId = uint64((seed >> 48) % 100000 + 1);
    }

    // --- Codec round-trip ---
    function testFuzz_codecRoundTrip(uint256 seed) public view {
        CrossChainTypes.CrossChainMessage memory m = _msg(seed);
        // decode() only accepts amount==0 for Reset / TransferSent / TransferReceipt;
        // TransferRequest and TransferApproval require a non-zero amount, and
        // Reset requires amount == 0.
        if (m.messageType == CrossChainTypes.CrossChainMessageType.Reset) {
            m.amount = 0;
        } else if (
            m.amount == 0
                && (m.messageType == CrossChainTypes.CrossChainMessageType.TransferRequest
                    || m.messageType == CrossChainTypes.CrossChainMessageType.TransferApproval)
        ) {
            m.amount = 1;
        }
        bytes memory raw = h.encodeMsg(m);
        assertEq(raw.length, 192, "encoded length must be 6 words");
        (bool ok, CrossChainTypes.CrossChainMessage memory d) = h.decodeMsg(raw);
        assertTrue(ok, "decode of own encode must succeed");
        assertEq(d.version, m.version);
        assertEq(uint8(d.messageType), uint8(m.messageType));
        assertEq(d.sourceChainId, m.sourceChainId);
        assertEq(d.destinationChainId, m.destinationChainId);
        assertEq(d.sessionNonce, m.sessionNonce);
        assertEq(d.amount, m.amount);
    }

    function testFuzz_codecRejectsBadLength(bytes memory raw) public view {
        vm.assume(raw.length != 192);
        (bool ok,) = h.decodeMsg(raw);
        assertFalse(ok, "wrong length must be rejected");
    }

    function test_codecRejectsBadVersionAndType() public view {
        CrossChainTypes.CrossChainMessage memory m = _msg(12345);
        bytes memory raw = h.encodeMsg(m);
        // corrupt version word (offset 0)
        bytes memory bad = raw;
        bad[31] = bytes1(uint8(2));
        (bool ok,) = h.decodeMsg(bad);
        assertFalse(ok, "wrong version must be rejected");
        // corrupt type word to 5 (> Reset=4): byte offset 32+31=63
        bytes memory badType = raw;
        badType[63] = bytes1(uint8(5));
        (ok,) = h.decodeMsg(badType);
        assertFalse(ok, "type > Reset must be rejected");
        // zero source chain (craft a message with source 0 and re-encode)
        CrossChainTypes.CrossChainMessage memory m0 = _msg(999);
        m0.sourceChainId = 0;
        (ok,) = h.decodeMsg(h.encodeMsg(m0));
        assertFalse(ok, "zero source chain must be rejected");
        m0 = _msg(999);
        m0.destinationChainId = 0;
        (ok,) = h.decodeMsg(h.encodeMsg(m0));
        assertFalse(ok, "zero destination chain must be rejected");
    }

    // --- Reducer invariants ---
    function testFuzz_reducerAccountingOutboxIgnores(uint256 seed) public view {
        CrossChainTypes.CrossChainMessage memory m = _msg(seed);
        CrossChainTypes.CrossChainState memory s = _state(seed);
        s.outbox.exists = true;
        uint64 accountingChainId = uint64((seed >> 56) % 100000 + 1);
        CrossChainTypes.CrossChainAction a = h.accounting(m, s, accountingChainId);
        assertEq(uint8(a), uint8(CrossChainTypes.CrossChainAction.Ignore), "outbox present => Ignore");
    }

    function testFuzz_reducerSatelliteTransferGating(uint256 seed) public view {
        CrossChainTypes.CrossChainMessage memory m = _msg(seed);
        CrossChainTypes.CrossChainState memory s = _state(seed);
        uint64 local = uint64((seed >> 56) % 100000 + 1);
        CrossChainTypes.CrossChainAction a = h.satellite(m, s, local);
        if (a == CrossChainTypes.CrossChainAction.AcceptTransfer) {
            assertEq(uint8(m.messageType), uint8(CrossChainTypes.CrossChainMessageType.TransferSent));
            assertEq(m.destinationChainId, local);
            assertTrue(m.amount != 0 || !s.outbox.exists, "zero-amount transfer needs empty outbox");
        }
    }

    function testFuzz_reducerDeterministic(uint256 seed) public view {
        CrossChainTypes.CrossChainMessage memory m = _msg(seed);
        CrossChainTypes.CrossChainState memory s = _state(seed);
        uint64 chainId = uint64((seed >> 56) % 100000 + 1);
        assertEq(uint8(h.accounting(m, s, chainId)), uint8(h.accounting(m, s, chainId)), "must be deterministic");
        assertEq(uint8(h.satellite(m, s, chainId)), uint8(h.satellite(m, s, chainId)), "must be deterministic");
    }

    function testFuzz_reducerAccountingAcceptRequestShape(uint256 seed) public view {
        CrossChainTypes.CrossChainMessage memory m = _msg(seed);
        CrossChainTypes.CrossChainState memory s = _state(seed);
        s.outbox.exists = false;
        uint64 accountingChainId = uint64((seed >> 56) % 100000 + 1);
        CrossChainTypes.CrossChainAction a = h.accounting(m, s, accountingChainId);
        if (a == CrossChainTypes.CrossChainAction.AcceptRequest) {
            assertEq(uint8(s.state), uint8(CrossChainTypes.CrossChainSessionState.Idle));
            assertEq(uint8(m.messageType), uint8(CrossChainTypes.CrossChainMessageType.TransferRequest));
            assertTrue(m.sourceChainId != accountingChainId);
            assertTrue(m.sourceChainId != m.destinationChainId);
        }
    }
}
