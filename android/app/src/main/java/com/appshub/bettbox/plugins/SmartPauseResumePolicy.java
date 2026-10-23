package com.appshub.bettbox.plugins;

/** Pause ownership and revocable admission for asynchronous Android starts.
 * The caller holds runLock when changing runtime flags or entering the native TUN.
 */
public final class SmartPauseResumePolicy {
    private enum Owner { NONE, SMART, COMPATIBILITY, STOPPED }

    public static final class Resume {
        public final long generation;
        private final Owner owner;
        private Resume(long generation, Owner owner) {
            this.generation = generation;
            this.owner = owner;
        }
    }

    private Owner owner = Owner.NONE;
    private long generation;
    private Resume admitted;

    public synchronized long generation() { return generation; }

    public synchronized void pauseSmart() {
        if (owner == Owner.COMPATIBILITY || owner == Owner.STOPPED) return;
        changeOwner(Owner.SMART);
    }

    public synchronized void pauseCompatibility() { changeOwner(Owner.COMPATIBILITY); }
    public synchronized void stop() { changeOwner(Owner.STOPPED); }
    public synchronized void start() {
        if (owner != Owner.COMPATIBILITY) changeOwner(Owner.NONE);
    }

    public synchronized void clearSmart() {
        if (owner == Owner.SMART) changeOwner(Owner.NONE);
    }

    public synchronized Resume admitResume(boolean compatibility, boolean wanted, boolean controlPaused) {
        if (!wanted || controlPaused || owner == Owner.STOPPED) return null;
        if (compatibility ? owner != Owner.COMPATIBILITY : owner == Owner.COMPATIBILITY) return null;
        admitted = new Resume(generation, owner);
        return admitted;
    }

    public synchronized boolean commitResume(Resume request, boolean wanted, boolean controlPaused) {
        if (!wanted || controlPaused || !isCurrent(request) || owner != request.owner) return false;
        owner = Owner.NONE;
        return true;
    }

    public synchronized boolean isCurrent(Resume request) {
        return request != null && admitted == request && request.generation == generation;
    }

    public synchronized boolean allowsStart(long expectedGeneration) {
        return expectedGeneration == generation && owner == Owner.NONE;
    }

    public synchronized boolean keepResourcesAfterCancelledStart(long expectedGeneration) {
        return expectedGeneration != generation && (owner == Owner.SMART || owner == Owner.NONE);
    }

    private void changeOwner(Owner next) {
        owner = next;
        generation++;
        admitted = null;
    }
}
