const std = @import("std");
const product = @import("product.zig");
const CiArtifacts = @import("ci.zig").CiArtifacts;

pub fn addCheck(b: *std.Build, ci: CiArtifacts, target: std.Build.ResolvedTarget, release_safe: *std.Build.Step.Compile) *std.Build.Step.Compile {
    const measurement_tests = b.addSystemCommand(&.{
        "go", "test", "-count=1", "-mod=readonly", "./...",
    });
    measurement_tests.setCwd(b.path("tests/qualification"));
    measurement_tests.setEnvironmentVariable("GOTOOLCHAIN", "local");
    const measurement_test_step = b.step(
        "measurement-check",
        "Compile and test the pinned Go measurement packages",
    );
    measurement_test_step.dependOn(&measurement_tests.step);

    const queue_audit_test = b.addSystemCommand(&.{
        "go", "test", "-count=1", "-mod=readonly", "-run", "^Test(ExecutionAuditQueryRejectsHiddenEntities|PopulateFreezesSessionOffer)$", "./model-queue", "-args", "-sqlite",
    });
    queue_audit_test.setCwd(b.path("tests/qualification"));
    queue_audit_test.setEnvironmentVariable("GOTOOLCHAIN", "local");
    const sqlite_shell = product.addSqliteShell(b, target, .ReleaseSmall);
    queue_audit_test.addFileArg(ci.path(sqlite_shell));
    measurement_test_step.dependOn(&queue_audit_test.step);

    // The runners' configure call against the current CLI and Host, so a change
    // to either fails here rather than in the next measurement campaign.
    const configure_contract = b.addSystemCommand(&.{"python3"});
    configure_contract.addFileArg(b.path("tests/integration/host_process.py"));
    configure_contract.addArgs(&.{ "exec", "env", "GOTOOLCHAIN=local", "go", "test", "-count=1", "-mod=readonly", "-run", "^TestConfigureContract$", "./measurement", "-args", "-rui" });
    configure_contract.setCwd(b.path("tests/qualification"));
    configure_contract.addFileArg(ci.path(release_safe));
    measurement_test_step.dependOn(&configure_contract.step);

    return sqlite_shell;
}

pub fn add(b: *std.Build, ci: CiArtifacts, release_safe: *std.Build.Step.Compile, sqlite_shell: *std.Build.Step.Compile, model_queue_output: ?[]const u8) void {
    const measure = addMeasurement(b, &.{"./configuration-admission"});
    measure.addFileArg(ci.path(release_safe));
    const measure_step = b.step(
        "measure-admission",
        "Measure macOS Host and direct-client memory for configuration admission",
    );
    measure_step.dependOn(&measure.step);

    const measure_messages = addMeasurement(b, &.{"./message-admission"});
    measure_messages.addFileArg(ci.path(release_safe));
    const measure_messages_step = b.step(
        "measure-message-admission",
        "Measure macOS message admission and observation scaling",
    );
    measure_messages_step.dependOn(&measure_messages.step);

    const measure_dispatch = addMeasurement(b, &.{"./model-dispatch"});
    measure_dispatch.addFileArg(ci.path(release_safe));
    const measure_dispatch_step = b.step(
        "measure-model-dispatch",
        "Measure macOS frozen-request transport, scratch, descriptors, and custody",
    );
    measure_dispatch_step.dependOn(&measure_dispatch.step);

    const measure_output = addMeasurement(b, &.{"./model-output"});
    measure_output.addPassthruArgs();
    measure_output.addFileArg(ci.path(release_safe));
    const measure_output_step = b.step(
        "measure-model-output",
        "Measure macOS model-output bytes, item counts, storage, and retained memory",
    );
    measure_output_step.dependOn(&measure_output.step);

    const measure_repeat_work = addMeasurement(b, &.{ "./model-output", "--repeat-work" });
    measure_repeat_work.addFileArg(ci.path(release_safe));
    const measure_repeat_work_step = b.step(
        "measure-repeat-work",
        "Measure 20 same-Host waves across 100 stable Sessions with growing history",
    );
    measure_repeat_work_step.dependOn(&measure_repeat_work.step);

    const measure_retry = addMeasurement(b, &.{"./model-retry"});
    measure_retry.addFileArg(ci.path(release_safe));
    const measure_retry_step = b.step(
        "measure-model-retry",
        "Measure macOS retry discovery, launch separation, churn, and custody",
    );
    measure_retry_step.dependOn(&measure_retry.step);

    const measure_queue = addMeasurement(b, &.{"./model-queue"});
    if (model_queue_output) |output| {
        measure_queue.addArgs(&.{ "-output", output });
    }
    measure_queue.addFileArg(ci.path(release_safe));
    measure_queue.addFileArg(ci.path(sqlite_shell));
    const measure_queue_step = b.step(
        "measure-model-queue",
        "Measure model queue discovery, ordering, settlement, and portable mixed resources",
    );
    measure_queue_step.dependOn(&measure_queue.step);

    const measure_control = addMeasurement(b, &.{"./model-control"});
    measure_control.addFileArg(ci.path(release_safe));
    const measure_control_step = b.step(
        "measure-model-control",
        "Measure control headroom, acknowledgment latency, and cleanup resources",
    );
    measure_control_step.dependOn(&measure_control.step);

    const measure_call_classification = addMeasurement(b, &.{"./call-classification"});
    measure_call_classification.addPassthruArgs();
    measure_call_classification.addFileArg(ci.path(release_safe));
    measure_call_classification.addFileArg(ci.path(sqlite_shell));
    const measure_call_classification_step = b.step(
        "measure-call-classification",
        "Measure production call classification, exact denial, recovery, and population scaling",
    );
    measure_call_classification_step.dependOn(&measure_call_classification.step);

    const measure_execution_service = addMeasurement(b, &.{"./execution-service"});
    measure_execution_service.addPassthruArgs();
    measure_execution_service.addFileArg(ci.path(release_safe));
    const measure_execution_service_step = b.step(
        "measure-execution-service",
        "Measure production execution service across completions, history, replay fields, and owner populations",
    );
    measure_execution_service_step.dependOn(&measure_execution_service.step);
}

// A Go measurement launches Rui, so it enters the fixture boundary like every
// fixture: root is refused and the environment is built there.
fn addMeasurement(b: *std.Build, arguments: []const []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{"python3"});
    run.addFileArg(b.path("tests/integration/host_process.py"));
    run.addArgs(&.{ "exec", "env", "GOTOOLCHAIN=local", "go", "run", "-mod=readonly" });
    run.addArgs(arguments);
    run.setCwd(b.path("tests/qualification"));
    return run;
}
