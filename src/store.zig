//! The Store's public surface. The Store itself lives in src/store/; code
//! outside that directory imports this file, never a file under it.

const action_domain = @import("store/domain/action.zig");
const command_domain = @import("store/domain/command.zig");
const configuration_domain = @import("store/domain/configuration.zig");
const content_domain = @import("store/domain/content.zig");
const historical_domain = @import("store/domain/historical.zig");
const model_admission_domain = @import("store/domain/model_admission.zig");
const model_settlement_domain = @import("store/domain/model_settlement.zig");
const reads_domain = @import("store/domain/reads.zig");
const report_domain = @import("store/domain/report.zig");
const store_core = @import("store/Store.zig");
const store_schema = @import("store/schema.zig");
const store_testing = @import("store/testing.zig");

pub const Store = store_core.Store;
pub const AcceptedMessageQueue = reads_domain.AcceptedMessageQueue;
pub const ActionAttemptBinding = action_domain.ActionAttemptBinding;
pub const AgentDelivery = command_domain.AgentDelivery;
pub const CoreActionInput = action_domain.CoreActionInput;
pub const ActionDispatchPermit = action_domain.ActionDispatchPermit;
pub const ActionResolutionCode = action_domain.ActionResolutionCode;
pub const ActiveOperationFilter = action_domain.ActiveOperationFilter;
pub const application_id = store_schema.application_id;
pub const AttemptBinding = store_core.AttemptBinding;
pub const BashExecutionInput = action_domain.BashExecutionInput;
pub const CommandObservation = command_domain.CommandObservation;
pub const ConfigureReply = configuration_domain.ConfigureReply;
pub const ContentLocation = content_domain.ContentLocation;
pub const ContentReader = content_domain.ContentReader;
pub const ContentReference = content_domain.ContentReference;
pub const ControlTrace = store_core.ControlTrace;
pub const ControlTracePhase = store_core.ControlTracePhase;
pub const DispatchPermit = model_admission_domain.DispatchPermit;
pub const Faults = store_core.Faults;
pub const HistoricalContent = historical_domain.HistoricalContent;
pub const HistoricalReader = historical_domain.HistoricalReader;
pub const HistoricalSettings = historical_domain.HistoricalSettings;
pub const HistoricalTool = historical_domain.HistoricalTool;
pub const Declaration = historical_domain.Declaration;
pub const HistoricalView = historical_domain.HistoricalView;
pub const MessageReply = command_domain.MessageReply;
pub const ModelAdmissionKind = model_admission_domain.ModelAdmissionKind;
pub const ModelFailure = model_settlement_domain.ModelFailure;
pub const ModelFailureClass = model_settlement_domain.ModelFailureClass;
pub const ModelInterruptionReply = command_domain.ModelInterruptionReply;
pub const ModelInterruptionTarget = command_domain.ModelInterruptionTarget;
pub const OpenOptions = store_core.OpenOptions;
pub const PermissionDecisionReply = command_domain.PermissionDecisionReply;
pub const PrefixSeal = historical_domain.PrefixSeal;
pub const PublicConversationPage = reads_domain.PublicConversationPage;
pub const schema_version = store_schema.schema_version;
pub const SessionReport = report_domain.SessionReport;
pub const SessionReportExecution = report_domain.SessionReportExecution;
pub const SessionStopReply = command_domain.SessionStopReply;
pub const settleCompactionForTesting = store_testing.settleCompactionForTesting;
pub const setHistoryFloorForTesting = store_testing.setHistoryFloorForTesting;
pub const settleAnswerItemsForTesting = store_testing.settleItemsForTesting;
pub const turnEndedForTesting = store_testing.turnEndedForTesting;
pub const SettlementTrace = store_core.SettlementTrace;
pub const SettlementTracePhase = store_core.SettlementTracePhase;
pub const testingPublicProjection = store_testing.testingPublicProjection;
pub const ValidatedOutput = model_settlement_domain.ValidatedOutput;

test {
    _ = @import("store/domain/history_floor.zig");
    _ = @import("store/tests.zig");
    _ = @import("store/sqlite_tests.zig");
    _ = @import("store/mysql_dialect_check.zig");
}
