package com.appshub.bettbox.services;

/** One pause owner, repeatable launches, and revocable departure decisions. */
public final class CompatibilityLaunchSession {
    public static final class Request {
        public final long generation;
        public final long revision;
        public final boolean newSession;
        public final boolean dispatch;

        private Request(long generation, long revision, boolean newSession, boolean dispatch) {
            this.generation = generation;
            this.revision = revision;
            this.newSession = newSession;
            this.dispatch = dispatch;
        }
    }

    private long generation;
    private long revision;
    private boolean active;
    private boolean launching;

    public synchronized Request requestLaunch() {
        boolean fresh = !active;
        if (fresh) {
            active = true;
            generation++;
        }
        revision++;
        boolean dispatch = !launching;
        launching = true;
        return new Request(generation, revision, fresh, dispatch);
    }

    public synchronized boolean isActive() { return active; }
    public synchronized long generation() { return generation; }
    public synchronized boolean isCurrent(long expected) { return active && generation == expected; }
    public synchronized long revision(long expected) { return isCurrent(expected) ? revision : -1; }

    public synchronized boolean finishLaunch(long expected) {
        if (!isCurrent(expected)) return false;
        launching = false;
        return true;
    }

    public synchronized boolean canAutoResume(long expected, long observedRevision) {
        return isCurrent(expected) && !launching && revision == observedRevision;
    }

    public synchronized boolean end(long expected) {
        if (!isCurrent(expected)) return false;
        active = false;
        launching = false;
        return true;
    }

    public synchronized boolean endIfIdle(long expected, long observedRevision) {
        return canAutoResume(expected, observedRevision) && end(expected);
    }
}
