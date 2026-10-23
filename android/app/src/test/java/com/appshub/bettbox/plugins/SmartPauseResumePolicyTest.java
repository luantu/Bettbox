package com.appshub.bettbox.plugins;

/** Exercises the production admission policy, including work queued before a pause. */
public final class SmartPauseResumePolicyTest {
    private static void require(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    public static void main(String[] args) {
        SmartPauseResumePolicy policy = new SmartPauseResumePolicy();
        policy.pauseSmart();
        policy.pauseCompatibility();
        require(policy.admitResume(false, true, false) == null,
                "ordinary check resumed after compatibility pause must be rejected at entry");

        policy = new SmartPauseResumePolicy();
        policy.pauseSmart();
        SmartPauseResumePolicy.Resume queued = policy.admitResume(false, true, false);
        require(queued != null, "smart-owned pause admits ordinary resume");
        policy.pauseCompatibility();
        require(!policy.commitResume(queued, true, false),
                "ordinary resume queued before compatibility pause cannot clear its owner");
        require(!policy.isCurrent(queued), "old ordinary token remains invalid at final TUN start");
        policy.start();
        require(policy.admitResume(false, true, false) == null,
                "a delayed generic start cannot erase compatibility ownership");

        SmartPauseResumePolicy.Resume own = policy.admitResume(true, true, false);
        require(own != null && policy.commitResume(own, true, false),
                "compatibility's own resume is allowed before manager clearSession");
        require(policy.isCurrent(own), "authorized owner can finish asynchronous TUN start");
        require(policy.admitResume(true, true, false) == null,
                "completed compatibility ownership cannot authorize a second resume");
        policy.pauseCompatibility();
        require(!policy.isCurrent(own), "new compatibility session invalidates old own resume");
        SmartPauseResumePolicy.Resume keepStopped = policy.admitResume(true, true, false);
        policy.stop();
        require(!policy.commitResume(keepStopped, true, false), "keep-stopped revokes queued own resume");
        require(policy.admitResume(false, true, false) == null, "ordinary resume cannot undo user stop");
        require(policy.admitResume(true, true, false) == null, "compatibility cannot undo user stop");

        policy.start();
        policy.pauseSmart();
        SmartPauseResumePolicy.Resume lateStop = policy.admitResume(false, true, false);
        require(!policy.commitResume(lateStop, false, false), "persisted stop wins after entry");
        require(policy.admitResume(false, false, false) == null, "persisted stop blocks entry");
        require(policy.admitResume(false, true, true) == null, "control-plane pause blocks ordinary entry");
        SmartPauseResumePolicy.Resume bypass = policy.admitResume(false, true, false);
        require(!policy.commitResume(bypass, true, true), "control-plane pause blocks queued resume");

        policy.start();
        long recoveryGeneration = policy.generation();
        require(policy.allowsStart(recoveryGeneration), "normal native recovery is unaffected");
        policy.pauseCompatibility();
        require(!policy.allowsStart(recoveryGeneration), "in-flight native start cannot overtake pause");
        long pausedGeneration = policy.generation();
        require(!policy.allowsStart(pausedGeneration), "new native recovery cannot steal compatibility pause");
        policy.clearSmart();
        policy.pauseSmart();
        require(policy.admitResume(false, true, false) == null,
                "legacy smart flags and repeated smart stop cannot erase compatibility owner");
        own = policy.admitResume(true, true, false);
        require(policy.commitResume(own, true, false), "compatibility owner survives legacy flag updates");
        require(policy.allowsStart(own.generation), "authorized resume unblocks current native recovery");
        policy.pauseSmart();
        require(!policy.isCurrent(own), "smart pause also revokes work awaiting TUN start");
        SmartPauseResumePolicy.Resume committed = policy.admitResume(false, true, false);
        require(policy.commitResume(committed, true, false), "ordinary resume can begin normally");
        policy.pauseCompatibility();
        require(!policy.isCurrent(committed) && !policy.allowsStart(committed.generation),
                "compatibility pause revokes ordinary resume already executing asynchronously");
        System.out.println("SmartPauseResumePolicy: all behavior checks passed");
    }
}
