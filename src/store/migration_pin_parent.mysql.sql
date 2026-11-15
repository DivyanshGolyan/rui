CREATE TABLE store_meta(
 meta_key VARCHAR(14) NOT NULL,
 meta_value LONGTEXT NOT NULL,
 PRIMARY KEY(meta_key),
 CHECK((meta_key='wire_version' OR meta_key='store_selector' OR meta_key='format' OR meta_key='store_id'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE store_owner(
 owner_key BIGINT NOT NULL,
 epoch BIGINT NOT NULL,
 commit_seq BIGINT NOT NULL,
 PRIMARY KEY(owner_key),
 CHECK(owner_key=1),
 CHECK(epoch>=0),
 CHECK(commit_seq>=0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE content(
 content_id BIGINT NOT NULL,
 digest VARBINARY(32) NOT NULL,
 byte_length BIGINT NOT NULL,
 private TINYINT NOT NULL,
 PRIMARY KEY(content_id),
 UNIQUE(digest,byte_length,private),
 CHECK(length(digest)=32),
 CHECK(byte_length>=0 AND byte_length<=1073737728),
 CHECK(private IN (0,1))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE content_chunk(
 content_id BIGINT NOT NULL,
 chunk_index BIGINT NOT NULL,
 bytes LONGBLOB NOT NULL,
 PRIMARY KEY(content_id,chunk_index),
 FOREIGN KEY(content_id) REFERENCES content(content_id),
 CHECK(chunk_index>=0),
 CHECK(length(bytes) BETWEEN 1 AND 131072)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE tool_record(
 tool_record_id BIGINT NOT NULL,
 name VARCHAR(64) NOT NULL,
 owner VARCHAR(8) NOT NULL,
 server VARCHAR(64) NOT NULL,
 read_only TINYINT NOT NULL DEFAULT 0,
 description_content_id BIGINT NOT NULL,
 input_schema_content_id BIGINT NOT NULL,
 PRIMARY KEY(tool_record_id),
 UNIQUE(name,owner,server,read_only,description_content_id,input_schema_content_id),
 FOREIGN KEY(description_content_id) REFERENCES content(content_id),
 FOREIGN KEY(input_schema_content_id) REFERENCES content(content_id),
 CHECK(tool_record_id>0),
 CHECK(OCTET_LENGTH(name) BETWEEN 1 AND 64 AND (NOT REGEXP_LIKE(name,'[^A-Za-z0-9_-]','c'))),
 CHECK((owner='rui' OR owner='provider' OR owner='mcp')),
 CHECK(OCTET_LENGTH(server)<=64 AND (NOT REGEXP_LIKE(server,'[^A-Za-z0-9_-]','c')) AND (owner='mcp' AND OCTET_LENGTH(server)>0 OR owner<>'mcp' AND OCTET_LENGTH(server)=0)),
 CHECK(read_only IN (0,1) AND (read_only=0 OR owner='mcp'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE tool_set(
 tool_set_id BIGINT NOT NULL,
 digest VARBINARY(32) NOT NULL,
 member_count BIGINT NOT NULL,
 PRIMARY KEY(tool_set_id),
 UNIQUE(digest),
 CHECK(tool_set_id>0),
 CHECK(length(digest)=32),
 CHECK(member_count BETWEEN 0 AND 1024)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE tool_set_member(
 tool_set_id BIGINT NOT NULL,
 ordinal BIGINT NOT NULL,
 tool_record_id BIGINT NOT NULL,
 PRIMARY KEY(tool_set_id,ordinal),
 FOREIGN KEY(tool_set_id) REFERENCES tool_set(tool_set_id),
 FOREIGN KEY(tool_record_id) REFERENCES tool_record(tool_record_id),
 CHECK(ordinal>=0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE host_tool_set(
 slot BIGINT NOT NULL,
 tool_set_id BIGINT NOT NULL,
 PRIMARY KEY(slot),
 FOREIGN KEY(tool_set_id) REFERENCES tool_set(tool_set_id),
 CHECK(slot=1)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE model_fact(
 model_id VARCHAR(256) NOT NULL,
 context_window BIGINT,
 efforts BIGINT NOT NULL,
 openai_listed TINYINT NOT NULL,
 generation BIGINT NOT NULL,
 PRIMARY KEY(model_id),
 CHECK(OCTET_LENGTH(model_id) BETWEEN 1 AND 256),
 CHECK(efforts BETWEEN 0 AND 63),
 CHECK(openai_listed IN (0,1))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE model_catalog_source(
 slot BIGINT NOT NULL,
 etag TEXT,
 generation BIGINT NOT NULL,
 fetched_at BIGINT NOT NULL,
 PRIMARY KEY(slot),
 CHECK(slot=1),
 CHECK(etag IS NULL OR OCTET_LENGTH(etag)<=512)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE session(
 session_ref VARCHAR(6) NOT NULL,
 workspace TEXT NOT NULL,
 provider TEXT NOT NULL,
 codec TEXT NOT NULL,
 codec_options BLOB,
 prefix_seal BLOB,
 model TEXT NOT NULL,
 instructions_content_id BIGINT NOT NULL,
 tool_set_id BIGINT NOT NULL,
 loaded_tool_set_id BIGINT,
 permission_mode BIGINT NOT NULL,
 output_schema_content_id BIGINT,
 revision BIGINT NOT NULL,
 compaction_trigger BIGINT,
 output_reservation BIGINT,
 reasoning_effort VARCHAR(6),
 label TEXT,
 created_at BIGINT NOT NULL,
 next_position BIGINT NOT NULL,
 created_seq BIGINT NOT NULL,
 workspace_digest VARBINARY(32) NOT NULL,
 workspace_key BIGINT NOT NULL,
 parent_ref VARCHAR(6),
 obligation_since BIGINT,
 session_obligation_parent_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN obligation_since IS NOT NULL THEN parent_ref END) STORED,
 session_parent_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN parent_ref IS NOT NULL THEN parent_ref END) STORED,
 PRIMARY KEY(session_ref),
 UNIQUE(created_seq),
 FOREIGN KEY(instructions_content_id) REFERENCES content(content_id),
 FOREIGN KEY(tool_set_id) REFERENCES tool_set(tool_set_id),
 FOREIGN KEY(loaded_tool_set_id) REFERENCES tool_set(tool_set_id),
 FOREIGN KEY(output_schema_content_id) REFERENCES content(content_id),
 FOREIGN KEY(parent_ref) REFERENCES session(session_ref),
 CHECK(OCTET_LENGTH(session_ref)=6 AND (NOT REGEXP_LIKE(session_ref,'[^0123456789abcdefghjkmnpqrstvwxyz]','c'))),
 CHECK(OCTET_LENGTH(workspace) BETWEEN 1 AND 4096),
 CHECK(OCTET_LENGTH(provider) BETWEEN 1 AND 16 AND REGEXP_LIKE(provider,'^[a-z]','c') AND (NOT REGEXP_LIKE(provider,'[^a-z0-9_-]','c'))),
 CHECK(OCTET_LENGTH(codec) BETWEEN 3 AND 40),
 CHECK(codec_options IS NULL OR length(codec_options) BETWEEN 1 AND 512),
 CHECK(prefix_seal IS NULL OR length(prefix_seal)=56),
 CHECK(OCTET_LENGTH(model) BETWEEN 1 AND 256),
 CHECK(tool_set_id>0),
 CHECK(permission_mode BETWEEN 0 AND 1),
 CHECK(revision>0),
 CHECK(compaction_trigger IS NULL OR compaction_trigger>0),
 CHECK(output_reservation IS NULL OR output_reservation>=0),
 CHECK(reasoning_effort IS NULL OR (reasoning_effort='none' OR reasoning_effort='low' OR reasoning_effort='medium' OR reasoning_effort='high' OR reasoning_effort='xhigh' OR reasoning_effort='max')),
 CHECK(label IS NULL OR OCTET_LENGTH(label) BETWEEN 1 AND 100),
 CHECK(created_at>0),
 CHECK(next_position>0),
 CHECK(created_seq>0),
 CHECK(length(workspace_digest)=32),
 CHECK(obligation_since IS NULL OR obligation_since>0),
 CHECK(workspace_key>0 AND workspace_key<=created_seq),
 CHECK(parent_ref IS NULL OR parent_ref<>session_ref)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE core_command(
 command_key VARCHAR(128) NOT NULL,
 kind BIGINT NOT NULL,
 target VARCHAR(128) NOT NULL,
 input_digest BLOB NOT NULL,
 primary_content_id BIGINT,
 secondary_content_id BIGINT,
 accepted TINYINT NOT NULL,
 code TEXT NOT NULL,
 revision BIGINT NOT NULL,
 created TINYINT NOT NULL,
 command_seq BIGINT NOT NULL,
 PRIMARY KEY(command_seq),
 UNIQUE(command_key),
 FOREIGN KEY(primary_content_id) REFERENCES content(content_id),
 FOREIGN KEY(secondary_content_id) REFERENCES content(content_id),
 CHECK(OCTET_LENGTH(command_key)<=128),
 CHECK(kind BETWEEN 1 AND 7),
 CHECK(OCTET_LENGTH(target)<=128),
 CHECK(length(input_digest)=32),
 CHECK(accepted IN (0,1)),
 CHECK(OCTET_LENGTH(code)<=96),
 CHECK(revision>=0),
 CHECK(created IN (0,1)),
 CHECK(command_seq>0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE session_revision(
 session_ref VARCHAR(6) NOT NULL,
 revision BIGINT NOT NULL,
 command_key VARCHAR(128) NOT NULL,
 workspace LONGTEXT NOT NULL,
 provider TEXT NOT NULL,
 model LONGTEXT NOT NULL,
 instructions_content_id BIGINT NOT NULL,
 instructions_updated TINYINT NOT NULL,
 tool_set_id BIGINT NOT NULL,
 loaded_tool_set_id BIGINT,
 permission_mode BIGINT NOT NULL,
 output_schema_content_id BIGINT,
 compaction_trigger BIGINT,
 output_reservation BIGINT,
 reasoning_effort VARCHAR(6),
 label TEXT,
 effort_source_revision BIGINT NOT NULL DEFAULT 1,
 PRIMARY KEY(session_ref,revision),
 UNIQUE(command_key),
 FOREIGN KEY(session_ref) REFERENCES session(session_ref),
 FOREIGN KEY(command_key) REFERENCES core_command(command_key),
 FOREIGN KEY(instructions_content_id) REFERENCES content(content_id),
 FOREIGN KEY(tool_set_id) REFERENCES tool_set(tool_set_id),
 FOREIGN KEY(loaded_tool_set_id) REFERENCES tool_set(tool_set_id),
 FOREIGN KEY(session_ref,effort_source_revision) REFERENCES session_revision(session_ref,revision),
 FOREIGN KEY(output_schema_content_id) REFERENCES content(content_id),
 CHECK(revision>0),
 CHECK(OCTET_LENGTH(provider) BETWEEN 1 AND 16 AND REGEXP_LIKE(provider,'^[a-z]','c') AND (NOT REGEXP_LIKE(provider,'[^a-z0-9_-]','c'))),
 CHECK(instructions_updated IN (0,1)),
 CHECK(tool_set_id>0),
 CHECK(permission_mode BETWEEN 0 AND 1),
 CHECK(compaction_trigger IS NULL OR compaction_trigger>0),
 CHECK(output_reservation IS NULL OR output_reservation>=0),
 CHECK(reasoning_effort IS NULL OR (reasoning_effort='none' OR reasoning_effort='low' OR reasoning_effort='medium' OR reasoning_effort='high' OR reasoning_effort='xhigh' OR reasoning_effort='max')),
 CHECK(label IS NULL OR OCTET_LENGTH(label) BETWEEN 1 AND 100),
 CHECK(effort_source_revision>0 AND effort_source_revision<=revision)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE session_change(
 session_ref VARCHAR(6) NOT NULL,
 position BIGINT NOT NULL,
 ordinal BIGINT NOT NULL,
 revision BIGINT NOT NULL,
 field VARCHAR(24) NOT NULL,
 changed_at BIGINT NOT NULL,
 provider_text TEXT,
 refused_operation_id BIGINT,
 PRIMARY KEY(session_ref,position,ordinal),
 UNIQUE(session_ref,revision,field),
 FOREIGN KEY(session_ref) REFERENCES session(session_ref),
 FOREIGN KEY(session_ref,revision) REFERENCES session_revision(session_ref,revision),
 CHECK(position>0),
 CHECK(ordinal>=0),
 CHECK(revision>1),
 CHECK((field='provider' OR field='model' OR field='instructions' OR field='tools' OR field='loaded_tools' OR field='permission_mode' OR field='output_schema' OR field='compaction_trigger' OR field='output_reservation' OR field='reasoning_effort' OR field='label' OR field='reasoning_effort_refused')),
 CHECK(changed_at>0),
 CHECK(provider_text IS NULL OR OCTET_LENGTH(provider_text)<=520),
 CHECK((field='reasoning_effort_refused')=(provider_text IS NOT NULL)),
 CHECK((field='reasoning_effort_refused')=(refused_operation_id IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE message_admission(
 admission_id BIGINT NOT NULL,
 session_ref VARCHAR(6) NOT NULL,
 command_key VARCHAR(128) NOT NULL,
 content_id BIGINT NOT NULL,
 admission_position BIGINT,
 turn_id BIGINT,
 admitted_at BIGINT NOT NULL,
 sender_session_ref VARCHAR(6),
 sender_position BIGINT,
 message_admission_pending_lead BIGINT GENERATED ALWAYS AS (CASE WHEN turn_id IS NULL THEN admission_id END) STORED,
 message_admission_session_pending_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN turn_id IS NULL THEN session_ref END) STORED,
 message_admission_person_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN sender_session_ref IS NULL THEN session_ref END) STORED,
 message_admission_unpositioned_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN admission_position IS NULL THEN session_ref END) STORED,
 PRIMARY KEY(admission_id),
 UNIQUE(command_key),
 FOREIGN KEY(session_ref) REFERENCES session(session_ref),
 FOREIGN KEY(command_key) REFERENCES core_command(command_key),
 FOREIGN KEY(content_id) REFERENCES content(content_id),
 FOREIGN KEY(sender_session_ref) REFERENCES session(session_ref),
 CHECK(admission_id>0),
 CHECK(admission_position>0),
 CHECK(admitted_at>0),
 CHECK(sender_position>0),
 CHECK((sender_session_ref IS NULL)=(sender_position IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE sent_rejection(
 command_key VARCHAR(128) NOT NULL,
 sender_session_ref VARCHAR(6) NOT NULL,
 sender_position BIGINT NOT NULL,
 rejected_at BIGINT NOT NULL,
 PRIMARY KEY(command_key),
 UNIQUE(sender_session_ref,sender_position),
 FOREIGN KEY(command_key) REFERENCES core_command(command_key),
 FOREIGN KEY(sender_session_ref) REFERENCES session(session_ref),
 CHECK(sender_position>0),
 CHECK(rejected_at>0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE turn(
 turn_id BIGINT NOT NULL,
 session_ref VARCHAR(6) NOT NULL,
 first_admission_id BIGINT NOT NULL,
 input_cutoff BIGINT NOT NULL,
 operation_id BIGINT NOT NULL,
 outcome_code TEXT,
 outcome_content_id BIGINT,
 outcome_position BIGINT,
 outcome_at BIGINT,
 continuation_operation_id BIGINT,
 turn_tool_continuation_lead BIGINT GENERATED ALWAYS AS (CASE WHEN outcome_code IS NULL AND continuation_operation_id=operation_id THEN operation_id END) STORED,
 turn_unpositioned_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN (outcome_code IS NULL)!=(outcome_position IS NULL) THEN session_ref END) STORED,
 PRIMARY KEY(turn_id),
 FOREIGN KEY(session_ref) REFERENCES session(session_ref),
 FOREIGN KEY(first_admission_id) REFERENCES message_admission(admission_id),
 FOREIGN KEY(outcome_content_id) REFERENCES content(content_id),
 CHECK(turn_id>0),
 CHECK(input_cutoff>=first_admission_id),
 CHECK(outcome_code IS NULL OR OCTET_LENGTH(outcome_code) BETWEEN 1 AND 96),
 CHECK(outcome_position>0),
 CHECK(outcome_at IS NULL OR outcome_at>0),
 CHECK(continuation_operation_id IS NULL OR continuation_operation_id<=operation_id),
 CHECK((outcome_code IS NULL)=(outcome_at IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE session_stop(
 command_key VARCHAR(128) NOT NULL,
 session_ref VARCHAR(6) NOT NULL,
 selected_turn_id BIGINT,
 position BIGINT,
 admission_cutoff BIGINT NOT NULL,
 stopped_at BIGINT NOT NULL,
 parent_caused TINYINT NOT NULL DEFAULT 0,
 session_stop_unpositioned_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN position IS NULL THEN session_ref END) STORED,
 PRIMARY KEY(command_key),
 FOREIGN KEY(command_key) REFERENCES core_command(command_key),
 FOREIGN KEY(session_ref) REFERENCES session(session_ref),
 FOREIGN KEY(selected_turn_id) REFERENCES turn(turn_id),
 CHECK(position>0),
 CHECK(admission_cutoff>=0),
 CHECK(stopped_at>0),
 CHECK(parent_caused IN (0,1))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE session_archive(
 session_ref VARCHAR(6) NOT NULL,
 command_key VARCHAR(128),
 PRIMARY KEY(session_ref),
 FOREIGN KEY(session_ref) REFERENCES session(session_ref),
 FOREIGN KEY(command_key) REFERENCES session_stop(command_key)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE session_archive_command(
 command_key VARCHAR(128) NOT NULL,
 archived TINYINT NOT NULL,
 PRIMARY KEY(command_key),
 FOREIGN KEY(command_key) REFERENCES core_command(command_key),
 CHECK(archived IN (0,1))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE session_pin(
 session_ref VARCHAR(6) NOT NULL,
 command_key VARCHAR(128),
 PRIMARY KEY(session_ref),
 UNIQUE(command_key),
 FOREIGN KEY(session_ref) REFERENCES session(session_ref),
 FOREIGN KEY(command_key) REFERENCES core_command(command_key)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE session_pin_command(
 command_key VARCHAR(128) NOT NULL,
 pinned TINYINT NOT NULL,
 PRIMARY KEY(command_key),
 FOREIGN KEY(command_key) REFERENCES core_command(command_key),
 CHECK(pinned IN (0,1))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE session_stop_owed(
 child_ref VARCHAR(6) NOT NULL,
 cause_ref VARCHAR(6) NOT NULL,
 cause_position BIGINT NOT NULL,
 settled BIGINT NOT NULL,
 PRIMARY KEY(child_ref,cause_ref,cause_position),
 FOREIGN KEY(child_ref) REFERENCES session(session_ref),
 FOREIGN KEY(cause_ref) REFERENCES session(session_ref),
 CHECK(cause_position>0),
 CHECK(settled BETWEEN 0 AND 1)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE session_forward(
 forward_id BIGINT NOT NULL,
 target_ref VARCHAR(6) NOT NULL,
 child_ref VARCHAR(6) NOT NULL,
 kind BIGINT NOT NULL,
 source_id BIGINT NOT NULL,
 position BIGINT,
 ordinal BIGINT NOT NULL,
 delivered_at BIGINT,
 message_delivered TINYINT,
 suppress_message TINYINT NOT NULL DEFAULT 0,
 session_forward_open_lead BIGINT GENERATED ALWAYS AS (CASE WHEN position IS NULL THEN forward_id END) STORED,
 PRIMARY KEY(forward_id),
 UNIQUE(target_ref,kind,source_id),
 FOREIGN KEY(target_ref) REFERENCES session(session_ref),
 FOREIGN KEY(child_ref) REFERENCES session(session_ref),
 CHECK(forward_id>0),
 CHECK(kind BETWEEN 1 AND 2),
 CHECK(source_id>0),
 CHECK(position IS NULL OR position>0),
 CHECK(ordinal=0),
 CHECK(delivered_at IS NULL OR delivered_at>0),
 CHECK(message_delivered IS NULL OR message_delivered IN (0,1)),
 CHECK(suppress_message IN (0,1)),
 CHECK((position IS NULL)=(delivered_at IS NULL)),
 CHECK(target_ref<>child_ref)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE model_interruption_command(
 command_key VARCHAR(128) NOT NULL,
 session_ref TEXT NOT NULL,
 turn_id TEXT NOT NULL,
 operation_id TEXT NOT NULL,
 PRIMARY KEY(command_key),
 FOREIGN KEY(command_key) REFERENCES core_command(command_key),
 CHECK(OCTET_LENGTH(session_ref)<=128),
 CHECK(OCTET_LENGTH(turn_id) BETWEEN 1 AND 20 AND (NOT REGEXP_LIKE(turn_id,'[^0-9]','c'))),
 CHECK(OCTET_LENGTH(operation_id) BETWEEN 1 AND 20 AND (NOT REGEXP_LIKE(operation_id,'[^0-9]','c')))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE model_operation(
 operation_id BIGINT NOT NULL,
 turn_id BIGINT NOT NULL,
 session_ref VARCHAR(6) NOT NULL,
 settings_revision BIGINT NOT NULL,
 input_cutoff BIGINT NOT NULL,
 admission_position BIGINT NOT NULL,
 purpose TINYINT NOT NULL DEFAULT 0,
 compaction_trigger BIGINT,
 output_reservation BIGINT NOT NULL,
 reasoning_effort VARCHAR(6),
 output_item_count BIGINT,
 attempt_ordinal BIGINT NOT NULL,
 auth_refresh_claimed TINYINT NOT NULL DEFAULT 0,
 retry_due_at_ms BIGINT,
 last_failure_code TEXT,
 resolution_code TEXT,
 resolution_content_id BIGINT,
 response_id TEXT,
 model_evidence BLOB,
 request_id TEXT,
 usage_uncached_tokens BIGINT,
 usage_cache_read_tokens BIGINT,
 usage_cache_write_tokens BIGINT,
 usage_output_tokens BIGINT,
 interrupted_by_command_key VARCHAR(128),
 attempt_at BIGINT,
 retry_scheduled_at BIGINT,
 resolved_at BIGINT,
 history_floor BIGINT,
 history_level BIGINT,
 history_dropped BIGINT,
 tool_set_id BIGINT NOT NULL,
 effort_source_revision BIGINT NOT NULL DEFAULT 1,
 previous_reasoning_effort VARCHAR(6),
 effort_update TINYINT NOT NULL DEFAULT 0,
 previous_effort_override VARCHAR(6),
 latency_ms BIGINT,
 first_event_ms BIGINT,
 context_window BIGINT NOT NULL,
 model_operation_retry_due_lead BIGINT GENERATED ALWAYS AS (CASE WHEN resolution_code IS NULL AND attempt_ordinal<4 THEN retry_due_at_ms END) STORED,
 model_operation_retry_exhausted_lead BIGINT GENERATED ALWAYS AS (CASE WHEN resolution_code IS NULL AND retry_due_at_ms=0 AND attempt_ordinal=4 THEN operation_id END) STORED,
 model_operation_context_history_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN (resolution_code='answer' OR resolution_code='compacted' OR resolution_code='tool_proposals') THEN session_ref END) STORED,
 model_operation_compaction_bases_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN purpose=1 AND resolution_code='compacted' THEN session_ref END) STORED,
 PRIMARY KEY(operation_id),
 UNIQUE(operation_id,session_ref),
 FOREIGN KEY(tool_set_id) REFERENCES tool_set(tool_set_id),
 FOREIGN KEY(turn_id) REFERENCES turn(turn_id),
 FOREIGN KEY(resolution_content_id) REFERENCES content(content_id),
 FOREIGN KEY(interrupted_by_command_key) REFERENCES core_command(command_key),
 FOREIGN KEY(session_ref,settings_revision) REFERENCES session_revision(session_ref,revision),
 CHECK(operation_id>0),
 CHECK(settings_revision>0),
 CHECK(input_cutoff>0),
 CHECK(admission_position>0),
 CHECK(purpose IN (0,1)),
 CHECK(compaction_trigger IS NULL OR compaction_trigger>0),
 CHECK(output_reservation>=0),
 CHECK(reasoning_effort IS NULL OR (reasoning_effort='none' OR reasoning_effort='low' OR reasoning_effort='medium' OR reasoning_effort='high' OR reasoning_effort='xhigh' OR reasoning_effort='max')),
 CHECK(output_item_count IS NULL OR output_item_count>=0),
 CHECK(attempt_ordinal BETWEEN 1 AND 4),
 CHECK(auth_refresh_claimed IN (0,1)),
 CHECK(retry_due_at_ms IS NULL OR retry_due_at_ms>=0),
 CHECK(last_failure_code IS NULL OR OCTET_LENGTH(last_failure_code) BETWEEN 1 AND 96),
 CHECK(resolution_code IS NULL OR OCTET_LENGTH(resolution_code) BETWEEN 1 AND 96),
 CHECK(response_id IS NULL OR OCTET_LENGTH(response_id)<=256),
 CHECK(model_evidence IS NULL OR length(model_evidence) BETWEEN 7 AND 775),
 CHECK(request_id IS NULL OR OCTET_LENGTH(request_id)<=256),
 CHECK(usage_uncached_tokens IS NULL OR usage_uncached_tokens>=0),
 CHECK(usage_cache_read_tokens IS NULL OR usage_cache_read_tokens>=0),
 CHECK(usage_cache_write_tokens IS NULL OR usage_cache_write_tokens>=0),
 CHECK(usage_output_tokens IS NULL OR usage_output_tokens>=0),
 CHECK(attempt_at IS NULL OR attempt_at>0),
 CHECK(retry_scheduled_at IS NULL OR retry_scheduled_at>0),
 CHECK(resolved_at IS NULL OR resolved_at>0),
 CHECK(history_floor IS NULL OR history_floor>0),
 CHECK(history_level IS NULL OR history_level BETWEEN 1 AND 3),
 CHECK(history_dropped IS NULL OR history_dropped>=0),
 CHECK(tool_set_id>0),
 CHECK(effort_source_revision>0 AND effort_source_revision<=settings_revision),
 CHECK(previous_reasoning_effort IS NULL OR (previous_reasoning_effort='none' OR previous_reasoning_effort='low' OR previous_reasoning_effort='medium' OR previous_reasoning_effort='high' OR previous_reasoning_effort='xhigh' OR previous_reasoning_effort='max')),
 CHECK(effort_update IN (0,1) AND (effort_update=0 OR reasoning_effort IS NOT NULL)),
 CHECK(previous_effort_override IS NULL OR (previous_effort_override='none' OR previous_effort_override='low' OR previous_effort_override='medium' OR previous_effort_override='high' OR previous_effort_override='xhigh' OR previous_effort_override='max')),
 CHECK(latency_ms IS NULL OR latency_ms>=0),
 CHECK(first_event_ms IS NULL OR first_event_ms>=0),
 CHECK(context_window BETWEEN 0 AND 4294967295),
 CHECK((usage_uncached_tokens IS NULL AND usage_cache_read_tokens IS NULL AND usage_cache_write_tokens IS NULL AND usage_output_tokens IS NULL) OR (usage_uncached_tokens IS NOT NULL AND usage_cache_read_tokens IS NOT NULL AND usage_cache_write_tokens IS NOT NULL AND usage_output_tokens IS NOT NULL)),
 CHECK((resolution_code IS NULL AND retry_due_at_ms IS NOT NULL) OR (resolution_code IS NOT NULL AND retry_due_at_ms IS NULL)),
 CHECK((resolution_code IS NULL AND retry_due_at_ms=0 AND attempt_at IS NOT NULL AND retry_scheduled_at IS NULL AND resolved_at IS NULL) OR (resolution_code IS NULL AND retry_due_at_ms>0 AND attempt_at IS NULL AND retry_scheduled_at IS NOT NULL AND resolved_at IS NULL) OR (resolution_code IS NOT NULL AND attempt_at IS NULL AND retry_scheduled_at IS NULL AND resolved_at IS NOT NULL)),
 CHECK(((resolution_code <=> 'interrupted') AND interrupted_by_command_key IS NOT NULL) OR (coalesce(resolution_code,'')!='interrupted' AND interrupted_by_command_key IS NULL)),
 CHECK((history_floor IS NULL AND history_level IS NULL AND history_dropped IS NULL) OR (history_floor IS NOT NULL AND purpose=1 AND ((history_level IS NULL AND history_dropped IS NULL) OR (history_level IS NOT NULL AND history_dropped IS NOT NULL))))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE message_skill(
 admission_id BIGINT NOT NULL,
 position BIGINT NOT NULL,
 name TEXT NOT NULL,
 content_id BIGINT NOT NULL,
 PRIMARY KEY(admission_id,position),
 FOREIGN KEY(admission_id) REFERENCES message_admission(admission_id),
 FOREIGN KEY(content_id) REFERENCES content(content_id),
 CHECK(position>0),
 CHECK(OCTET_LENGTH(name) BETWEEN 1 AND 64 AND (NOT REGEXP_LIKE(name,'[^a-z0-9-]','c')))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE session_skill_catalog(
 session_ref VARCHAR(6) NOT NULL,
 position BIGINT NOT NULL,
 catalog_content_id BIGINT NOT NULL,
 PRIMARY KEY(session_ref,position),
 FOREIGN KEY(session_ref) REFERENCES session(session_ref),
 FOREIGN KEY(catalog_content_id) REFERENCES content(content_id),
 CHECK(position>=0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE conversation_entry(
 session_ref VARCHAR(6) NOT NULL,
 entry_ordinal BIGINT NOT NULL,
 session_position BIGINT NOT NULL,
 entry_kind BIGINT NOT NULL,
 turn_id BIGINT,
 source_admission_id BIGINT,
 source_revision BIGINT,
 source_catalog_position BIGINT,
 source_skill_admission_id BIGINT,
 source_skill_position BIGINT,
 source_operation_id BIGINT,
 source_item_ordinal BIGINT,
 content_id BIGINT NOT NULL,
 recorded_at BIGINT NOT NULL,
 PRIMARY KEY(session_ref,entry_ordinal),
 UNIQUE(source_admission_id),
 UNIQUE(session_ref,session_position),
 UNIQUE(session_ref,source_revision),
 UNIQUE(session_ref,source_catalog_position),
 UNIQUE(source_skill_admission_id,source_skill_position),
 FOREIGN KEY(turn_id) REFERENCES turn(turn_id),
 FOREIGN KEY(source_admission_id) REFERENCES message_admission(admission_id),
 FOREIGN KEY(source_operation_id) REFERENCES model_operation(operation_id),
 FOREIGN KEY(content_id) REFERENCES content(content_id),
 FOREIGN KEY(session_ref,source_revision) REFERENCES session_revision(session_ref,revision),
 FOREIGN KEY(session_ref,source_catalog_position) REFERENCES session_skill_catalog(session_ref,position),
 FOREIGN KEY(source_skill_admission_id,source_skill_position) REFERENCES message_skill(admission_id,position),
 CHECK(entry_ordinal>0),
 CHECK(session_position>0),
 CHECK(entry_kind BETWEEN 1 AND 4),
 CHECK(source_item_ordinal IS NULL OR source_item_ordinal>=0),
 CHECK(recorded_at>0),
 CHECK((entry_kind=3)=(source_item_ordinal IS NOT NULL)),
 CHECK((turn_id IS NULL)=(source_catalog_position IS NOT NULL)),
 CHECK(source_catalog_position IS NULL OR source_catalog_position=session_position),
 CHECK((source_skill_admission_id IS NULL)=(source_skill_position IS NULL)),
 CHECK((entry_kind=4)=(source_skill_position IS NOT NULL)),
 CHECK((entry_kind=1 AND source_admission_id IS NOT NULL AND source_revision IS NULL AND source_catalog_position IS NULL AND source_operation_id IS NULL) OR (entry_kind=2 AND source_admission_id IS NULL AND ((source_revision IS NOT NULL AND source_catalog_position IS NULL) OR (source_revision IS NULL AND source_catalog_position IS NOT NULL)) AND source_operation_id IS NULL) OR (entry_kind=3 AND source_admission_id IS NULL AND source_revision IS NULL AND source_catalog_position IS NULL AND source_operation_id IS NOT NULL) OR (entry_kind=4 AND source_admission_id IS NULL AND source_revision IS NULL AND source_catalog_position IS NULL AND source_operation_id IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE model_output_item(
 operation_id BIGINT NOT NULL,
 item_ordinal BIGINT NOT NULL,
 session_ref VARCHAR(6) NOT NULL,
 session_position BIGINT NOT NULL,
 item_kind BIGINT NOT NULL,
 message_content_id BIGINT,
 attempt_ordinal BIGINT NOT NULL,
 item_id_digest VARBINARY(32) NOT NULL,
 replay_omits_reasoning_text TINYINT NOT NULL,
 phase BIGINT NOT NULL DEFAULT 0,
 extras_content_id BIGINT NOT NULL,
 part_count BIGINT NOT NULL,
 description TEXT,
 call_failed TINYINT NOT NULL DEFAULT 0,
 model_output_call_history_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN item_kind=3 THEN session_ref END) STORED,
 model_output_hosted_history_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN item_kind=5 THEN session_ref END) STORED,
 model_output_compaction_history_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN item_kind=4 THEN session_ref END) STORED,
 model_output_compaction_anchor_lead BIGINT GENERATED ALWAYS AS (CASE WHEN item_kind=4 THEN operation_id END) STORED,
 PRIMARY KEY(operation_id,item_ordinal),
 UNIQUE(session_ref,session_position),
 UNIQUE(operation_id,item_id_digest),
 FOREIGN KEY(operation_id) REFERENCES model_operation(operation_id),
 FOREIGN KEY(message_content_id) REFERENCES content(content_id),
 FOREIGN KEY(extras_content_id) REFERENCES content(content_id),
 CHECK(item_ordinal>=0),
 CHECK(session_position>0),
 CHECK(item_kind BETWEEN 1 AND 5),
 CHECK((message_content_id IS NOT NULL)=(item_kind=2)),
 CHECK(attempt_ordinal>0),
 CHECK(length(item_id_digest)=32),
 CHECK(replay_omits_reasoning_text IN (0,1) AND (replay_omits_reasoning_text=0 OR item_kind=1)),
 CHECK(phase IN (0,1,2) AND (phase=0 OR item_kind=2)),
 CHECK(part_count>=0 AND (part_count=0 OR item_kind IN (1,2))),
 CHECK(description IS NULL OR (OCTET_LENGTH(description) BETWEEN 1 AND 200 AND (description IS NOT NULL)=(item_kind=5))),
 CHECK(call_failed IN (0,1) AND (call_failed=0 OR item_kind=5))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE model_output_part(
 operation_id BIGINT NOT NULL,
 item_ordinal BIGINT NOT NULL,
 part_ordinal BIGINT NOT NULL,
 part_array BIGINT NOT NULL,
 part_kind BIGINT NOT NULL,
 text_length BIGINT,
 text_content_id BIGINT,
 extras_content_id BIGINT NOT NULL,
 PRIMARY KEY(operation_id,item_ordinal,part_ordinal),
 FOREIGN KEY(text_content_id) REFERENCES content(content_id),
 FOREIGN KEY(extras_content_id) REFERENCES content(content_id),
 CHECK(part_ordinal>=0),
 CHECK(part_array IN (1,2)),
 CHECK(part_kind=0 OR (part_kind IN (1,2,4) AND part_array=1) OR (part_kind=3 AND part_array=2)),
 CHECK(text_length IS NULL OR text_length>=0),
 CHECK((text_length IS NOT NULL)=(part_kind IN (1,2)) AND (text_content_id IS NOT NULL)=(part_kind IN (3,4)))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE model_tool_call(
 operation_id BIGINT NOT NULL,
 session_ref VARCHAR(6) NOT NULL,
 call_ordinal BIGINT NOT NULL,
 item_ordinal BIGINT NOT NULL,
 name_content_id BIGINT NOT NULL,
 call_id_content_id BIGINT NOT NULL,
 arguments_content_id BIGINT NOT NULL,
 description TEXT,
 field_metadata BLOB NOT NULL,
 rejection_code VARCHAR(17),
 rejection_content_id BIGINT,
 acceptance_position BIGINT,
 action_kind BIGINT,
 model_tool_call_session_results_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN acceptance_position IS NOT NULL THEN session_ref END) STORED,
 model_tool_call_acceptance_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN acceptance_position IS NOT NULL THEN session_ref END) STORED,
 PRIMARY KEY(operation_id,call_ordinal),
 UNIQUE(operation_id,item_ordinal),
 UNIQUE(operation_id,call_id_content_id),
 UNIQUE(operation_id,call_ordinal,action_kind),
 FOREIGN KEY(operation_id) REFERENCES model_operation(operation_id),
 FOREIGN KEY(operation_id,session_ref) REFERENCES model_operation(operation_id,session_ref),
 FOREIGN KEY(name_content_id) REFERENCES content(content_id),
 FOREIGN KEY(call_id_content_id) REFERENCES content(content_id),
 FOREIGN KEY(arguments_content_id) REFERENCES content(content_id),
 FOREIGN KEY(rejection_content_id) REFERENCES content(content_id),
 CHECK(call_ordinal>=0),
 CHECK(item_ordinal>=0),
 CHECK(description IS NULL OR OCTET_LENGTH(description) BETWEEN 1 AND 200),
 CHECK(length(field_metadata)=120),
 CHECK(rejection_code IS NULL OR rejection_code IN ('unknown_tool','invalid_arguments')),
 CHECK(acceptance_position IS NULL OR acceptance_position>0),
 CHECK(action_kind IS NULL OR action_kind=1),
 CHECK((rejection_code IS NULL AND rejection_content_id IS NULL AND acceptance_position IS NULL AND (action_kind <=> 1)) OR (rejection_code IS NOT NULL AND rejection_content_id IS NOT NULL AND acceptance_position IS NOT NULL AND action_kind IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE action_operation(
 action_id BIGINT NOT NULL,
 parent_operation_id BIGINT NOT NULL,
 call_ordinal BIGINT NOT NULL,
 session_ref VARCHAR(6) NOT NULL,
 tool_kind BIGINT NOT NULL,
 permission_revision BIGINT NOT NULL,
 authorized TINYINT NOT NULL,
 attempt_ordinal BIGINT NOT NULL DEFAULT 0,
 bash_timeout_override_ms BIGINT,
 attempt_timeout_ms BIGINT,
 sender_handle VARCHAR(32),
 resolution_code VARCHAR(23),
 resolution_content_id BIGINT,
 acceptance_position BIGINT,
 attempt_at BIGINT,
 decided_at BIGINT,
 resolved_at BIGINT,
 approval_position BIGINT,
 action_operation_session_results_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN acceptance_position IS NOT NULL THEN session_ref END) STORED,
 action_operation_approval_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN approval_position IS NOT NULL THEN session_ref END) STORED,
 action_operation_executable_lead BIGINT GENERATED ALWAYS AS (CASE WHEN authorized=1 AND resolution_code IS NULL AND attempt_ordinal=0 THEN action_id END) STORED,
 action_operation_unresolved_attempt_lead BIGINT GENERATED ALWAYS AS (CASE WHEN resolution_code IS NULL AND attempt_ordinal=1 THEN action_id END) STORED,
 action_operation_indeterminate_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN resolution_code='indeterminate' THEN session_ref END) STORED,
 PRIMARY KEY(action_id),
 UNIQUE(parent_operation_id,call_ordinal),
 FOREIGN KEY(parent_operation_id) REFERENCES model_operation(operation_id),
 FOREIGN KEY(session_ref) REFERENCES session(session_ref),
 FOREIGN KEY(resolution_content_id) REFERENCES content(content_id),
 FOREIGN KEY(parent_operation_id,session_ref) REFERENCES model_operation(operation_id,session_ref),
 FOREIGN KEY(parent_operation_id,call_ordinal,tool_kind) REFERENCES model_tool_call(operation_id,call_ordinal,action_kind),
 FOREIGN KEY(session_ref,permission_revision) REFERENCES session_revision(session_ref,revision),
 CHECK(action_id>0),
 CHECK(call_ordinal>=0),
 CHECK(tool_kind=1),
 CHECK(permission_revision>0),
 CHECK(authorized IN (0,1)),
 CHECK(attempt_ordinal IN (0,1)),
 CHECK(bash_timeout_override_ms IS NULL OR bash_timeout_override_ms>0),
 CHECK(attempt_timeout_ms IS NULL OR attempt_timeout_ms>0),
 CHECK(sender_handle IS NULL OR (OCTET_LENGTH(sender_handle)=32 AND (NOT REGEXP_LIKE(sender_handle,'[^0-9a-f]','c')))),
 CHECK(resolution_code IS NULL OR (resolution_code='denied' OR resolution_code='cancelled' OR resolution_code='succeeded' OR resolution_code='failed' OR resolution_code='timed_out' OR resolution_code='indeterminate' OR resolution_code='storage_failed' OR resolution_code='spawn_failed' OR resolution_code='infrastructure_shutdown')),
 CHECK(acceptance_position IS NULL OR acceptance_position>0),
 CHECK(attempt_at IS NULL OR attempt_at>0),
 CHECK(decided_at IS NULL OR decided_at>0),
 CHECK(resolved_at IS NULL OR resolved_at>0),
 CHECK(approval_position IS NULL OR approval_position>0),
 CHECK((NOT (resolution_code <=> 'denied')) OR (authorized=0 AND attempt_ordinal=0)),
 CHECK((attempt_ordinal=0 AND attempt_timeout_ms IS NULL) OR (attempt_ordinal=1 AND attempt_timeout_ms IS NOT NULL)),
 CHECK((resolution_code IS NULL AND resolution_content_id IS NULL AND acceptance_position IS NULL) OR (resolution_code IS NOT NULL AND resolution_content_id IS NOT NULL AND acceptance_position IS NOT NULL)),
 CHECK((attempt_ordinal=1)=(attempt_at IS NOT NULL)),
 CHECK((authorized=1)=(decided_at IS NOT NULL)),
 CHECK((resolution_code IS NULL)=(resolved_at IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE permission_decision_command(
 command_key VARCHAR(128) NOT NULL,
 action_id TEXT NOT NULL,
 decision VARCHAR(10) NOT NULL,
 PRIMARY KEY(command_key),
 FOREIGN KEY(command_key) REFERENCES core_command(command_key),
 CHECK(OCTET_LENGTH(action_id) BETWEEN 1 AND 20 AND (NOT REGEXP_LIKE(action_id,'[^0-9]','c'))),
 CHECK(decision IN ('allow_once','deny'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE INDEX session_obligation_parent ON session(session_obligation_parent_lead,obligation_since,session_ref);
CREATE INDEX session_forward_owed_message ON session_forward(target_ref,message_delivered);
CREATE INDEX session_workspace_list ON session(workspace_digest,created_seq);
CREATE UNIQUE INDEX message_admission_sent ON message_admission(sender_session_ref,sender_position);
CREATE UNIQUE INDEX turn_one_active_per_session ON turn((CASE WHEN outcome_code IS NULL THEN session_ref END));
CREATE INDEX turn_tool_continuation ON turn(turn_tool_continuation_lead);
CREATE INDEX message_admission_session_order ON message_admission(session_ref,turn_id,admission_id);
CREATE INDEX message_admission_pending ON message_admission(message_admission_pending_lead,session_ref);
CREATE INDEX message_admission_session_pending ON message_admission(message_admission_session_pending_lead,admission_id);
CREATE INDEX message_admission_person ON message_admission(message_admission_person_lead,admission_position);
CREATE INDEX message_admission_unpositioned ON message_admission(message_admission_unpositioned_lead);
CREATE INDEX message_admission_position ON message_admission(session_ref,admission_position);
CREATE INDEX core_command_target_order ON core_command(target,kind,command_seq);
CREATE INDEX session_revision_instructions ON session_revision(session_ref,instructions_content_id);
CREATE INDEX session_revision_output_schema ON session_revision(session_ref,output_schema_content_id);
CREATE INDEX session_stop_exclusion ON session_stop(session_ref,admission_cutoff,position);
CREATE INDEX session_stop_unpositioned ON session_stop(session_stop_unpositioned_lead);
CREATE INDEX session_stop_position ON session_stop(session_ref,position);
CREATE INDEX session_stop_turn ON session_stop(selected_turn_id);
CREATE INDEX session_parent ON session(session_parent_lead);
CREATE INDEX session_stop_open ON session_stop_owed(settled,child_ref);
CREATE INDEX session_forward_message ON session_forward(message_delivered,source_id);
CREATE INDEX session_forward_open ON session_forward(session_forward_open_lead);
CREATE INDEX session_forward_feed ON session_forward(target_ref,position);
CREATE INDEX action_operation_session_order ON action_operation(session_ref,action_id);
CREATE UNIQUE INDEX action_operation_sender_handle ON action_operation(sender_handle);
CREATE INDEX action_operation_acceptance ON action_operation(session_ref,acceptance_position);
CREATE INDEX action_operation_session_results ON action_operation(action_operation_session_results_lead,parent_operation_id,acceptance_position);
CREATE INDEX action_operation_approval ON action_operation(action_operation_approval_lead,approval_position);
CREATE INDEX action_operation_executable ON action_operation(action_operation_executable_lead);
CREATE INDEX action_operation_unresolved_attempt ON action_operation(action_operation_unresolved_attempt_lead);
CREATE INDEX action_operation_indeterminate ON action_operation(action_operation_indeterminate_lead,parent_operation_id,call_ordinal);
CREATE INDEX model_tool_call_session_order ON model_tool_call(session_ref,operation_id,call_ordinal);
CREATE INDEX model_tool_call_session_results ON model_tool_call(model_tool_call_session_results_lead,operation_id,acceptance_position);
CREATE INDEX model_tool_call_acceptance ON model_tool_call(model_tool_call_acceptance_lead,acceptance_position);
CREATE INDEX model_operation_retry_due ON model_operation(model_operation_retry_due_lead,operation_id);
CREATE INDEX model_operation_retry_exhausted ON model_operation(model_operation_retry_exhausted_lead);
CREATE INDEX model_operation_session_history ON model_operation(session_ref,operation_id);
CREATE INDEX model_operation_turn_history ON model_operation(turn_id,operation_id);
CREATE INDEX session_change_refused_operation ON session_change(refused_operation_id,session_ref,revision);
CREATE UNIQUE INDEX model_operation_effort_source ON model_operation(operation_id,session_ref,effort_source_revision);
CREATE INDEX model_operation_admission ON model_operation(session_ref,admission_position);
CREATE INDEX model_operation_context_history ON model_operation(model_operation_context_history_lead,admission_position);
CREATE INDEX model_operation_compaction_bases ON model_operation(model_operation_compaction_bases_lead,admission_position);
CREATE INDEX conversation_entry_history ON conversation_entry(session_ref,session_position);
CREATE INDEX model_output_history ON model_output_item(session_ref,session_position);
CREATE INDEX model_output_call_history ON model_output_item(model_output_call_history_lead,session_position);
CREATE INDEX model_output_hosted_history ON model_output_item(model_output_hosted_history_lead,session_position);
CREATE INDEX model_output_compaction_history ON model_output_item(model_output_compaction_history_lead,session_position);
CREATE INDEX model_output_compaction_anchor ON model_output_item(model_output_compaction_anchor_lead,item_ordinal);
CREATE INDEX turn_session_latest ON turn(session_ref,turn_id DESC);
CREATE INDEX turn_unpositioned ON turn(turn_unpositioned_lead);
CREATE INDEX turn_outcome_position ON turn(session_ref,outcome_position);
ALTER TABLE session_change ADD FOREIGN KEY(refused_operation_id,session_ref,revision) REFERENCES model_operation(operation_id,session_ref,effort_source_revision);
ALTER TABLE message_admission ADD FOREIGN KEY(turn_id) REFERENCES turn(turn_id);
ALTER TABLE conversation_entry ADD FOREIGN KEY(source_operation_id,source_item_ordinal) REFERENCES model_output_item(operation_id,item_ordinal);
