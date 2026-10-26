package com.appshub.bettbox.services;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicInteger;

/** Repeated user clicks reuse one pause window, never a stale resume decision. */
public final class CompatibilityLaunchSessionTest {
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    public static void main(String[] args) throws Exception {
        CompatibilityLaunchSession session = new CompatibilityLaunchSession();
        CompatibilityLaunchSession.Request first = session.requestLaunch();
        check(first.dispatch && first.newSession, "first open must dispatch and own the pause");
        check(!session.canAutoResume(first.generation, first.revision),
                "in-flight launch must block auto-resume");
        CompatibilityLaunchSession.Request duringLaunch = session.requestLaunch();
        check(!duringLaunch.dispatch && !duringLaunch.newSession,
                "rapid taps during launch must be accepted without duplicate launch workers");
        check(duringLaunch.generation == first.generation, "duplicate tap created another pause session");
        check(session.finishLaunch(first.generation), "current launch could not finish");
        long observedRevision = session.revision(first.generation);
        check(session.canAutoResume(first.generation, observedRevision), "idle current session cannot resume");

        CompatibilityLaunchSession.Request reopen = session.requestLaunch();
        check(reopen.dispatch && !reopen.newSession && reopen.generation == first.generation,
                "second open must dispatch within the existing pause window");
        check(!session.canAutoResume(first.generation, observedRevision),
                "a resume decision from before re-open must be revoked");
        session.finishLaunch(reopen.generation);
        check(!session.canAutoResume(first.generation, observedRevision),
                "stale departure cannot resume VPN even after re-open finished");
        check(session.canAutoResume(reopen.generation, reopen.revision), "latest idle revision lost");

        check(session.end(reopen.generation), "explicit end failed");
        CompatibilityLaunchSession.Request next = session.requestLaunch();
        check(next.newSession && next.dispatch && next.generation != first.generation,
                "open after recovery must create a new session");
        check(!session.end(first.generation) && !session.finishLaunch(first.generation),
                "old coroutine modified a newer session");
        check(session.isCurrent(next.generation), "new session was cleared by the old monitor");

        CompatibilityLaunchSession concurrent = new CompatibilityLaunchSession();
        CountDownLatch ready = new CountDownLatch(1);
        AtomicInteger dispatches = new AtomicInteger();
        List<Thread> threads = new ArrayList<>();
        for (int i = 0; i < 20; i++) {
            Thread thread = new Thread(() -> {
                try { ready.await(); } catch (InterruptedException e) { throw new AssertionError(e); }
                if (concurrent.requestLaunch().dispatch) dispatches.incrementAndGet();
            });
            threads.add(thread);
            thread.start();
        }
        ready.countDown();
        for (Thread thread : threads) thread.join();
        check(dispatches.get() == 1, "concurrent taps created multiple launch/pause workers");
        System.out.println("CompatibilityLaunchSession: repeated and concurrent launch checks passed");
    }
}
