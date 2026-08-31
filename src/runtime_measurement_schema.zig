/// The one internal v2 wire contract shared by the runtime-measurement producer
/// and its summarizer. Keep this deliberately small: there is one producer and
/// one consumer today.
pub const record_schema = "onepage.runtime-measurement.v2";

pub const Timing = struct {
    wall_ns: u64,
    cpu_ns: u64,
    operations_per_second: f64,
};

pub const ProcessSample = struct {
    resident_bytes: u64,
    physical_footprint_bytes: u64,
    lifetime_peak_physical_footprint_bytes: u64,
    virtual_bytes: u64,
    thread_count: u32,
    running_thread_count: u32,
    user_cpu_ns: u64,
    system_cpu_ns: u64,
    package_idle_wakeups: u64,
    interrupt_wakeups: u64,
    pageins: u64,
    disk_read_bytes: u64,
    disk_written_bytes: u64,
    instructions: u64,
    cycles: u64,
};

pub const Observations = struct {
    baseline: ProcessSample,
    runtime_open: ProcessSample,
    workload_complete: ProcessSample,
    runtime_closed: ProcessSample,
};

pub const ByteFootprint = struct {
    logical_file_bytes: u64 = 0,
    allocated_file_bytes: u64 = 0,
};

pub const DurableStorage = struct {
    sqlite: ByteFootprint = .{},
    sessions: ByteFootprint = .{},
    other: ByteFootprint = .{},
};

pub const SqlitePagerAccounting = struct {
    page_count: u64,
    freelist_pages: u64,
    cache_pages_written: u64,
    cache_spill_events: u64,
};

pub const SqliteMemoryCurrent = struct {
    heap_bytes: u64,
    page_cache_bytes: u64,
    lookaside_slots: u64,
    statements_bytes: u64,
};

pub const SqliteMemoryHighWater = struct {
    heap_bytes: u64,
    lookaside_slots: u64,
};

pub const SqliteMemoryObservation = struct {
    before: SqliteMemoryCurrent,
    after: SqliteMemoryCurrent,
    workload_highwater: SqliteMemoryHighWater,
};

pub const Record = struct {
    schema: []const u8,
    scenario: []const u8,
    build_mode: []const u8,
    count: u64,
    active_capacity: u64,
    activation_slot_bytes: u64,
    activation_reservation_bytes: u64,
    activation_pool_overhead_bytes: u64,
    activation_occupied_high_water_bytes: u64,
    measurement_scope: []const u8,
    timing: Timing,
    durable_storage: DurableStorage,
    sqlite_pager: struct {
        before: SqlitePagerAccounting,
        after: SqlitePagerAccounting,
    },
    sqlite_memory: SqliteMemoryObservation,
    observations: Observations,
};
