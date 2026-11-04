CREATE TABLE store_meta(
 meta_key TEXT PRIMARY KEY NOT NULL CHECK((meta_key='wire_version' OR meta_key='store_selector' OR meta_key='format')),
 meta_value TEXT NOT NULL
) STRICT;
CREATE TABLE content(
 content_id INTEGER PRIMARY KEY NOT NULL,
 digest BLOB NOT NULL CHECK(length(digest)=32),
 byte_length INTEGER NOT NULL CHECK(byte_length>=0 AND byte_length<=1073737728),
 private INTEGER NOT NULL CHECK(private IN (0,1)),
 payload BLOB NOT NULL CHECK(length(payload)=byte_length),
 UNIQUE(digest,byte_length,private)
) STRICT;
CREATE TABLE session(
 session_ref TEXT PRIMARY KEY NOT NULL CHECK(length(CAST(session_ref AS BLOB))=6 AND (session_ref NOT GLOB '*[^0123456789abcdefghjkmnpqrstvwxyz]*' AND length(session_ref)=length(CAST(session_ref AS BLOB)))),
 workspace TEXT NOT NULL CHECK(length(CAST(workspace AS BLOB)) BETWEEN 1 AND 4096),
 provider TEXT NOT NULL CHECK(length(CAST(provider AS BLOB)) BETWEEN 1 AND 16 AND provider GLOB '[a-z]*' AND (provider NOT GLOB '*[^a-z0-9_-]*' AND length(provider)=length(CAST(provider AS BLOB)))),
 codec TEXT NOT NULL CHECK(length(CAST(codec AS BLOB)) BETWEEN 3 AND 40),
 codec_options BLOB CHECK(codec_options IS NULL OR length(codec_options) BETWEEN 1 AND 512),
 prefix_seal BLOB CHECK(prefix_seal IS NULL OR length(prefix_seal)=56),
 model TEXT NOT NULL CHECK(length(CAST(model AS BLOB)) BETWEEN 1 AND 256),
 instructions_content_id INTEGER NOT NULL REFERENCES content(content_id),
 tools_mask INTEGER NOT NULL CHECK(tools_mask BETWEEN 0 AND 3),
 permission_mode INTEGER NOT NULL CHECK(permission_mode BETWEEN 0 AND 1),
 output_schema_content_id INTEGER REFERENCES content(content_id),
 revision INTEGER NOT NULL CHECK(revision>0),
 compaction_trigger INTEGER CHECK(compaction_trigger IS NULL OR compaction_trigger>0),
 output_reservation INTEGER CHECK(output_reservation IS NULL OR output_reservation>=0),
 reasoning_effort TEXT CHECK(reasoning_effort IS NULL OR (reasoning_effort='none' OR reasoning_effort='low' OR reasoning_effort='medium' OR reasoning_effort='high' OR reasoning_effort='xhigh' OR reasoning_effort='max')),
 label TEXT CHECK(label IS NULL OR length(CAST(label AS BLOB)) BETWEEN 1 AND 100),
 created_at INTEGER NOT NULL CHECK(created_at>0),
 next_position INTEGER NOT NULL CHECK(next_position>0),
 created_seq INTEGER NOT NULL UNIQUE CHECK(created_seq>0),
 workspace_digest BLOB NOT NULL CHECK(length(workspace_digest)=32),
 workspace_key INTEGER NOT NULL,
 CHECK(workspace_key>0 AND workspace_key<=created_seq)
) STRICT;
CREATE TABLE core_command(
 command_key TEXT NOT NULL UNIQUE CHECK(length(CAST(command_key AS BLOB))<=128),
 kind INTEGER NOT NULL CHECK(kind BETWEEN 1 AND 5),
 target TEXT NOT NULL CHECK(length(CAST(target AS BLOB))<=128),
 input_digest BLOB NOT NULL CHECK(length(input_digest)=32),
 primary_content_id INTEGER REFERENCES content(content_id),
 secondary_content_id INTEGER REFERENCES content(content_id),
 accepted INTEGER NOT NULL CHECK(accepted IN (0,1)),
 code TEXT NOT NULL CHECK(length(CAST(code AS BLOB))<=96),
 revision INTEGER NOT NULL CHECK(revision>=0),
 created INTEGER NOT NULL CHECK(created IN (0,1)),
 command_seq INTEGER PRIMARY KEY NOT NULL CHECK(command_seq>0)
) STRICT;
CREATE TABLE session_revision(
 session_ref TEXT NOT NULL REFERENCES session(session_ref),
 revision INTEGER NOT NULL CHECK(revision>0),
 command_key TEXT NOT NULL UNIQUE REFERENCES core_command(command_key),
 workspace TEXT NOT NULL,
 provider TEXT NOT NULL CHECK(length(CAST(provider AS BLOB)) BETWEEN 1 AND 16 AND provider GLOB '[a-z]*' AND (provider NOT GLOB '*[^a-z0-9_-]*' AND length(provider)=length(CAST(provider AS BLOB)))),
 model TEXT NOT NULL,
 instructions_content_id INTEGER NOT NULL REFERENCES content(content_id),
 instructions_updated INTEGER NOT NULL CHECK(instructions_updated IN (0,1)),
 tools_mask INTEGER NOT NULL CHECK(tools_mask BETWEEN 0 AND 3),
 permission_mode INTEGER NOT NULL CHECK(permission_mode BETWEEN 0 AND 1),
 output_schema_content_id INTEGER REFERENCES content(content_id),
 compaction_trigger INTEGER CHECK(compaction_trigger IS NULL OR compaction_trigger>0),
 output_reservation INTEGER CHECK(output_reservation IS NULL OR output_reservation>=0),
 reasoning_effort TEXT CHECK(reasoning_effort IS NULL OR (reasoning_effort='none' OR reasoning_effort='low' OR reasoning_effort='medium' OR reasoning_effort='high' OR reasoning_effort='xhigh' OR reasoning_effort='max')),
 label TEXT CHECK(label IS NULL OR length(CAST(label AS BLOB)) BETWEEN 1 AND 100),
 PRIMARY KEY(session_ref,revision)
) STRICT, WITHOUT ROWID;
CREATE TABLE message_admission(
 admission_id INTEGER PRIMARY KEY NOT NULL CHECK(admission_id>0),
 session_ref TEXT NOT NULL REFERENCES session(session_ref),
 command_key TEXT NOT NULL UNIQUE REFERENCES core_command(command_key),
 content_id INTEGER NOT NULL REFERENCES content(content_id),
 admission_position INTEGER CHECK(admission_position>0),
 turn_id INTEGER REFERENCES turn(turn_id),
 admitted_at INTEGER NOT NULL CHECK(admitted_at>0),
 sender_session_ref TEXT REFERENCES session(session_ref),
 sender_position INTEGER CHECK(sender_position>0),
 CHECK((sender_session_ref IS NULL)=(sender_position IS NULL))
) STRICT;
CREATE TABLE sent_rejection(
 command_key TEXT PRIMARY KEY NOT NULL REFERENCES core_command(command_key),
 sender_session_ref TEXT NOT NULL REFERENCES session(session_ref),
 sender_position INTEGER NOT NULL CHECK(sender_position>0),
 rejected_at INTEGER NOT NULL CHECK(rejected_at>0),
 UNIQUE(sender_session_ref,sender_position)
) STRICT, WITHOUT ROWID;
CREATE TABLE turn(
 turn_id INTEGER PRIMARY KEY NOT NULL CHECK(turn_id>0),
 session_ref TEXT NOT NULL REFERENCES session(session_ref),
 first_admission_id INTEGER NOT NULL REFERENCES message_admission(admission_id),
 input_cutoff INTEGER NOT NULL CHECK(input_cutoff>=first_admission_id),
 operation_id INTEGER NOT NULL,
 outcome_code TEXT CHECK(outcome_code IS NULL OR length(CAST(outcome_code AS BLOB)) BETWEEN 1 AND 96),
 outcome_content_id INTEGER REFERENCES content(content_id),
 outcome_position INTEGER CHECK(outcome_position>0),
 outcome_at INTEGER CHECK(outcome_at IS NULL OR outcome_at>0),
 continuation_operation_id INTEGER CHECK(continuation_operation_id IS NULL OR continuation_operation_id<=operation_id),
 CHECK((outcome_code IS NULL)=(outcome_at IS NULL))
) STRICT;
CREATE TABLE session_stop(
 command_key TEXT PRIMARY KEY NOT NULL REFERENCES core_command(command_key),
 session_ref TEXT NOT NULL REFERENCES session(session_ref),
 selected_turn_id INTEGER REFERENCES turn(turn_id),
 position INTEGER CHECK(position>0),
 admission_cutoff INTEGER NOT NULL CHECK(admission_cutoff>=0),
 stopped_at INTEGER NOT NULL CHECK(stopped_at>0)
) STRICT, WITHOUT ROWID;
CREATE TABLE model_interruption_command(
 command_key TEXT PRIMARY KEY NOT NULL REFERENCES core_command(command_key),
 session_ref TEXT NOT NULL CHECK(length(CAST(session_ref AS BLOB))<=128),
 turn_id TEXT NOT NULL CHECK(length(CAST(turn_id AS BLOB)) BETWEEN 1 AND 20 AND (turn_id NOT GLOB '*[^0-9]*' AND length(turn_id)=length(CAST(turn_id AS BLOB)))),
 operation_id TEXT NOT NULL CHECK(length(CAST(operation_id AS BLOB)) BETWEEN 1 AND 20 AND (operation_id NOT GLOB '*[^0-9]*' AND length(operation_id)=length(CAST(operation_id AS BLOB))))
) STRICT, WITHOUT ROWID;
CREATE TABLE model_operation(
 operation_id INTEGER PRIMARY KEY NOT NULL CHECK(operation_id>0),
 turn_id INTEGER NOT NULL REFERENCES turn(turn_id),
 session_ref TEXT NOT NULL,
 settings_revision INTEGER NOT NULL CHECK(settings_revision>0),
 input_cutoff INTEGER NOT NULL CHECK(input_cutoff>0),
 admission_position INTEGER NOT NULL CHECK(admission_position>0),
 purpose INTEGER NOT NULL DEFAULT 0 CHECK(purpose IN (0,1)),
 compaction_trigger INTEGER CHECK(compaction_trigger IS NULL OR compaction_trigger>0),
 output_reservation INTEGER NOT NULL CHECK(output_reservation>=0),
 reasoning_effort TEXT CHECK(reasoning_effort IS NULL OR (reasoning_effort='none' OR reasoning_effort='low' OR reasoning_effort='medium' OR reasoning_effort='high' OR reasoning_effort='xhigh' OR reasoning_effort='max')),
 output_item_count INTEGER CHECK(output_item_count IS NULL OR output_item_count>=0),
 attempt_ordinal INTEGER NOT NULL CHECK(attempt_ordinal BETWEEN 1 AND 4),
 auth_refresh_claimed INTEGER NOT NULL DEFAULT 0 CHECK(auth_refresh_claimed IN (0,1)),
 retry_due_at_ms INTEGER CHECK(retry_due_at_ms IS NULL OR retry_due_at_ms>=0),
 last_failure_code TEXT CHECK(last_failure_code IS NULL OR length(CAST(last_failure_code AS BLOB)) BETWEEN 1 AND 96),
 resolution_code TEXT CHECK(resolution_code IS NULL OR length(CAST(resolution_code AS BLOB)) BETWEEN 1 AND 96),
 resolution_content_id INTEGER REFERENCES content(content_id),
 response_id TEXT CHECK(response_id IS NULL OR length(CAST(response_id AS BLOB))<=256),
 model_evidence BLOB CHECK(model_evidence IS NULL OR length(model_evidence) BETWEEN 7 AND 775),
 request_id TEXT CHECK(request_id IS NULL OR length(CAST(request_id AS BLOB))<=256),
 usage_content_id INTEGER REFERENCES content(content_id),
 usage_uncached_tokens INTEGER CHECK(usage_uncached_tokens IS NULL OR usage_uncached_tokens>=0),
 usage_cache_read_tokens INTEGER CHECK(usage_cache_read_tokens IS NULL OR usage_cache_read_tokens>=0),
 usage_cache_write_tokens INTEGER CHECK(usage_cache_write_tokens IS NULL OR usage_cache_write_tokens>=0),
 usage_output_tokens INTEGER CHECK(usage_output_tokens IS NULL OR usage_output_tokens>=0),
 interrupted_by_command_key TEXT REFERENCES core_command(command_key),
 attempt_at INTEGER CHECK(attempt_at IS NULL OR attempt_at>0),
 retry_scheduled_at INTEGER CHECK(retry_scheduled_at IS NULL OR retry_scheduled_at>0),
 resolved_at INTEGER CHECK(resolved_at IS NULL OR resolved_at>0),
 UNIQUE(operation_id,session_ref),
 FOREIGN KEY(session_ref,settings_revision) REFERENCES session_revision(session_ref,revision),
 CHECK((usage_uncached_tokens IS NULL AND usage_cache_read_tokens IS NULL AND usage_cache_write_tokens IS NULL AND usage_output_tokens IS NULL) OR (usage_uncached_tokens IS NOT NULL AND usage_cache_read_tokens IS NOT NULL AND usage_cache_write_tokens IS NOT NULL AND usage_output_tokens IS NOT NULL AND usage_content_id IS NOT NULL)),
 CHECK((resolution_code IS NULL AND retry_due_at_ms IS NOT NULL) OR (resolution_code IS NOT NULL AND retry_due_at_ms IS NULL)),
 CHECK((resolution_code IS NULL AND retry_due_at_ms=0 AND attempt_at IS NOT NULL AND retry_scheduled_at IS NULL AND resolved_at IS NULL) OR (resolution_code IS NULL AND retry_due_at_ms>0 AND attempt_at IS NULL AND retry_scheduled_at IS NOT NULL AND resolved_at IS NULL) OR (resolution_code IS NOT NULL AND attempt_at IS NULL AND retry_scheduled_at IS NULL AND resolved_at IS NOT NULL)),
 CHECK(((resolution_code IS 'interrupted') AND interrupted_by_command_key IS NOT NULL) OR (coalesce(resolution_code,'')!='interrupted' AND interrupted_by_command_key IS NULL))
) STRICT;
CREATE TABLE conversation_entry(
 session_ref TEXT NOT NULL,
 entry_ordinal INTEGER NOT NULL CHECK(entry_ordinal>0),
 session_position INTEGER NOT NULL CHECK(session_position>0),
 entry_kind INTEGER NOT NULL CHECK(entry_kind BETWEEN 1 AND 3),
 turn_id INTEGER NOT NULL REFERENCES turn(turn_id),
 source_admission_id INTEGER UNIQUE REFERENCES message_admission(admission_id),
 source_revision INTEGER,
 source_operation_id INTEGER REFERENCES model_operation(operation_id),
 source_item_ordinal INTEGER CHECK(source_item_ordinal IS NULL OR source_item_ordinal>=0),
 content_id INTEGER NOT NULL REFERENCES content(content_id),
 recorded_at INTEGER NOT NULL CHECK(recorded_at>0),
 PRIMARY KEY(session_ref,entry_ordinal),
 UNIQUE(session_ref,session_position),
 UNIQUE(session_ref,source_revision),
 FOREIGN KEY(session_ref,source_revision) REFERENCES session_revision(session_ref,revision),
 FOREIGN KEY(source_operation_id,source_item_ordinal) REFERENCES model_output_item(operation_id,item_ordinal),
 CHECK((entry_kind=3)=(source_item_ordinal IS NOT NULL)),
 CHECK((entry_kind=1 AND source_admission_id IS NOT NULL AND source_revision IS NULL AND source_operation_id IS NULL) OR (entry_kind=2 AND source_admission_id IS NULL AND source_revision IS NOT NULL AND source_operation_id IS NULL) OR (entry_kind=3 AND source_admission_id IS NULL AND source_revision IS NULL AND source_operation_id IS NOT NULL))
) STRICT, WITHOUT ROWID;
CREATE TABLE model_output_item(
 operation_id INTEGER NOT NULL REFERENCES model_operation(operation_id),
 item_ordinal INTEGER NOT NULL CHECK(item_ordinal>=0),
 session_ref TEXT NOT NULL,
 session_position INTEGER NOT NULL CHECK(session_position>0),
 item_kind INTEGER NOT NULL CHECK(item_kind BETWEEN 1 AND 5),
 message_content_id INTEGER REFERENCES content(content_id) CHECK((message_content_id IS NOT NULL)=(item_kind=2)),
 attempt_ordinal INTEGER NOT NULL CHECK(attempt_ordinal>0),
 item_id_digest BLOB NOT NULL CHECK(length(item_id_digest)=32),
 replay_omits_reasoning_text INTEGER NOT NULL CHECK(replay_omits_reasoning_text IN (0,1) AND (replay_omits_reasoning_text=0 OR item_kind=1)),
 phase INTEGER NOT NULL DEFAULT 0 CHECK(phase IN (0,1,2) AND (phase=0 OR item_kind=2)),
 extras_content_id INTEGER NOT NULL REFERENCES content(content_id),
 part_count INTEGER NOT NULL CHECK(part_count>=0 AND (part_count=0 OR item_kind IN (1,2))),
 description TEXT CHECK(description IS NULL OR (length(CAST(description AS BLOB)) BETWEEN 1 AND 100 AND (description IS NOT NULL)=(item_kind=5))),
 call_failed INTEGER NOT NULL DEFAULT 0 CHECK(call_failed IN (0,1) AND (call_failed=0 OR item_kind=5)),
 PRIMARY KEY(operation_id,item_ordinal),
 UNIQUE(session_ref,session_position),
 UNIQUE(operation_id,item_id_digest)
) STRICT, WITHOUT ROWID;
CREATE TABLE model_output_part(
 operation_id INTEGER NOT NULL,
 item_ordinal INTEGER NOT NULL,
 part_ordinal INTEGER NOT NULL CHECK(part_ordinal>=0),
 part_array INTEGER NOT NULL CHECK(part_array IN (1,2)),
 part_kind INTEGER NOT NULL CHECK(part_kind=0 OR (part_kind IN (1,2,4) AND part_array=1) OR (part_kind=3 AND part_array=2)),
 text_length INTEGER CHECK(text_length IS NULL OR text_length>=0),
 text_content_id INTEGER REFERENCES content(content_id),
 extras_content_id INTEGER NOT NULL REFERENCES content(content_id),
 PRIMARY KEY(operation_id,item_ordinal,part_ordinal),
 CHECK((text_length IS NOT NULL)=(part_kind IN (1,2)) AND (text_content_id IS NOT NULL)=(part_kind IN (3,4)))
) STRICT, WITHOUT ROWID;
CREATE TABLE model_tool_call(
 operation_id INTEGER NOT NULL REFERENCES model_operation(operation_id),
 session_ref TEXT NOT NULL,
 call_ordinal INTEGER NOT NULL CHECK(call_ordinal>=0),
 item_ordinal INTEGER NOT NULL CHECK(item_ordinal>=0),
 name_content_id INTEGER NOT NULL REFERENCES content(content_id),
 call_id_content_id INTEGER NOT NULL REFERENCES content(content_id),
 arguments_content_id INTEGER NOT NULL REFERENCES content(content_id),
 description TEXT CHECK(description IS NULL OR length(CAST(description AS BLOB)) BETWEEN 1 AND 100),
 field_metadata BLOB NOT NULL CHECK(length(field_metadata)=120),
 rejection_code TEXT CHECK(rejection_code IS NULL OR rejection_code IN ('unknown_tool','invalid_arguments')),
 rejection_content_id INTEGER REFERENCES content(content_id),
 acceptance_position INTEGER CHECK(acceptance_position IS NULL OR acceptance_position>0),
 action_kind INTEGER CHECK(action_kind IS NULL OR action_kind=1),
 PRIMARY KEY(operation_id,call_ordinal),
 UNIQUE(operation_id,item_ordinal),
 UNIQUE(operation_id,call_id_content_id),
 UNIQUE(operation_id,call_ordinal,action_kind),
 FOREIGN KEY(operation_id,session_ref) REFERENCES model_operation(operation_id,session_ref),
 CHECK((rejection_code IS NULL AND rejection_content_id IS NULL AND acceptance_position IS NULL AND (action_kind IS 1)) OR (rejection_code IS NOT NULL AND rejection_content_id IS NOT NULL AND acceptance_position IS NOT NULL AND action_kind IS NULL))
) STRICT, WITHOUT ROWID;
CREATE TABLE action_operation(
 action_id INTEGER PRIMARY KEY NOT NULL CHECK(action_id>0),
 parent_operation_id INTEGER NOT NULL REFERENCES model_operation(operation_id),
 call_ordinal INTEGER NOT NULL CHECK(call_ordinal>=0),
 session_ref TEXT NOT NULL REFERENCES session(session_ref),
 tool_kind INTEGER NOT NULL CHECK(tool_kind=1),
 permission_revision INTEGER NOT NULL CHECK(permission_revision>0),
 authorized INTEGER NOT NULL CHECK(authorized IN (0,1)),
 attempt_ordinal INTEGER NOT NULL DEFAULT 0 CHECK(attempt_ordinal IN (0,1)),
 bash_timeout_override_ms INTEGER CHECK(bash_timeout_override_ms IS NULL OR bash_timeout_override_ms>0),
 bash_timeout_ms INTEGER CHECK(bash_timeout_ms IS NULL OR bash_timeout_ms>0),
 sender_handle TEXT CHECK(sender_handle IS NULL OR (length(CAST(sender_handle AS BLOB))=32 AND (sender_handle NOT GLOB '*[^0-9a-f]*' AND length(sender_handle)=length(CAST(sender_handle AS BLOB))))),
 resolution_code TEXT CHECK(resolution_code IS NULL OR (resolution_code='denied' OR resolution_code='cancelled' OR resolution_code='succeeded' OR resolution_code='failed' OR resolution_code='timed_out' OR resolution_code='indeterminate' OR resolution_code='storage_failed' OR resolution_code='spawn_failed' OR resolution_code='infrastructure_shutdown')),
 resolution_content_id INTEGER REFERENCES content(content_id),
 acceptance_position INTEGER CHECK(acceptance_position IS NULL OR acceptance_position>0),
 attempt_at INTEGER CHECK(attempt_at IS NULL OR attempt_at>0),
 decided_at INTEGER CHECK(decided_at IS NULL OR decided_at>0),
 resolved_at INTEGER CHECK(resolved_at IS NULL OR resolved_at>0),
 UNIQUE(parent_operation_id,call_ordinal),
 FOREIGN KEY(parent_operation_id,session_ref) REFERENCES model_operation(operation_id,session_ref),
 FOREIGN KEY(parent_operation_id,call_ordinal,tool_kind) REFERENCES model_tool_call(operation_id,call_ordinal,action_kind),
 FOREIGN KEY(session_ref,permission_revision) REFERENCES session_revision(session_ref,revision),
 CHECK((resolution_code IS NOT 'denied') OR (authorized=0 AND attempt_ordinal=0)),
 CHECK((attempt_ordinal=0 AND bash_timeout_ms IS NULL) OR (attempt_ordinal=1 AND bash_timeout_ms IS NOT NULL)),
 CHECK((resolution_code IS NULL AND resolution_content_id IS NULL AND acceptance_position IS NULL) OR (resolution_code IS NOT NULL AND resolution_content_id IS NOT NULL AND acceptance_position IS NOT NULL)),
 CHECK((attempt_ordinal=1)=(attempt_at IS NOT NULL)),
 CHECK((authorized=1)=(decided_at IS NOT NULL)),
 CHECK((resolution_code IS NULL)=(resolved_at IS NULL))
) STRICT;
CREATE TABLE permission_decision_command(
 command_key TEXT PRIMARY KEY NOT NULL REFERENCES core_command(command_key),
 action_id TEXT NOT NULL CHECK(length(CAST(action_id AS BLOB)) BETWEEN 1 AND 20 AND (action_id NOT GLOB '*[^0-9]*' AND length(action_id)=length(CAST(action_id AS BLOB)))),
 decision TEXT NOT NULL CHECK(decision IN ('allow_once','deny'))
) STRICT, WITHOUT ROWID;
CREATE INDEX session_workspace_list ON session(workspace_digest,created_seq);
CREATE UNIQUE INDEX message_admission_sent ON message_admission(sender_session_ref,sender_position) WHERE sender_session_ref IS NOT NULL;
CREATE UNIQUE INDEX turn_one_active_per_session ON turn(session_ref) WHERE outcome_code IS NULL;
CREATE INDEX turn_tool_continuation ON turn(operation_id) WHERE outcome_code IS NULL AND continuation_operation_id=operation_id;
CREATE INDEX message_admission_session_order ON message_admission(session_ref,turn_id,admission_id);
CREATE INDEX message_admission_pending ON message_admission(admission_id,session_ref) WHERE turn_id IS NULL;
CREATE INDEX message_admission_session_pending ON message_admission(session_ref,admission_id) WHERE turn_id IS NULL;
CREATE INDEX message_admission_person ON message_admission(session_ref,admission_position) WHERE sender_session_ref IS NULL;
CREATE INDEX message_admission_unpositioned ON message_admission(session_ref) WHERE admission_position IS NULL;
CREATE INDEX message_admission_position ON message_admission(session_ref,admission_position);
CREATE INDEX core_command_target_order ON core_command(target,kind,command_seq);
CREATE INDEX session_revision_instructions ON session_revision(session_ref,instructions_content_id);
CREATE INDEX session_revision_output_schema ON session_revision(session_ref,output_schema_content_id);
CREATE INDEX session_stop_exclusion ON session_stop(session_ref,admission_cutoff,position);
CREATE INDEX session_stop_unpositioned ON session_stop(session_ref) WHERE position IS NULL;
CREATE INDEX session_stop_position ON session_stop(session_ref,position);
CREATE INDEX session_stop_turn ON session_stop(selected_turn_id);
CREATE INDEX action_operation_session_order ON action_operation(session_ref,action_id);
CREATE UNIQUE INDEX action_operation_sender_handle ON action_operation(sender_handle) WHERE sender_handle IS NOT NULL;
CREATE INDEX action_operation_acceptance ON action_operation(session_ref,acceptance_position);
CREATE INDEX action_operation_session_results ON action_operation(session_ref,parent_operation_id,acceptance_position) WHERE acceptance_position IS NOT NULL;
CREATE INDEX action_operation_executable ON action_operation(action_id) WHERE authorized=1 AND resolution_code IS NULL AND attempt_ordinal=0;
CREATE INDEX action_operation_unresolved_attempt ON action_operation(action_id) WHERE resolution_code IS NULL AND attempt_ordinal=1;
CREATE INDEX model_tool_call_session_order ON model_tool_call(session_ref,operation_id,call_ordinal);
CREATE INDEX model_tool_call_session_results ON model_tool_call(session_ref,operation_id,acceptance_position) WHERE acceptance_position IS NOT NULL;
CREATE INDEX model_tool_call_acceptance ON model_tool_call(session_ref,acceptance_position) WHERE acceptance_position IS NOT NULL;
CREATE INDEX model_operation_retry_due ON model_operation(retry_due_at_ms,operation_id) WHERE resolution_code IS NULL AND attempt_ordinal<4;
CREATE INDEX model_operation_retry_exhausted ON model_operation(operation_id) WHERE resolution_code IS NULL AND retry_due_at_ms=0 AND attempt_ordinal=4;
CREATE INDEX model_operation_session_history ON model_operation(session_ref,operation_id);
CREATE INDEX model_operation_turn_history ON model_operation(turn_id,operation_id);
CREATE INDEX model_operation_context_history ON model_operation(session_ref,admission_position) WHERE (resolution_code='answer' OR resolution_code='compacted' OR resolution_code='tool_proposals');
CREATE INDEX model_operation_compaction_bases ON model_operation(session_ref,admission_position) WHERE purpose=1 AND resolution_code='compacted';
CREATE INDEX conversation_entry_history ON conversation_entry(session_ref,session_position);
CREATE INDEX model_output_history ON model_output_item(session_ref,session_position);
CREATE INDEX model_output_call_history ON model_output_item(session_ref,session_position) WHERE item_kind=3;
CREATE INDEX model_output_hosted_history ON model_output_item(session_ref,session_position) WHERE item_kind=5;
CREATE INDEX model_output_compaction_anchor ON model_output_item(operation_id,item_ordinal) WHERE item_kind=4;
CREATE INDEX turn_session_latest ON turn(session_ref,turn_id DESC);
CREATE INDEX turn_unpositioned ON turn(session_ref) WHERE (outcome_code IS NULL)!=(outcome_position IS NULL);
CREATE INDEX turn_outcome_position ON turn(session_ref,outcome_position);
