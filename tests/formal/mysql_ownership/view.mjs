const phase = {
  down: "Not started", refused: "Refused: Store locked", ready: "Owns the Store",
  committing: "Batch sent, waiting for COMMIT's OK", reconnect: "Connection lost",
  lockWait: "Reconnected, waiting for the old session's lock",
  fenced: "Fenced, exits", closed: "Closed",
};
export const title = "Host A: a MySQL write batch across a lost connection";
export const state = (v) => phase[v.pc.A] ?? v.pc.A;
export const group = (v) => (v.pc.A === "fenced" || v.pc.A === "refused" ? "stop" : ["reconnect","lockWait"].includes(v.pc.A) ? "recovery" : "normal");
export const step = (a, f, t) => {
  switch (a) {
    case "HostOpens": return "Host opens the Store (epoch + 1)";
    case "HostRefused": return "another session holds the lock";
    case "HostSendsBatch": return t.rerun.A ? "Host sends the batch [again]" : "Host sends the batch";
    case "HostCommitted": return "COMMIT's OK arrives";
    case "HostFenceFailed": return "the fence matches no row";
    case "HostLosesConnection": return "the connection drops";
    case "HostReclaimReads": return t.pc.A === "fenced" ? "epoch changed or a stranger holds the lock" : "new session: epoch and lock holder match";
    case "HostReclaimsLock": return t.pc.A === "ready" ? (t.batch.A > f.batch.A ? "lock taken: COMMIT had landed" : "lock taken: nothing landed, run again") : "lock taken: Store moved on";
    case "HostLockTimesOut": return "lock wait times out";
    case "HostLosesReclaim": return "the new connection drops";
    case "HostCloses": return "batches done, Host closes";
    case "ServerRuns": return "the server runs a batch it received";
    case "ServerEndsSession": return "the server ends an unread session";
    case "ServerForgetsLock": return "the lock stops excluding the old session";
    case "Finished": return null;
    default: return a;
  }
};
export const colors = { normal: "blue", recovery: "orange", stop: "pink" };
