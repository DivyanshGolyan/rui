-- Additional populated schema-63 rows for D238, shared by both engines.
-- Current settings and mutable saved facts deliberately disagree with each
-- Operation's own frozen revision and the pinned pre-change shipped snapshot.
UPDATE session_revision SET model='gpt-6.1-sol' WHERE session_ref='d8mv7p';
UPDATE session_revision SET model='d238-unknown' WHERE session_ref='brhkcj';
UPDATE session SET model='current-is-not-frozen' WHERE session_ref IN ('d8mv7p','brhkcj');
INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq)
SELECT 'window-revision',kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,2,0,(SELECT max(command_seq)+1 FROM core_command) FROM core_command WHERE command_key='fixture-ask-config';
INSERT INTO session_revision(session_ref,revision,command_key,workspace,provider,model,instructions_content_id,instructions_updated,tool_set_id,loaded_tool_set_id,permission_mode,output_schema_content_id,compaction_trigger,output_reservation,reasoning_effort,label)
SELECT session_ref,2,'window-revision',workspace,provider,'gpt-6.1-sol',instructions_content_id,0,tool_set_id,loaded_tool_set_id,permission_mode,output_schema_content_id,compaction_trigger,output_reservation,reasoning_effort,label FROM session_revision WHERE session_ref='brhkcj' AND revision=1;
INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose,output_reservation,attempt_ordinal,retry_due_at_ms,attempt_at)
VALUES(3,2,'brhkcj',2,2,6,1,0,1,0,1);
INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose,output_reservation,attempt_ordinal,resolution_code,resolved_at,history_floor,history_level,history_dropped)
VALUES(4,2,'brhkcj',1,2,7,1,8,1,'context_overflow',1,3,2,4);
UPDATE turn SET operation_id=4 WHERE turn_id=2;
INSERT INTO model_catalog_source(slot,etag,generation,fetched_at) VALUES(1,NULL,1,1);
INSERT INTO model_fact(model_id,context_window,efforts,openai_listed,generation)
VALUES('gpt-6.1-sol',NULL,0,1,1),('d238-unknown',7,0,1,1);
