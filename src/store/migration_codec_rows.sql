UPDATE session SET codec='openai-responses/1',codec_options=NULL WHERE session_ref='d8mv7p';
UPDATE session SET codec='openai-responses/3',codec_options=X'00' WHERE session_ref='brhkcj';
UPDATE session SET codec='openai-responses/2',codec_options=NULL WHERE session_ref='rhvzwc';
INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose,output_reservation,attempt_ordinal,retry_due_at_ms,attempt_at,retry_scheduled_at,resolved_at,resolution_code,interrupted_by_command_key,tool_set_id,context_window)
SELECT 3,turn_id,session_ref,settings_revision,input_cutoff,10,0,output_reservation,2,0,1,NULL,NULL,NULL,NULL,tool_set_id,context_window FROM model_operation WHERE operation_id=1;
INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose,output_reservation,attempt_ordinal,retry_due_at_ms,attempt_at,retry_scheduled_at,resolved_at,resolution_code,interrupted_by_command_key,tool_set_id,context_window)
SELECT 4,turn_id,session_ref,settings_revision,input_cutoff,11,0,output_reservation,2,100,NULL,1,NULL,NULL,NULL,tool_set_id,context_window FROM model_operation WHERE operation_id=2;
INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose,output_reservation,attempt_ordinal,resolved_at,resolution_code,interrupted_by_command_key,tool_set_id,context_window)
SELECT 5,turn_id,session_ref,settings_revision,input_cutoff,12,0,output_reservation,1,1,'interrupted','fixture-interrupt',tool_set_id,context_window FROM model_operation WHERE operation_id=1;
INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose,output_reservation,attempt_ordinal,resolved_at,resolution_code,tool_set_id,context_window)
SELECT 6,turn_id,session_ref,settings_revision,input_cutoff,13,0,output_reservation,4,1,'provider_failure',tool_set_id,context_window FROM model_operation WHERE operation_id=2;
INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose,output_reservation,attempt_ordinal,resolved_at,resolution_code,tool_set_id,context_window)
SELECT 7,turn_id,session_ref,settings_revision,input_cutoff,14,1,output_reservation,1,1,'compacted',tool_set_id,context_window FROM model_operation WHERE operation_id=1;
INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose,output_reservation,attempt_ordinal,resolved_at,resolution_code,tool_set_id,context_window)
SELECT 8,turn_id,'rhvzwc',1,input_cutoff,15,0,output_reservation,1,1,'answer',tool_set_id,context_window FROM model_operation WHERE operation_id=1;
